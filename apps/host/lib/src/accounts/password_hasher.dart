import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

abstract class PasswordHasher {
  Future<String> hash(String password);
  Future<bool> verify(String password, String encoded);
}

/// PBKDF2-HMAC-SHA256 fallback: crypto provides all cryptographic primitives.
/// Salt is 128 bits; derived key is 256 bits. Encoded values are self describing.
class Pbkdf2PasswordHasher implements PasswordHasher {
  Pbkdf2PasswordHasher({this.iterations = 600000}) {
    if (iterations < 600000) {
      throw ArgumentError.value(iterations, 'iterations');
    }
  }
  final int iterations;
  final Random _random = Random.secure();

  @override
  Future<String> hash(String password) {
    final rounds = iterations;
    return Isolate.run(
      () => Pbkdf2PasswordHasher(iterations: rounds)._hash(password),
    );
  }

  String _hash(String password) {
    final salt = List<int>.generate(16, (_) => _random.nextInt(256));
    final key = _derive(password, salt, iterations);
    return 'pbkdf2-sha256\$$iterations\$${base64Url.encode(salt)}\$${base64Url.encode(key)}';
  }

  @override
  Future<bool> verify(String password, String encoded) =>
      Isolate.run(() => Pbkdf2PasswordHasher()._verify(password, encoded));

  bool _verify(String password, String encoded) {
    try {
      final parts = encoded.split('\$');
      if (parts.length != 4 || parts[0] != 'pbkdf2-sha256') return false;
      final rounds = int.tryParse(parts[1]);
      if (rounds == null || rounds < 600000) return false;
      final salt = base64Url.decode(parts[2]);
      final expected = base64Url.decode(parts[3]);
      if (salt.length != 16 || expected.length != 32) return false;
      final actual = _derive(password, salt, rounds);
      var difference = 0;
      for (var i = 0; i < actual.length; i++) {
        difference |= actual[i] ^ expected[i];
      }
      return difference == 0;
    } on FormatException {
      return false;
    }
  }

  List<int> _derive(String password, List<int> salt, int rounds) {
    final hmac = Hmac(sha256, utf8.encode(password));
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final result = Uint8List.fromList(u);
    for (var round = 1; round < rounds; round++) {
      u = hmac.convert(u).bytes;
      for (var i = 0; i < 32; i++) {
        result[i] ^= u[i];
      }
    }
    return result;
  }
}

String secretHash(String value) =>
    sha256.convert(utf8.encode(value)).toString();
String randomSecret(int bytes) => base64Url
    .encode(List<int>.generate(bytes, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');
