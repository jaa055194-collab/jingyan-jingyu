import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

abstract class KeyProvider {
  Future<Uint8List> loadKek();
}

/// An explicitly injected development/test key. Never reads the environment or
/// acts as an automatic fallback for a failed production key provider.
final class EnvKeyProvider implements KeyProvider {
  EnvKeyProvider(this.base64Key);
  final String base64Key;

  @override
  Future<Uint8List> loadKek() async {
    final key = base64Decode(base64Key);
    if (key.length != 32) {
      throw const FormatException('KEK must contain exactly 32 bytes');
    }
    return key;
  }
}

/// Stores only a current-Windows-user DPAPI protected random 32-byte KEK.
/// Existing unreadable or invalid key files fail closed and are never replaced.
final class DpapiKeyProvider implements KeyProvider {
  DpapiKeyProvider({required this.path});
  final String path;
  static final _pending = <String, Future<Uint8List>>{};

  @override
  Future<Uint8List> loadKek() {
    if (!Platform.isWindows) {
      return Future.error(UnsupportedError('DPAPI requires Windows'));
    }
    final absolute = File(path).absolute.path;
    final pending = _pending[absolute];
    if (pending != null) return pending.then(Uint8List.fromList);
    final future = _load(absolute).whenComplete(() {
      _pending.remove(absolute);
    });
    _pending[absolute] = future;
    return future.then(Uint8List.fromList);
  }

  Future<Uint8List> _load(String absolute) async {
    final file = File(absolute);
    await file.parent.create(recursive: true);
    final claim = await File('$absolute.lock').open(mode: FileMode.append);
    await claim.lock(FileLock.blockingExclusive);
    try {
      if (await file.exists()) {
        final protected = await file.readAsBytes();
        final key = _dpapi(protected, protect: false);
        if (key.length != 32) {
          key.fillRange(0, key.length, 0);
          throw StateError('Invalid protected KEK length');
        }
        return key;
      }
      final random = Random.secure();
      final key = Uint8List.fromList(
        List.generate(32, (_) => random.nextInt(256)),
      );
      try {
        final protected = _dpapi(key, protect: true);
        // A crash during this write leaves an invalid file: next startup fails
        // closed instead of silently generating a key that loses existing data.
        await file.writeAsBytes(protected, flush: true);
        return key;
      } catch (_) {
        key.fillRange(0, key.length, 0);
        rethrow;
      }
    } finally {
      await claim.unlock();
      await claim.close();
    }
  }
}

final class _Blob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

final _crypt32 = DynamicLibrary.open('crypt32.dll');
final _kernel = DynamicLibrary.open('kernel32.dll');
typedef _DpapiNative =
    Int32 Function(
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<_Blob>,
    );
typedef _Dpapi =
    int Function(
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<_Blob>,
    );
final _protect = _crypt32.lookupFunction<_DpapiNative, _Dpapi>(
  'CryptProtectData',
);
final _unprotect = _crypt32.lookupFunction<_DpapiNative, _Dpapi>(
  'CryptUnprotectData',
);
final _localFree = _kernel
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)
    >('LocalFree');
final _getHeap = _kernel
    .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
      'GetProcessHeap',
    );
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

Uint8List _dpapi(Uint8List bytes, {required bool protect}) {
  if (bytes.isEmpty) throw StateError('Empty protected KEK');
  final heap = _getHeap();
  final input = _alloc(heap, 8, sizeOf<_Blob>()).cast<_Blob>();
  final output = _alloc(heap, 8, sizeOf<_Blob>()).cast<_Blob>();
  final data = _alloc(heap, 8, bytes.length);
  try {
    if (input == nullptr || output == nullptr || data == nullptr) {
      throw StateError('Native allocation failed');
    }
    data.asTypedList(bytes.length).setAll(0, bytes);
    input.ref
      ..length = bytes.length
      ..data = data;
    // CRYPTPROTECT_UI_FORBIDDEN; no LOCAL_MACHINE flag, so current user only.
    final success = (protect ? _protect : _unprotect)(
      input,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      1,
      output,
    );
    if (success == 0) throw StateError('Windows DPAPI key protection failed');
    return Uint8List.fromList(output.ref.data.asTypedList(output.ref.length));
  } finally {
    if (output != nullptr) {
      if (output.ref.data != nullptr) {
        output.ref.data
            .asTypedList(output.ref.length)
            .fillRange(0, output.ref.length, 0);
        _localFree(output.ref.data.cast());
      }
      _free(heap, 0, output.cast());
    }
    if (input != nullptr) _free(heap, 0, input.cast());
    if (data != nullptr) {
      data.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      _free(heap, 0, data.cast());
    }
  }
}
