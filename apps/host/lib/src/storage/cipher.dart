import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:jingyu_core/jingyu_core.dart';

abstract class ColumnCipher {
  /// Returns `v1:` + base64(nonce|ciphertext|tag).
  String encrypt(String plaintext, {required String aad});
  Result<String> decrypt(String sealed, {required String aad});
}

/// Windows CNG AES-256-GCM with a fresh 96-bit nonce and a 128-bit tag.
final class AesGcmColumnCipher implements ColumnCipher {
  AesGcmColumnCipher(List<int> key) : _key = _validateKey(key) {
    if (!Platform.isWindows) {
      throw UnsupportedError('AES-GCM storage requires Windows BCrypt');
    }
  }

  final Uint8List _key;
  bool _disposed = false;

  /// Erases the owned key buffer and makes this instance unusable.
  void dispose() {
    _key.fillRange(0, _key.length, 0);
    _disposed = true;
  }

  void _checkActive() {
    if (_disposed) throw StateError('Cipher is disposed');
  }

  static Uint8List _validateKey(List<int> key) {
    if (key.length != 32 || key.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('AES-256 requires exactly 32 bytes');
    }
    return Uint8List.fromList(key);
  }

  @override
  String encrypt(String plaintext, {required String aad}) {
    _checkActive();
    final nonce = _randomBytes(12);
    final tag = Uint8List(16);
    final ciphertext = _crypt(
      utf8.encode(plaintext),
      utf8.encode(aad),
      nonce,
      tag,
      decrypt: false,
    );
    return 'v1:${base64Encode([...nonce, ...ciphertext, ...tag])}';
  }

  @override
  Result<String> decrypt(String sealed, {required String aad}) {
    _checkActive();
    try {
      if (!sealed.startsWith('v1:')) throw const FormatException();
      final bytes = base64Decode(sealed.substring(3));
      if (bytes.length < 28) throw const FormatException();
      final plaintext = _crypt(
        bytes.sublist(12, bytes.length - 16),
        utf8.encode(aad),
        bytes.sublist(0, 12),
        bytes.sublist(bytes.length - 16),
        decrypt: true,
      );
      return Ok(utf8.decode(plaintext));
    } on FormatException {
      return err(FailureCode.invalidArgument, 'Invalid encrypted column');
    } on StateError {
      return err(
        FailureCode.invalidArgument,
        'Encrypted column authentication failed',
      );
    }
  }

  Uint8List _crypt(
    List<int> input,
    List<int> aad,
    List<int> nonce,
    Uint8List tag, {
    required bool decrypt,
  }) {
    final memory = _Memory();
    Pointer<Void> algorithm = nullptr;
    Pointer<Void> key = nullptr;
    try {
      final algorithmOut = memory
          .allocate(sizeOf<IntPtr>())
          .cast<Pointer<Void>>();
      _check(_open(algorithmOut, memory.wide('AES'), nullptr, 0));
      algorithm = algorithmOut.value;
      final mode = memory.wide('ChainingModeGCM');
      _check(
        _setProperty(
          algorithm,
          memory.wide('ChainingMode'),
          mode.cast(),
          32,
          0,
        ),
      );
      final keyOut = memory.allocate(sizeOf<IntPtr>()).cast<Pointer<Void>>();
      // CNG allocates the key object when pbKeyObject is NULL (Windows 7+).
      _check(
        _generateKey(
          algorithm,
          keyOut,
          nullptr,
          0,
          memory.bytes(_key),
          _key.length,
          0,
        ),
      );
      key = keyOut.value;
      final info = memory.allocate(sizeOf<_AuthInfo>()).cast<_AuthInfo>();
      final tagBuffer = memory.bytes(tag);
      info.ref
        ..size = sizeOf<_AuthInfo>()
        ..version = 1
        ..nonce = memory.bytes(nonce)
        ..nonceLength = nonce.length
        ..aad = memory.bytes(aad)
        ..aadLength = aad.length
        ..tag = tagBuffer
        ..tagLength = tag.length;
      final output = memory.allocate(input.isEmpty ? 1 : input.length);
      final written = memory.allocate(4).cast<Uint32>();
      _check(
        (decrypt ? _decrypt : _encrypt)(
          key,
          memory.bytes(input),
          input.length,
          info.cast(),
          nullptr,
          0,
          output,
          input.length,
          written,
          0,
        ),
      );
      if (!decrypt) tag.setAll(0, tagBuffer.asTypedList(tag.length));
      return Uint8List.fromList(output.asTypedList(written.value));
    } finally {
      if (key != nullptr) _destroyKey(key);
      if (algorithm != nullptr) _close(algorithm, 0);
      memory.release();
    }
  }
}

final class _AuthInfo extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int version;
  external Pointer<Uint8> nonce;
  @Uint32()
  external int nonceLength;
  external Pointer<Uint8> aad;
  @Uint32()
  external int aadLength;
  external Pointer<Uint8> tag;
  @Uint32()
  external int tagLength;
  external Pointer<Uint8> macContext;
  @Uint32()
  external int macContextLength;
  @Uint32()
  external int aadProcessed;
  @Uint64()
  external int dataProcessed;
  @Uint32()
  external int flags;
}

final _bcrypt = DynamicLibrary.open('bcrypt.dll');
final _kernel = DynamicLibrary.open('kernel32.dll');
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
final _open = _bcrypt
    .lookupFunction<
      Int32 Function(
        Pointer<Pointer<Void>>,
        Pointer<Uint16>,
        Pointer<Uint16>,
        Uint32,
      ),
      int Function(
        Pointer<Pointer<Void>>,
        Pointer<Uint16>,
        Pointer<Uint16>,
        int,
      )
    >('BCryptOpenAlgorithmProvider');
final _setProperty = _bcrypt
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Uint16>,
        Pointer<Uint8>,
        Uint32,
        Uint32,
      ),
      int Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint8>, int, int)
    >('BCryptSetProperty');
final _generateKey = _bcrypt
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Pointer<Void>>,
        Pointer<Uint8>,
        Uint32,
        Pointer<Uint8>,
        Uint32,
        Uint32,
      ),
      int Function(
        Pointer<Void>,
        Pointer<Pointer<Void>>,
        Pointer<Uint8>,
        int,
        Pointer<Uint8>,
        int,
        int,
      )
    >('BCryptGenerateSymmetricKey');
typedef _CryptNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Uint32,
      Pointer<Void>,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint32>,
      Uint32,
    );
typedef _Crypt =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint32>,
      int,
    );
final _encrypt = _bcrypt.lookupFunction<_CryptNative, _Crypt>('BCryptEncrypt');
final _decrypt = _bcrypt.lookupFunction<_CryptNative, _Crypt>('BCryptDecrypt');
final _destroyKey = _bcrypt
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'BCryptDestroyKey',
    );
final _close = _bcrypt
    .lookupFunction<
      Int32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)
    >('BCryptCloseAlgorithmProvider');
final _random = _bcrypt
    .lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Uint32),
      int Function(Pointer<Void>, Pointer<Uint8>, int, int)
    >('BCryptGenRandom');

void _check(int status) {
  if (status < 0) throw StateError('Windows cryptographic operation failed');
}

Uint8List _randomBytes(int length) {
  final memory = _Memory();
  try {
    final bytes = memory.allocate(length);
    _check(_random(nullptr, bytes, length, 2));
    return Uint8List.fromList(bytes.asTypedList(length));
  } finally {
    memory.release();
  }
}

final class _Memory {
  final _blocks = <(Pointer<Uint8>, int)>[];
  Pointer<Uint8> allocate(int length) {
    final pointer = _alloc(_getHeap(), 8, length);
    if (pointer == nullptr) throw StateError('Native allocation failed');
    _blocks.add((pointer, length));
    return pointer;
  }

  Pointer<Uint8> bytes(List<int> bytes) {
    final pointer = allocate(bytes.isEmpty ? 1 : bytes.length);
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    return pointer;
  }

  Pointer<Uint16> wide(String value) {
    final pointer = allocate((value.length + 1) * 2).cast<Uint16>();
    pointer.asTypedList(value.length).setAll(0, value.codeUnits);
    return pointer;
  }

  void release() {
    for (final (pointer, length) in _blocks.reversed) {
      pointer.asTypedList(length).fillRange(0, length, 0);
      _free(_getHeap(), 0, pointer.cast());
    }
    _blocks.clear();
  }
}
