import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AiIdentityResolver alice;
  late AiIdentityResolver bob;
  late AiIdentityResolver admin;
  final aiAccount = AccountId.parse('ai_account');
  const migrations = [
    ...allMigrations,
    ...accountsMigrations,
    aiIdentityMigration,
  ];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ai-identity-');
    db = await SqliteDatabase.open(
      '${directory.path}/identity.sqlite',
      migrations: migrations,
    );
    // Real canonical account schema; no authentication or password hashing.
    for (final id in ['alice', 'bob', 'admin']) {
      await db.execute(
        'INSERT INTO account (id, display_name, kind, is_admin, disabled, '
        'password_hash, failed_passwords, locked_until) '
        "VALUES (?, ?, 'human', ?, 0, 'unused-fixture', 0, 0)",
        [id, id, id == 'admin' ? 1 : 0],
      );
    }
    await db.execute(
      'INSERT INTO account (id, display_name, kind, is_admin, disabled, '
      'password_hash, failed_passwords, locked_until) '
      "VALUES (?, 'AI', 'ai', 0, 0, NULL, 0, 0)",
      [aiAccount.value],
    );
    await db.execute(
      'INSERT INTO ai_operator (ai_id, operator_id) VALUES (?, ?)',
      [aiAccount.value, 'alice'],
    );
    alice = AiIdentityResolver.forOwner(ownerId: 'alice', db: db);
    bob = AiIdentityResolver.forOwner(ownerId: 'bob', db: db);
    admin = AiIdentityResolver.forOwner(ownerId: 'admin', db: db);
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test('register persists an independent typed profile identity', () async {
    final identity = (await alice.register(aiAccount)).value;
    expect(identity.profileId, isA<AiId>());
    expect(identity.profileId.value, isNot(aiAccount.value));
    expect(identity.profileId, isNot(aiAccount));
    expect(identity.aiAccountId, aiAccount);
    expect(identity.ownerAccountId, AccountId.parse('alice'));
    final resolved = (await alice.resolve(identity.profileId)).value;
    expect(resolved.profileId, identity.profileId);
    expect(resolved.aiAccountId, aiAccount);
    expect(resolved.ownerAccountId, AccountId.parse('alice'));
    expect(
      (await alice.resolve(AiId.parse(aiAccount.value))).failureOrNull?.code,
      FailureCode.notFound,
    );
  });

  test('register is idempotent including concurrent requests', () async {
    final results = await Future.wait(
      List.generate(6, (_) => alice.register(aiAccount)),
    );
    final id = results.first.value.profileId;
    expect(results.map((r) => r.value.profileId), everyElement(id));
    expect((await db.query('SELECT id FROM ai_profile')).length, 1);
  });

  test('mapping survives database and resolver restart', () async {
    final id = (await alice.register(aiAccount)).value.profileId;
    await db.close();
    db = await SqliteDatabase.open(
      '${directory.path}/identity.sqlite',
      migrations: migrations,
    );
    alice = AiIdentityResolver.forOwner(ownerId: 'alice', db: db);
    expect((await alice.resolve(id)).value.aiAccountId, aiAccount);
    expect((await alice.register(aiAccount)).value.profileId, id);
  });

  test('resolve never implicitly registers an account', () async {
    expect(
      (await alice.resolve(AiId.parse('missing'))).failureOrNull?.code,
      FailureCode.notFound,
    );
    expect(await db.query('SELECT id FROM ai_profile'), isEmpty);
  });

  test('other owners and admins cannot register or resolve the AI', () async {
    final id = (await alice.register(aiAccount)).value.profileId;
    for (final resolver in [bob, admin]) {
      expect(
        (await resolver.register(aiAccount)).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await resolver.resolve(id)).failureOrNull?.code,
        FailureCode.notFound,
      );
    }
    expect((await db.query('SELECT id FROM ai_profile')).length, 1);
  });

  test('human and missing accounts cannot acquire a profile', () async {
    // Even a malformed operator association must not make a human into an AI.
    await db.execute(
      'INSERT INTO ai_operator (ai_id, operator_id) VALUES (?, ?)',
      ['bob', 'alice'],
    );
    for (final id in ['alice', 'bob', 'missing']) {
      expect(
        (await alice.register(AccountId.parse(id))).failureOrNull?.code,
        FailureCode.notFound,
      );
    }
    expect(await db.query('SELECT id FROM ai_profile'), isEmpty);
  });

  test('disabled AI cannot register or resolve an existing mapping', () async {
    final id = (await alice.register(aiAccount)).value.profileId;
    await db.execute('UPDATE account SET disabled = 1 WHERE id = ?', [
      aiAccount.value,
    ]);
    expect((await alice.resolve(id)).failureOrNull?.code, FailureCode.notFound);
    expect(
      (await alice.register(aiAccount)).failureOrNull?.code,
      FailureCode.notFound,
    );
  });

  test('operator revocation is checked for every operation', () async {
    final id = (await alice.register(aiAccount)).value.profileId;
    await db.execute('DELETE FROM ai_operator WHERE ai_id = ?', [
      aiAccount.value,
    ]);
    expect((await alice.resolve(id)).failureOrNull?.code, FailureCode.notFound);
    expect(
      (await alice.register(aiAccount)).failureOrNull?.code,
      FailureCode.notFound,
    );
  });

  test(
    'ownership changes immediately update access and resolved owner',
    () async {
      final id = (await alice.register(aiAccount)).value.profileId;
      await db.execute(
        'UPDATE ai_operator SET operator_id = ? WHERE ai_id = ?',
        ['bob', aiAccount.value],
      );
      expect(
        (await alice.resolve(id)).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await alice.register(aiAccount)).failureOrNull?.code,
        FailureCode.notFound,
      );
      final identity = (await bob.resolve(id)).value;
      expect(identity.ownerAccountId, AccountId.parse('bob'));
      expect((await bob.register(aiAccount)).value.profileId, id);
    },
  );

  test('account kind is rechecked when resolving an existing profile', () async {
    final id = (await alice.register(aiAccount)).value.profileId;
    await db.execute(
      "UPDATE account SET kind = 'human', password_hash = 'unused' WHERE id = ?",
      [aiAccount.value],
    );
    expect((await alice.resolve(id)).failureOrNull?.code, FailureCode.notFound);
  });

  test(
    'profile migration enforces unique account and account foreign key',
    () async {
      await alice.register(aiAccount);
      await expectLater(
        db.execute('INSERT INTO ai_profile (id, account_id) VALUES (?, ?)', [
          'duplicate',
          aiAccount.value,
        ]),
        throwsException,
      );
      await expectLater(
        db.execute('INSERT INTO ai_profile (id, account_id) VALUES (?, ?)', [
          'orphan',
          'missing',
        ]),
        throwsException,
      );
    },
  );
}
