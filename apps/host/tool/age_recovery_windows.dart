// Windows-only I/O primitives for the offline operator tool. In particular a
// Dart advisory file lock does not protect a SQLite file from an open in
// another process. Open both source members with dwShareMode=0 instead and
// retain both handles until after the archive is published.
import 'dart:ffi';
import 'dart:typed_data';

final _kernel = DynamicLibrary.open('kernel32.dll');
final _createFile = _kernel
    .lookupFunction<
      IntPtr Function(
        Pointer<Uint16>,
        Uint32,
        Uint32,
        IntPtr,
        Uint32,
        Uint32,
        IntPtr,
      ),
      int Function(Pointer<Uint16>, int, int, int, int, int, int)
    >('CreateFileW');
final _closeHandle = _kernel
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
final _getInfo = _kernel
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetFileInformationByHandle');
final _getType = _kernel
    .lookupFunction<Uint32 Function(IntPtr), int Function(int)>('GetFileType');
final _readFile = _kernel
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, IntPtr),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, int)
    >('ReadFile');
final _getAttributes = _kernel
    .lookupFunction<
      Uint32 Function(Pointer<Uint16>),
      int Function(Pointer<Uint16>)
    >('GetFileAttributesW', isLeaf: true);
final _getDriveType = _kernel
    .lookupFunction<
      Uint32 Function(Pointer<Uint16>),
      int Function(Pointer<Uint16>)
    >('GetDriveTypeW');
final _lastError = _kernel.lookupFunction<Uint32 Function(), int Function()>(
  'GetLastError',
  isLeaf: true,
);
final _move = _kernel
    .lookupFunction<
      Int32 Function(Pointer<Uint16>, Pointer<Uint16>, Uint32),
      int Function(Pointer<Uint16>, Pointer<Uint16>, int)
    >('MoveFileExW');
final _heap = _kernel
    .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
      'GetProcessHeap',
    )();
final _alloc = _kernel
    .lookupFunction<
      Pointer<Uint8> Function(Pointer<Void>, Uint32, IntPtr),
      Pointer<Uint8> Function(Pointer<Void>, int, int)
    >('HeapAlloc');
final _free = _kernel
    .lookupFunction<
      Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
      int Function(Pointer<Void>, int, Pointer<Void>)
    >('HeapFree');

const _invalidAttributes = 0xffffffff;
const _directory = 0x10;
const _reparse = 0x400;
final _drivePath = RegExp(r'^[a-zA-Z]:\\');
final _forbidden = RegExp(r'[\x00-\x1f<>:"|?*]');
final _device = RegExp(
  r'^(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)',
  caseSensitive: false,
);

/// Reject ambiguous/device/ADS/UNC/relative/reparse paths rather than attempt
/// to resolve them. All parent directories must already exist and be local.
String localAbsolutePath(String input) {
  final path = input.replaceAll('/', '\\');
  if (path.length < 3 || path.length >= 240 || !_drivePath.hasMatch(path)) {
    throw const RecoveryFailure('local_absolute_path_required');
  }
  final parts = path.substring(3).split('\\');
  if (parts.any(
    (part) =>
        part.isEmpty ||
        part.endsWith('.') ||
        part.endsWith(' ') ||
        _forbidden.hasMatch(part) ||
        _device.hasMatch(part),
  )) {
    throw const RecoveryFailure('local_absolute_path_required');
  }
  final drive = path.substring(0, 3);
  if (_withWide(drive, _getDriveType) != 3) {
    throw const RecoveryFailure('local_fixed_drive_required');
  }
  var current = drive;
  for (var i = 0; i < parts.length - 1; i++) {
    current = '$current${parts[i]}';
    requireDirectory(current);
    current += '\\';
  }
  return path;
}

/// Returns null only when the final leaf does not exist. Access denied, a
/// dangling reparse point, etc. must not be treated as an available path.
int? _attributes(String path) => _withWide(path, (wide) {
  // Resolve both thunks before the call and stay in leaf calls until the
  // thread-local error is captured. Dart/FFI transitions may reset it.
  final lastError = _lastError;
  final result = _getAttributes(wide);
  if (result != _invalidAttributes) return result;
  final error = lastError();
  if (error == 2 || error == 3) return null;
  throw const RecoveryFailure('path_unavailable');
});

bool pathPresent(String path) => _attributes(path) != null;

void requireDirectory(String path) {
  final attributes = _attributes(path);
  if (attributes == null ||
      attributes & _directory == 0 ||
      attributes & _reparse != 0) {
    throw const RecoveryFailure('ordinary_directory_required');
  }
}

void requireOrdinaryFile(String path, String error) {
  final attributes = _attributes(path);
  if (attributes == null || attributes & (_directory | _reparse) != 0) {
    throw RecoveryFailure(error);
  }
}

void publishNoReplace(String source, String destination) {
  // No REPLACE_EXISTING or COPY_ALLOWED. Source and destination are siblings
  // on the same volume; fail atomically if anything takes the destination.
  final success = _withWide(
    source,
    (from) => _withWide(destination, (to) => _move(from, to, 8)),
  );
  if (success == 0) {
    throw const RecoveryFailure('publish_failed_or_destination_exists');
  }
}

final class RecoveryFailure implements Exception {
  const RecoveryFailure(this.code);
  final String code;
}

final class GuardedInput {
  GuardedInput(
    String path, {
    required String unavailable,
    bool shareRead = false,
  }) {
    requireOrdinaryFile(path, unavailable);
    // GENERIC_READ, OPEN_EXISTING and OPEN_REPARSE_POINT. Source members deny
    // all sharing; ciphertext allows age to read but no other writes/deletes.
    _handle = _withWide(
      path,
      (wide) =>
          _createFile(wide, 0x80000000, shareRead ? 1 : 0, 0, 3, 0x00200000, 0),
    );
    if (_handle == -1) throw RecoveryFailure(unavailable);
    try {
      _native(52, (raw) {
        // BY_HANDLE_FILE_INFORMATION (13 DWORDs). Inspect the actual handle,
        // not just path metadata; reject reparse points and hard-link aliases.
        final info = raw.cast<Uint32>();
        if (_getType(_handle) != 1 ||
            _getInfo(_handle, info) == 0 ||
            info[0] & (_directory | _reparse) != 0 ||
            info[10] != 1) {
          throw RecoveryFailure(unavailable);
        }
        length = (info[8] << 32) | info[9];
      });
    } catch (_) {
      close();
      rethrow;
    }
  }

  late final int _handle;
  late final int length;

  Uint8List read(int limit) {
    if (length < 1 || length > limit) {
      throw const RecoveryFailure('input_size_out_of_range');
    }
    final bytes = Uint8List(length);
    try {
      _native(
        64 * 1024,
        (buffer) => _native(4, (rawCount) {
          final count = rawCount.cast<Uint32>();
          var offset = 0;
          while (offset < bytes.length) {
            final requested = (bytes.length - offset).clamp(1, 64 * 1024);
            if (_readFile(_handle, buffer, requested, count, 0) == 0 ||
                count.value == 0 ||
                count.value > requested) {
              throw const RecoveryFailure('input_read_failed');
            }
            bytes.setRange(
              offset,
              offset + count.value,
              buffer.asTypedList(count.value),
            );
            offset += count.value;
          }
          if (_readFile(_handle, buffer, 1, count, 0) == 0 ||
              count.value != 0) {
            throw const RecoveryFailure('input_changed_during_read');
          }
        }),
      );
      return bytes;
    } catch (_) {
      bytes.fillRange(0, bytes.length, 0);
      rethrow;
    }
  }

  void close() => _closeHandle(_handle);
}

T _native<T>(int length, T Function(Pointer<Uint8>) use) {
  final memory = _alloc(_heap, 8, length);
  if (memory == nullptr) throw const RecoveryFailure('allocation_failed');
  try {
    return use(memory);
  } finally {
    memory.asTypedList(length).fillRange(0, length, 0);
    _free(_heap, 0, memory.cast());
  }
}

T _withWide<T>(String text, T Function(Pointer<Uint16>) use) =>
    _native((text.length + 1) * 2, (raw) {
      final wide = raw.cast<Uint16>();
      wide.asTypedList(text.length).setAll(0, text.codeUnits);
      return use(wide);
    });
