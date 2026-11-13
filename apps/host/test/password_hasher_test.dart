@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';

import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:test/test.dart';

// Independent Python hashlib.pbkdf2_hmac('sha256', UTF8 password,
// bytes(range(16)), 600000, 32) reference. Hex avoids opaque fixture text.
String referenceHash({String rounds = '600000'}) {
  const hex =
      '5aa1fcda06d4857448a56e5cccb83b1b826ef743e983a4f57ae9c19a485c01d7';
  final key = [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  final salt = base64Url
      .encode(List.generate(16, (i) => i))
      .replaceAll('=', '');
  final digest = base64Url.encode(key).replaceAll('=', '');
  return '\$v1\$pbkdf2-sha256\$$rounds\$$salt\$$digest';
}

void main() {
  group('PasswordHasher', () {
    // Catches a wrong PRF, UTF-8 encoding, block counter or iteration count.
    test('verifies the independent 600000-round UTF-8 PBKDF2 fixture', () {
      expect(PasswordHasher().verify('鲸语🔐 password', referenceHash()), isTrue);
    });

    test('writes a versioned 600000-round hash with a 32-byte key', () {
      final parts = PasswordHasher().hash('password').split(r'$');
      expect(parts, hasLength(6));
      expect(parts.take(4), ['', 'v1', 'pbkdf2-sha256', '600000']);
      expect(base64Url.decode(base64Url.normalize(parts[4])), hasLength(16));
      expect(base64Url.decode(base64Url.normalize(parts[5])), hasLength(32));
    });

    test('uses a different random salt for each hash', () {
      final hasher = PasswordHasher();
      final first = hasher.hash('same password');
      final second = hasher.hash('same password');
      expect(first.split(r'$')[4], isNot(second.split(r'$')[4]));
      expect(hasher.verify('same password', first), isTrue);
      expect(hasher.verify('same password', second), isTrue);
    });

    test(
      'verifies only the original password with exact whitespace and case',
      () {
        final hasher = PasswordHasher();
        final encoded = referenceHash();
        for (final password in [
          'incorrect',
          '鲸语🔐 Password',
          '鲸语🔐 password ',
        ]) {
          expect(hasher.verify(password, encoded), isFalse);
        }
      },
    );

    test('rejects malformed encodings without throwing', () {
      final hasher = PasswordHasher();
      final valid = referenceHash();
      final parts = valid.split(r'$');
      for (final encoded in [
        '',
        'plaintext',
        valid.substring(1),
        '$valid\$extra',
        valid.replaceFirst('v1', 'v2'),
        valid.replaceFirst('pbkdf2-sha256', 'unknown'),
        valid.replaceFirst(parts[4], 'short'),
        valid.replaceFirst(parts[5], 'short'),
        valid.replaceFirst(parts[4], '!' * 22),
        valid.replaceFirst(parts[4], 'A' * 100),
        valid.replaceFirst(parts[5], 'A' * 44),
        'A' * 10000,
      ]) {
        expect(hasher.verify('password', encoded), isFalse, reason: encoded);
      }
    });

    test(
      'rejects weak, excessive and noncanonical rounds before derivation',
      () {
        for (final rounds in [
          '0',
          '1',
          '599999',
          '1000001',
          '999999999999999999999',
          '-600000',
          '+600000',
          '0600000',
          '600000.0',
        ]) {
          expect(
            PasswordHasher().verify('password', referenceHash(rounds: rounds)),
            isFalse,
            reason: rounds,
          );
        }
      },
    );
  });
}
