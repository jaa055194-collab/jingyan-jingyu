import 'package:jingyu_host/src/accounts/accounts_store.dart';
import 'package:jingyu_host/src/audit/audit_log.dart';
import 'package:test/test.dart';

Map<String, Object?> _account(String id, String name) => {
  'id': id,
  'displayName': name,
  'kind': 'human',
  'operator': null,
  'isAdmin': false,
  'disabled': false,
  'passwordHash': r'$v1$pbkdf2-sha256$600000$salt$digest',
  'failedPasswords': 0,
  'lockedUntil': 0,
};

/// Shared by the memory and SQL adapters using complete domain rows.
void accountsStoreContract(String name, AccountsStore Function() create) {
  group('AccountsStore $name', () {
    test('transactions serialize concurrent read/modify/write', () async {
      final store = create();
      await Future.wait(
        List.generate(
          20,
          (_) => store.transaction((state) async {
            final n = state.accounts.length;
            await Future<void>.delayed(Duration.zero);
            state.accounts['a$n'] = _account('a$n', 'account');
          }),
        ),
      );
      expect((await store.snapshot()).accounts.length, 20);
    });
    test(
      'throw rolls back every collection and queue remains usable',
      () async {
        final store = create();
        await expectLater(
          store.transaction((state) async {
            state.accounts['a'] = _account('a', 'lost');
            state.devices['d'] = {
              'id': 'd',
              'account': 'a',
              'deviceName': 'lost',
              'accessHash': 'a' * 64,
              'refreshHash': 'b' * 64,
              'accessExpires': 100,
              'refreshExpires': 200,
              'lastUsedAt': 0,
            };
            state.invites['i'] = {
              'id': 'i',
              'codeHash': 'c' * 64,
              'expiresAt': 100,
              'maxUses': 1,
              'usedCount': 0,
              'revokedAt': null,
            };
            throw StateError('rollback');
          }),
          throwsStateError,
        );
        final snapshot = await store.snapshot();
        expect(snapshot.accounts, isEmpty);
        expect(snapshot.devices, isEmpty);
        expect(snapshot.invites, isEmpty);
        await store.transaction((s) async {
          s.accounts['ok'] = _account('ok', 'kept');
        });
        expect((await store.snapshot()).accounts.keys, ['ok']);
      },
    );
    test('transactionWithAudit commits state and audit together', () async {
      final store = create();
      final entry = AuditEntry(
        at: DateTime.utc(2026, 11, 23),
        actorId: 'actor',
        action: 'account.ai.remove',
        targetKind: 'account',
        targetId: 'a',
      );
      await store.transactionWithAudit((state) {
        state.accounts['a'] = _account('a', 'kept');
      }, audit: (before, after) => [entry]);
      expect((await store.snapshot()).accounts.keys, ['a']);
      if (store is InMemoryAccountsStore) {
        expect(store.auditEntries, [entry]);
      }
    });
    test(
      'transactionWithAudit rolls state back when audit construction fails',
      () async {
        final store = create();
        await expectLater(
          store.transactionWithAudit(
            (state) {
              state.accounts['a'] = _account('a', 'lost');
            },
            audit: (before, after) => throw StateError('audit builder failure'),
          ),
          throwsStateError,
        );
        expect((await store.snapshot()).accounts, isEmpty);
      },
    );
    test(
      'snapshots and retained transaction references cannot mutate committed state',
      () async {
        final store = create();
        late AccountsState retained;
        await store.transaction((s) async {
          retained = s;
          s.accounts['a'] = _account('a', 'kept');
        });
        retained.accounts['a']!['displayName'] = 'changed';
        final snapshot = await store.snapshot();
        snapshot.accounts['a']!['displayName'] = 'also changed';
        expect((await store.snapshot()).accounts['a']!['displayName'], 'kept');
      },
    );
  });
}
