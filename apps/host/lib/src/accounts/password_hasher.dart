import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Versioned, salted password hashes for the standalone accounts boundary.
///
/// M02 permits only `crypto`. The offline Windows pub cache has no usable
/// pure-Dart Argon2id implementation; PBKDF2 with HMAC-SHA256 is the specified
/// fallback, with 600000 rounds. Salt and key use unpadded base64url.
///
/// Derivation is synchronous and CPU intensive. Callers serving concurrent
/// requests should schedule this work in a worker isolate.
class PasswordHasher {
  static const _rounds = 600000;
  static const _maxRounds = 1000000;
  static const _saltBytes = 16;
  static const _keyBytes = 32;
  static final _base64UrlCharacters = RegExp(r'^[A-Za-z0-9_-]+$');
  static final _roundCharacters = RegExp(r'^[1-9][0-9]{5,6}$');

  /// Shared admission gate: at most two CPU workers in this request isolate,
  /// including when several domains/hasher instances share the same host.
  static int _workers = 0;
  static final Queue<Completer<void>> _waiting = Queue<Completer<void>>();
  static Future<T> _worker<T>(T Function() derive) async {
    if (_workers >= 2) {
      final admitted = Completer<void>();
      _waiting.add(admitted);
      await admitted.future;
    } else {
      _workers++;
    }
    try {
      return await Isolate.run(derive);
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _workers--;
      }
    }
  }

  /// Worker closures capture only this stateless hasher and credential strings,
  /// never a domain, transaction, database handle, or request. HTTP admission
  /// limits bound request rates before work enters this shared worker queue.
  Future<String> hashAsync(String password) => _worker(() => hash(password));
  Future<bool> verifyAsync(String password, String encodedHash) =>
      _worker(() => verify(password, encodedHash));

  /// Produces `$v1$pbkdf2-sha256$rounds$salt$key` with a fresh secure salt.
  String hash(String password) {
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List.generate(_saltBytes, (_) => random.nextInt(256)),
    );
    final key = _derive(password, salt, _rounds);
    return '\$v1\$pbkdf2-sha256\$$_rounds\$${_encode(salt)}\$${_encode(key)}';
  }

  /// Returns false for mismatches, unsupported formats and invalid parameters.
  ///
  /// Validate all attacker-controlled lengths and rounds before doing expensive
  /// work. Supported salts are 16–64 bytes and keys are exactly 32 bytes.
  bool verify(String password, String encodedHash) {
    if (encodedHash.length > 160) return false;
    final parts = encodedHash.split(r'$');
    if (parts.length != 6 ||
        parts[0].isNotEmpty ||
        parts[1] != 'v1' ||
        parts[2] != 'pbkdf2-sha256' ||
        !_roundCharacters.hasMatch(parts[3])) {
      return false;
    }
    final rounds = int.tryParse(parts[3]);
    if (rounds == null || rounds < _rounds || rounds > _maxRounds) {
      return false;
    }
    final salt = _decode(parts[4], minBytes: _saltBytes, maxBytes: 64);
    final expected = _decode(
      parts[5],
      minBytes: _keyBytes,
      maxBytes: _keyBytes,
    );
    if (salt == null || expected == null) return false;

    final actual = _derive(password, salt, rounds);
    // Always examine all 32 bytes. No prefix-dependent early return.
    var difference = 0;
    for (var i = 0; i < _keyBytes; i++) {
      difference |= actual[i] ^ expected[i];
    }
    return difference == 0;
  }

  static String _encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static List<int>? _decode(
    String text, {
    required int minBytes,
    required int maxBytes,
  }) {
    if (text.length < (minBytes * 8 + 5) ~/ 6 ||
        text.length > (maxBytes * 8 + 5) ~/ 6 ||
        !_base64UrlCharacters.hasMatch(text)) {
      return null;
    }
    try {
      final bytes = base64Url.decode(base64Url.normalize(text));
      if (bytes.length < minBytes ||
          bytes.length > maxBytes ||
          _encode(bytes) != text) {
        return null;
      }
      return bytes;
    } on FormatException {
      return null;
    }
  }

  static Uint8List _derive(String password, List<int> salt, int rounds) {
    final prf = Hmac(sha256, utf8.encode(password));
    // The 32-byte key needs exactly one SHA-256 block, counter INT_32_BE(1).
    var u = prf.convert([...salt, 0, 0, 0, 1]).bytes;
    final key = Uint8List.fromList(u);
    for (var round = 1; round < rounds; round++) {
      u = prf.convert(u).bytes;
      for (var i = 0; i < _keyBytes; i++) {
        key[i] ^= u[i];
      }
    }
    return key;
  }
}
