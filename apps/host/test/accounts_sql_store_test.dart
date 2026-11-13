import 'dart:async';
import 'dart:io';

import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/accounts_store.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

import 'accounts_store_contract.dart';

Map<String, Object?> account(String id, {String? operator}) => {
  'id': id,
  'displayName': "O'Brien'); DROP TABLE account;--",
  'kind': operator == null ? 'human' : 'ai',
  'operator': operator,
  'isAdmin': false,
  'disabled': false,
  'passwordHash': operator == null
      ? r'$v1$pbkdf2-sha256$600000$salt$digest'
      : null,
  'failedPasswords': 0,
  'lockedUntil': 0,
};
Map<String, Object?> invite(String id) => {
  'id': id,
  'codeHash': 'a' * 64,
  'expiresAt': 200000,
  'maxUses': 20,
  'usedCount': 0,
  'revokedAt': null,
};
Map<String, Object?> device(String id) => {
  'id': id,
  'account': 'human',
  'deviceName': "user's device",
  'accessHash': 'b' * 64,
  'refreshHash': 'c' * 64,
  'accessExpires': 10000,
  'refreshExpires': 20000,
  'lastUsedAt': 1,
};

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late SqlAccountsStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('m02-sql-');
    db = await SqliteDatabase.open('${directory.path}/host.sqlite');
    store = SqlAccountsStore(db);
    await store.start();
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  accountsStoreContract('SQLite', () => store);

  test(
    'bound values round trip and relational rows reconstruct after restart',
    () async {
      late AccountsState retained;
      await store.transaction((s) {
        retained = s;
        s.accounts['human'] = account('human');
        s.accounts['ai'] = account('ai', operator: 'human');
        s.devices['device'] = device('device');
        s.invites['invite'] = invite('invite');
      });
      retained.accounts['human']!['displayName'] = 'mutated';
      await db.close();
      db = await SqliteDatabase.open('${directory.path}/host.sqlite');
      store = SqlAccountsStore(db);
      await store.start();
      await store.start();
      final state = await store.snapshot();
      expect(state.accounts['human'], account('human'));
      expect(state.accounts['ai'], account('ai', operator: 'human'));
      expect(state.devices['device'], device('device'));
      expect(state.invites['invite'], invite('invite'));
      expect(await db.query('SELECT operator_id FROM ai_operator'), [
        {'operator_id': 'human'},
      ]);
      expect(await db.query('SELECT token_hash FROM refresh_token'), [
        {'token_hash': 'c' * 64},
      ]);
      expect((await db.query('PRAGMA foreign_key_check')), isEmpty);
    },
  );

  test(
    'callback failure discards every collection and queue recovers',
    () async {
      await expectLater(
        store.transaction((s) {
          s.accounts['human'] = account('human');
          s.invites['invite'] = invite('invite');
          throw StateError('abort');
        }),
        throwsStateError,
      );
      expect((await store.snapshot()).accounts, isEmpty);
      expect((await store.snapshot()).invites, isEmpty);
      await store.transaction((s) => s.accounts['human'] = account('human'));
      expect((await store.snapshot()).accounts.keys, ['human']);
    },
  );

  test('SQL failure rolls back earlier deletes and upserts atomically', () async {
    await store.transaction((s) {
      s.accounts['human'] = account('human');
      s.devices['device'] = device('device');
    });
    // Failure occurs late, after account upsert and device deletion.
    await db.execute(
      "CREATE TRIGGER reject_invite BEFORE INSERT ON invite BEGIN SELECT RAISE(ABORT, 'test failure'); END",
    );
    await expectLater(
      store.transaction((s) {
        s.accounts['human']!['displayName'] = 'must roll back';
        s.devices.clear();
        s.invites['invite'] = invite('invite');
      }),
      throwsA(anything),
    );
    final state = await store.snapshot();
    expect(state.accounts['human'], account('human'));
    expect(state.devices['device'], device('device'));
    expect(state.invites, isEmpty);
  });

  test(
    'separate adapters serialize 20 read modify writes on one database',
    () async {
      await store.transaction((s) => s.invites['invite'] = invite('invite'));
      final other = SqlAccountsStore(db);
      await Future.wait(
        List.generate(
          20,
          (i) => (i.isEven ? store : other).transaction((s) async {
            final count = s.invites['invite']!['usedCount'] as int;
            await Future<void>.delayed(Duration.zero);
            s.invites['invite']!['usedCount'] = count + 1;
          }),
        ),
      );
      expect((await store.snapshot()).invites['invite']!['usedCount'], 20);
    },
  );

  test(
    'device removal deletes refresh credentials and account removal clears relations',
    () async {
      await store.transaction((s) {
        s.accounts['human'] = account('human');
        s.accounts['ai'] = account('ai', operator: 'human');
        s.devices['device'] = device('device');
      });
      await store.transaction((s) => s.devices.clear());
      expect(await db.query('SELECT * FROM refresh_token'), isEmpty);
      await store.transaction((s) => s.accounts.clear());
      expect(await db.query('SELECT * FROM ai_operator'), isEmpty);
      expect((await store.snapshot()).accounts, isEmpty);
    },
  );

  test('plaintext credentials are rejected at the storage boundary', () async {
    await expectLater(
      store.transaction((s) {
        s.accounts['human'] = account('human');
        s.devices['device'] = device('device')..['accessHash'] = 'raw-token';
      }),
      throwsArgumentError,
    );
    await expectLater(
      store.transaction((s) {
        s.invites['invite'] = invite('invite')..['codeHash'] = 'raw-invite';
      }),
      throwsArgumentError,
    );
    expect((await store.snapshot()).accounts, isEmpty);
    expect((await store.snapshot()).devices, isEmpty);
    expect((await store.snapshot()).invites, isEmpty);
  });

  test(
    'invalid account relation fails without committing another row',
    () async {
      await expectLater(
        store.transaction((s) {
          s.accounts['ai'] = account('ai', operator: 'missing');
          s.invites['invite'] = invite('invite');
        }),
        throwsA(anything),
      );
      expect((await store.snapshot()).toJson(), {
        'accounts': {},
        'devices': {},
        'invites': {},
      });
    },
  );
}
