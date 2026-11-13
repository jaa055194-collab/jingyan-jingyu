@Timeout(Duration(minutes: 10))
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:test/test.dart';

// Independent hashlib PBKDF2 fixture shared with password_hasher_test.
String fixtureHash() {
  const hex =
      '5aa1fcda06d4857448a56e5cccb83b1b826ef743e983a4f57ae9c19a485c01d7';
  final key = [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  String encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
  return '\$v1\$pbkdf2-sha256\$600000\$${encode(List.generate(16, (i) => i))}\$${encode(key)}';
}

void main() {
  late InMemoryAccountsStore store;
  late AccountsDomain domain;
  final id = AccountId.parse('human');
  const password = '鲸语🔐 password';
  setUp(() async {
    store = InMemoryAccountsStore();
    domain = AccountsDomain(
      store: store,
      clock: FakeClock(DateTime.utc(2026)),
      hasher: PasswordHasher(),
    );
    await store.transaction((s) {
      s.accounts[id.value] = {
        'id': id.value,
        'displayName': 'human',
        'kind': 'human',
        'operator': null,
        'isAdmin': false,
        'disabled': false,
        'passwordHash': fixtureHash(),
        'failedPasswords': 0,
        'lockedUntil': 0,
      };
    });
  });

  test(
    'password verification leaves event loop and account queue responsive',
    () async {
      var finished = false;
      final login = domain
          .login(id, password, deviceName: 'pc')
          .whenComplete(() => finished = true);
      await Future<void>.delayed(Duration.zero);
      final snapshot = await store.snapshot();
      final completedBeforeRead = finished;
      expect(snapshot.accounts.length, 1);
      expect((await login).isOk, isTrue);
      expect(
        completedBeforeRead,
        isFalse,
        reason:
            'PBKDF must run outside request isolate and account transaction',
      );
    },
  );

  test(
    'in-flight password verification cannot issue tokens after disable',
    () async {
      final login = domain.login(id, password, deviceName: 'pc');
      await Future<void>.delayed(Duration.zero);
      await store.transaction((s) => s.accounts[id.value]!['disabled'] = true);
      expect((await login).isErr, isTrue);
      expect((await store.snapshot()).devices, isEmpty);
    },
  );

  test('in-flight verification cannot accept a reset password hash', () async {
    final login = domain.login(id, password, deviceName: 'pc');
    await Future<void>.delayed(Duration.zero);
    await store.transaction(
      (s) => s.accounts[id.value]!['passwordHash'] = 'replaced-by-reset',
    );
    expect((await login).isErr, isTrue);
    expect((await store.snapshot()).devices, isEmpty);
  });

  for (final reset in [false, true]) {
    test(
      '${reset ? 'reset' : 'create'} revalidates admin bearer after hashing',
      () async {
        const bearer = 'abcdefghijklmnopqrstuv';
        final digest = sha256.convert(utf8.encode(bearer)).toString();
        await store.transaction((s) {
          s.accounts['admin'] = {
            ...s.accounts[id.value]!,
            'id': 'admin',
            'isAdmin': true,
          };
          s.devices['admin-device'] = {
            'id': 'admin-device',
            'account': 'admin',
            'deviceName': 'admin',
            'accessHash': digest,
            'refreshHash': digest,
            'accessExpires': DateTime.utc(2027).millisecondsSinceEpoch,
            'refreshExpires': DateTime.utc(2027).millisecondsSinceEpoch,
            'lastUsedAt': DateTime.utc(2026).millisecondsSinceEpoch,
          };
        });
        final session = (await domain.scope(bearer)).value;
        final pending = reset
            ? session.accounts.resetPassword(id, 'new password 123')
            : session.accounts.createHuman(
                displayName: 'new',
                password: 'new password 123',
              );
        await Future<void>.delayed(Duration.zero);
        await store.transaction((s) => s.devices.clear());
        expect((await pending).isErr, isTrue);
        final state = await store.snapshot();
        expect(state.accounts.length, 2);
        expect(state.accounts[id.value]!['passwordHash'], fixtureHash());
        expect(state.devices, isEmpty);
      },
    );
  }

  test(
    'concurrent bad verifications increment current counter and lock account',
    () async {
      final attempts = await Future.wait(
        List.generate(5, (_) => domain.login(id, 'wrong', deviceName: 'pc')),
      );
      expect(attempts.every((result) => result.isErr), isTrue);
      final account = (await store.snapshot()).accounts[id.value]!;
      expect(account['failedPasswords'], 5);
      expect(
        account['lockedUntil'],
        DateTime.utc(
          2026,
        ).add(const Duration(minutes: 15)).millisecondsSinceEpoch,
      );
      expect(
        (await domain.login(id, password, deviceName: 'pc')).isErr,
        isTrue,
      );
    },
  );
}
