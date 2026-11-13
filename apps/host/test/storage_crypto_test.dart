import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/key_provider.dart';
import 'package:test/test.dart';

Uint8List hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);

void main() {
  group('Windows AES-256-GCM', () {
    test('decrypts NIST zero-key, zero-IV, empty-plaintext vector', () {
      final cipher = AesGcmColumnCipher(Uint8List(32));
      // NIST GCM AES-256: IV=0^96, P=A=empty, T below.
      final sealed =
          'v1:${base64Encode([...Uint8List(12), ...hex('530f8afbc74536b9a963b4f1c4cb738b')])}';
      expect(cipher.decrypt(sealed, aad: '').value, '');
    });

    test('roundtrips UTF-8 and empty plaintext with fresh 96-bit nonces', () {
      final cipher = AesGcmColumnCipher(List.filled(32, 7));
      for (final text in ['', '鲸言鲸语 🔐\u0000 private body']) {
        final first = cipher.encrypt(text, aad: 'messages:body:42');
        final second = cipher.encrypt(text, aad: 'messages:body:42');
        expect(first, startsWith('v1:'));
        final firstBytes = base64Decode(first.substring(3));
        final secondBytes = base64Decode(second.substring(3));
        expect(firstBytes.length, 12 + utf8.encode(text).length + 16);
        expect(firstBytes.take(12), isNot(orderedEquals(secondBytes.take(12))));
        expect(cipher.decrypt(first, aad: 'messages:body:42').value, text);
      }
    });

    test('rejects changed nonce, ciphertext, tag, AAD and key', () {
      final cipher = AesGcmColumnCipher(List.filled(32, 7));
      final sealed = cipher.encrypt('secret', aad: 'messages:body:42');
      final bytes = base64Decode(sealed.substring(3));
      for (final index in [0, 12, bytes.length - 1]) {
        final changed = Uint8List.fromList(bytes)..[index] ^= 1;
        expect(
          cipher
              .decrypt('v1:${base64Encode(changed)}', aad: 'messages:body:42')
              .isErr,
          isTrue,
        );
      }
      expect(cipher.decrypt(sealed, aad: 'messages:body:43').isErr, isTrue);
      expect(
        AesGcmColumnCipher(
          List.filled(32, 8),
        ).decrypt(sealed, aad: 'messages:body:42').isErr,
        isTrue,
      );
    });

    test('rejects malformed envelopes and invalid key sizes', () {
      final cipher = AesGcmColumnCipher(List.filled(32, 7));
      for (final sealed in ['', 'v2:AAAA', 'v1:!', 'v1:AA==']) {
        expect(cipher.decrypt(sealed, aad: '').isErr, isTrue);
      }
      expect(() => AesGcmColumnCipher(List.filled(31, 0)), throwsArgumentError);
      expect(
        () => AesGcmColumnCipher([...List.filled(31, 0), 256]),
        throwsArgumentError,
      );
    });
  }, skip: !Platform.isWindows ? 'BCrypt requires Windows' : false);

  test('disposed AES cipher rejects further use', () {
    final cipher = AesGcmColumnCipher(List.filled(32, 7));
    final sealed = cipher.encrypt('secret', aad: 'row');
    cipher.dispose();
    cipher.dispose();
    expect(() => cipher.encrypt('secret', aad: 'row'), throwsStateError);
    expect(() => cipher.decrypt(sealed, aad: 'row'), throwsStateError);
  }, skip: !Platform.isWindows ? 'BCrypt requires Windows' : false);

  group('key providers', () {
    test(
      'environment key is explicitly injected and must decode to 32 bytes',
      () async {
        final bytes = List.generate(32, (index) => index);
        expect(await EnvKeyProvider(base64Encode(bytes)).loadKek(), bytes);
        await expectLater(EnvKeyProvider('!').loadKek(), throwsFormatException);
        await expectLater(
          EnvKeyProvider('AA==').loadKek(),
          throwsFormatException,
        );
      },
    );

    test(
      'DPAPI persists only protected bytes and reloads the same KEK',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'jingyu-dpapi-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/keys/kek.dpapi');
        final first = await DpapiKeyProvider(path: file.path).loadKek();
        final second = await DpapiKeyProvider(path: file.path).loadKek();
        expect(first.length, 32);
        expect(second, first);
        final persisted = await file.readAsBytes();
        expect(persisted, isNot(orderedEquals(first)));
        expect(base64Encode(persisted), isNot(contains(base64Encode(first))));
        final other = await DpapiKeyProvider(
          path: '${directory.path}/other',
        ).loadKek();
        expect(other, isNot(orderedEquals(first)));
      },
      skip: !Platform.isWindows ? 'DPAPI requires Windows' : false,
    );

    test(
      'DPAPI rejects corrupted persisted keys without replacing them',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'jingyu-dpapi-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/kek.dpapi');
        await DpapiKeyProvider(path: file.path).loadKek();
        final corrupted = await file.readAsBytes();
        corrupted[0] ^= 0xff;
        await file.writeAsBytes(corrupted, flush: true);
        await expectLater(
          DpapiKeyProvider(path: file.path).loadKek(),
          throwsStateError,
        );
        expect(await file.readAsBytes(), corrupted);
        await file.writeAsBytes([1, 2, 3], flush: true);
        await expectLater(
          DpapiKeyProvider(path: file.path).loadKek(),
          throwsStateError,
        );
      },
      skip: !Platform.isWindows ? 'DPAPI requires Windows' : false,
    );
  });
}
