import 'dart:convert';

import 'package:flutter/services.dart';

/// Sanitized local-vault failure. Never carries a native message, record,
/// credential or file path, so callers can surface it without leaking secrets.
class AndroidPrivateAiVaultException implements Exception {
  const AndroidPrivateAiVaultException();

  @override
  String toString() => 'AndroidPrivateAiVaultException';
}

/// Android-only encrypted record store for one owner's private AI data.
///
/// The caller supplies a scope that is exactly 64 lowercase hex characters
/// (SHA-256 of host origin, account, device and AI account). Records are JSON
/// maps bounded to 1 MiB; encryption, atomic replacement and Keystore key
/// handling live in the native `PrivateAiVault`. This adapter adds no storage
/// of its own and never logs record content.
class AndroidPrivateAiVault {
  const AndroidPrivateAiVault();

  static const MethodChannel _channel = MethodChannel('jingyu/platform');

  /// Defensive bound for both directions; native enforces the same limit.
  static const int maxRecordBytes = 1024 * 1024;

  Future<Map<String, Object?>?> read(String scope) async {
    _checkScope(scope);
    final raw = await _invoke('readPrivateAiVault', {'scope': scope});
    if (raw == null) return null;
    if (raw is! Uint8List || raw.isEmpty || raw.length > maxRecordBytes) {
      throw const AndroidPrivateAiVaultException();
    }
    try {
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is! Map<String, Object?>) {
        throw const AndroidPrivateAiVaultException();
      }
      return decoded;
    } on AndroidPrivateAiVaultException {
      rethrow;
    } on Object {
      // Malformed or truncated ciphertext must not look like "no record".
      throw const AndroidPrivateAiVaultException();
    }
  }

  Future<void> write(String scope, Map<String, Object?> record) async {
    _checkScope(scope);
    final List<int> encoded;
    try {
      encoded = utf8.encode(jsonEncode(record));
    } on Object {
      throw const AndroidPrivateAiVaultException();
    }
    if (encoded.isEmpty || encoded.length > maxRecordBytes) {
      throw const AndroidPrivateAiVaultException();
    }
    await _invoke('writePrivateAiVault', {
      'scope': scope,
      'bytes': Uint8List.fromList(encoded),
    });
  }

  Future<void> remove(String scope) async {
    _checkScope(scope);
    await _invoke('removePrivateAiVault', {'scope': scope});
  }

  static void _checkScope(String scope) {
    if (scope.length != 64) throw const AndroidPrivateAiVaultException();
    for (final unit in scope.codeUnits) {
      final isDigit = unit >= 0x30 && unit <= 0x39;
      final isLowerHexLetter = unit >= 0x61 && unit <= 0x66;
      if (!isDigit && !isLowerHexLetter) {
        throw const AndroidPrivateAiVaultException();
      }
    }
  }

  static Future<Object?> _invoke(
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException {
      throw const AndroidPrivateAiVaultException();
    } on MissingPluginException {
      throw const AndroidPrivateAiVaultException();
    }
  }
}
