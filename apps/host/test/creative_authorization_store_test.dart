import 'dart:io';

import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/creative/creative_migrations.dart';
import 'package:jingyu_host/src/creative/reports/reports_models.dart';
import 'package:jingyu_host/src/creative/sqlite_creative_authorization_store.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late SqliteDatabase database;
  late SqliteCreativeAuthorizationStore store;

  Future<void> addAccount(String id, String kind) => database.execute(
    'INSERT INTO account(id, display_name, kind, is_admin, disabled, password_hash, failed_passwords, locked_until) VALUES(?,?,?,?,?,?,?,?)',
    [id, id, kind, 0, 0, kind == 'human' ? 'x' : null, 0, 0],
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jingyu-creative-auth-');
    database = await SqliteDatabase.open(
      '${dir.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        aiIdentityMigration,
        ...creativeMigrations,
      ],
    );
    store = SqliteCreativeAuthorizationStore(database: database);
    await addAccount('owner1', 'human');
    await addAccount('ai-account1', 'ai');
    await database.execute(
      'INSERT INTO ai_operator(ai_id, operator_id) VALUES(?,?)',
      ['ai-account1', 'owner1'],
    );
    await database.execute(
      'INSERT INTO ai_profile(id, account_id) VALUES(?,?)',
      ['profile1', 'ai-account1'],
    );
  });

  tearDown(() async {
    await database.close();
    await dir.delete(recursive: true);
  });

  test('authorization scopes and radio consent start denied', () async {
    expect(
      await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'),
      isEmpty,
    );
    expect(
      await store.radioEnabledFor(
        ownerAccountId: 'owner1',
        aiProfileId: 'profile1',
      ),
      isFalse,
    );
  });

  test('scope grants replace atomically and empty scopes revoke', () async {
    await store.setAuthorization(
      ownerAccountId: 'owner1',
      aiProfileId: 'profile1',
      scopes: {CreativeScope.privateChat, CreativeScope.groupChat},
      radioEnabled: true,
    );
    expect(
      await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'),
      {CreativeScope.privateChat, CreativeScope.groupChat},
    );
    expect(
      await store.radioEnabledFor(
        ownerAccountId: 'owner1',
        aiProfileId: 'profile1',
      ),
      isTrue,
    );

    await store.setAuthorization(
      ownerAccountId: 'owner1',
      aiProfileId: 'profile1',
      scopes: {CreativeScope.moments},
      radioEnabled: false,
    );
    expect(
      await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'),
      {CreativeScope.moments},
    );
    expect(
      await store.radioEnabledFor(
        ownerAccountId: 'owner1',
        aiProfileId: 'profile1',
      ),
      isFalse,
    );

    await store.setAuthorization(
      ownerAccountId: 'owner1',
      aiProfileId: 'profile1',
      scopes: const {},
      radioEnabled: false,
    );
    expect(
      await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'),
      isEmpty,
    );
  });

  test('foreign profile cannot receive a grant', () async {
    await expectLater(
      store.setAuthorization(
        ownerAccountId: 'owner1',
        aiProfileId: 'not-owned',
        scopes: {CreativeScope.privateChat},
        radioEnabled: true,
      ),
      throwsA(isA<CreativeAuthorizationOwnershipException>()),
    );
    expect(
      await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'not-owned'),
      isEmpty,
    );
  });

  for (final account in ['ai-account1', 'owner1']) {
    test('disabled $account immediately hides persisted grants and rejects writes', () async {
      await store.setAuthorization(
        ownerAccountId: 'owner1',
        aiProfileId: 'profile1',
        scopes: {CreativeScope.privateChat},
        radioEnabled: true,
      );
      await database.execute('UPDATE account SET disabled=1 WHERE id=?', [account]);
      expect(
        await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'),
        isEmpty,
      );
      expect(
        await store.radioEnabledFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'),
        isFalse,
      );
      await expectLater(
        store.setAuthorization(
          ownerAccountId: 'owner1',
          aiProfileId: 'profile1',
          scopes: {CreativeScope.moments},
          radioEnabled: false,
        ),
        throwsA(isA<CreativeAuthorizationOwnershipException>()),
      );
      // Rejected writes must not destroy the previous owner-scoped snapshot.
      await database.execute('UPDATE account SET disabled=0 WHERE id=?', [account]);
      expect(
        await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'),
        {CreativeScope.privateChat},
      );
      expect(
        await store.radioEnabledFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'),
        isTrue,
      );
    });
  }

  test('operator transfer hides former owner grants and never inherits them', () async {
    await store.setAuthorization(
      ownerAccountId: 'owner1', aiProfileId: 'profile1',
      scopes: {CreativeScope.privateChat}, radioEnabled: true,
    );
    await addAccount('owner2', 'human');
    await database.execute('UPDATE ai_operator SET operator_id=? WHERE ai_id=?',
        ['owner2', 'ai-account1']);
    for (final owner in ['owner1', 'owner2']) {
      expect(await store.scopesFor(ownerAccountId: owner, aiProfileId: 'profile1'), isEmpty);
      expect(await store.radioEnabledFor(ownerAccountId: owner, aiProfileId: 'profile1'), isFalse);
    }
    await expectLater(
      store.setAuthorization(ownerAccountId: 'owner1', aiProfileId: 'profile1',
        scopes: {CreativeScope.moments}, radioEnabled: true),
      throwsA(isA<CreativeAuthorizationOwnershipException>()),
    );
    await store.setAuthorization(ownerAccountId: 'owner2', aiProfileId: 'profile1',
      scopes: {CreativeScope.groupChat}, radioEnabled: false);
    expect(await store.scopesFor(ownerAccountId: 'owner2', aiProfileId: 'profile1'),
        {CreativeScope.groupChat});
    expect(await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'), isEmpty);
  });

  test('revocation survives closing and reopening the SQLite connection', () async {
    await store.setAuthorization(ownerAccountId: 'owner1', aiProfileId: 'profile1',
      scopes: {CreativeScope.privateChat, CreativeScope.moments}, radioEnabled: true);
    await database.close();
    database = await SqliteDatabase.open('${dir.path}/host.sqlite', migrations: [
      ...allMigrations, ...accountsMigrations, aiIdentityMigration, ...creativeMigrations,
    ]);
    store = SqliteCreativeAuthorizationStore(database: database);
    expect(await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'),
        {CreativeScope.privateChat, CreativeScope.moments});
    expect(await store.radioEnabledFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'), isTrue);
    await store.setAuthorization(ownerAccountId: 'owner1', aiProfileId: 'profile1',
      scopes: {}, radioEnabled: false);
    await database.close();
    database = await SqliteDatabase.open('${dir.path}/host.sqlite', migrations: [
      ...allMigrations, ...accountsMigrations, aiIdentityMigration, ...creativeMigrations,
    ]);
    store = SqliteCreativeAuthorizationStore(database: database);
    expect(await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'), isEmpty);
    expect(await store.radioEnabledFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'), isFalse);
  });

  test('setAuthorization snapshots the caller scope set before queued transaction', () async {
    final scopes = <CreativeScope>{CreativeScope.privateChat};
    final pending = store.setAuthorization(ownerAccountId: 'owner1', aiProfileId: 'profile1',
      scopes: scopes, radioEnabled: true);
    scopes.clear();
    scopes.add(CreativeScope.moments);
    await pending;
    expect(await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'),
        {CreativeScope.privateChat});
  });

  test('failure writing radio consent rolls back scope deletion and inserts', () async {
    await store.setAuthorization(ownerAccountId: 'owner1', aiProfileId: 'profile1',
      scopes: {CreativeScope.privateChat}, radioEnabled: true);
    await database.execute('''
CREATE TRIGGER reject_radio_update BEFORE UPDATE ON creative_radio_authorizations
BEGIN SELECT RAISE(ABORT, 'test rollback'); END
''');
    await expectLater(
      store.setAuthorization(ownerAccountId: 'owner1', aiProfileId: 'profile1',
        scopes: {CreativeScope.moments}, radioEnabled: false),
      throwsA(isA<Exception>()),
    );
    expect(await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'),
        {CreativeScope.privateChat});
    expect(await store.radioEnabledFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'), isTrue);
  });

  test('authorization store does not expose another owner profile', () async {
    expect(
      await store.scopesFor(ownerAccountId: 'owner2', aiProfileId: 'profile1'),
      isEmpty,
    );
    expect(
      await store.radioEnabledFor(
        ownerAccountId: 'owner2',
        aiProfileId: 'profile1',
      ),
      isFalse,
    );
  });
}
