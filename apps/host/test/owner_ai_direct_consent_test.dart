import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/social/conversation_preferences.dart';
import 'package:jingyu_host/src/social/conversation_preferences_migration.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_consent.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_migration.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/private_conversations.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

const consentMigrations = [
  ...allMigrations,
  ...accountsMigrations,
  ...socialMigrations,
  friendshipMigration,
  privateConversationMigration,
  conversationPreferencesMigration,
  aiIdentityMigration,
  ownerAiDirectMigration,
  ownerAiProfileInvalidationMigration,
];

void main() {
  late Directory dir;
  late SqliteDatabase db;
  late OwnerAiDirectConsent consent;
  late PrivateConversations direct;
  late ConversationPreferences prefs;
  final clock = FakeClock(DateTime.utc(2026, 11, 17));

  Future<void> account(String id, String kind) async {
    await db.execute(
      '''INSERT INTO account
(id,display_name,kind,is_admin,disabled,password_hash,failed_passwords,locked_until)
VALUES(?,?,?,0,0,?,0,0)''',
      [id, id, kind, kind == 'human' ? 'test' : null],
    );
  }

  Future<Map<String, Object?>> open([int revision = 0]) async {
    final result = await consent.open(
      ownerId: 'owner',
      aiProfileId: 'profile',
      expectedRevision: revision,
    );
    expect(result.isOk, isTrue);
    return result.value;
  }

  Future<void> reconnect() async {
    await db.close();
    db = await SqliteDatabase.open(
      '${dir.path}/host.sqlite',
      migrations: consentMigrations,
    );
    consent = OwnerAiDirectConsent(database: db, clock: clock);
    direct = PrivateConversations(db: db, clock: clock);
    prefs = ConversationPreferences(database: db);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('owner-ai-consent-');
    db = await SqliteDatabase.open(
      '${dir.path}/host.sqlite',
      migrations: consentMigrations,
    );
    consent = OwnerAiDirectConsent(database: db, clock: clock);
    direct = PrivateConversations(db: db, clock: clock);
    prefs = ConversationPreferences(database: db);
    await account('owner', 'human');
    await account('other', 'human');
    await account('ai-account', 'ai');
    await db.execute('INSERT INTO ai_operator(ai_id,operator_id) VALUES(?,?)', [
      'ai-account',
      'owner',
    ]);
    await db.execute('INSERT INTO ai_profile(id,account_id) VALUES(?,?)', [
      'profile',
      'ai-account',
    ]);
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test(
    'default off metadata is read-only; profile is not AI account; explicit grant is canonical',
    () async {
      final initial = (await consent.get(
        ownerId: 'owner',
        aiProfileId: 'profile',
      )).value;
      expect(initial['revision'], 0);
      expect(initial['enabled'], false);
      expect(initial['scope'], 'ownerTextOnly');
      expect(await db.query('SELECT * FROM owner_ai_direct_grants'), isEmpty);
      expect(
        (await consent.get(
          ownerId: 'owner',
          aiProfileId: 'ai-account',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await consent.get(
          ownerId: 'other',
          aiProfileId: 'profile',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await consent.get(
          ownerId: 'ai-account',
          aiProfileId: 'profile',
        )).isErr,
        true,
      );
      final granted = await open();
      expect(granted['revision'], 1);
      expect(granted['enabled'], true);
      final id = granted['conversationId'] as String;
      expect(await direct.canPost('owner', id), true);
      expect(await direct.canPost('ai-account', id), true);
      expect(await direct.canRead('other', id), false);
      expect(await direct.canPost('profile', id), false);
      final again = await open(1);
      expect(again['conversationId'], id);
      expect(
        await db.query('SELECT * FROM direct_conversations'),
        hasLength(1),
      );
      expect(await db.query('SELECT * FROM friendships'), isEmpty);
      expect(await db.query('SELECT * FROM friend_requests'), isEmpty);
    },
  );

  test(
    'revoke survives restart; tagged revoked chat cannot fall back to friendship',
    () async {
      final id = (await open())['conversationId'] as String;
      final stale = await consent.revoke(
        ownerId: 'owner',
        aiProfileId: 'profile',
        expectedRevision: 0,
      );
      expect(stale.failureOrNull?.code, FailureCode.conflict);
      final revoked = await consent.revoke(
        ownerId: 'owner',
        aiProfileId: 'profile',
        expectedRevision: 1,
      );
      expect(revoked.value['revision'], 2);
      await db.execute(
        'INSERT INTO friendships(account_low,account_high,created_at) VALUES(?,?,0)',
        ['ai-account', 'owner'],
      );
      await reconnect();
      expect(
        (await consent.get(
          ownerId: 'owner',
          aiProfileId: 'profile',
        )).value['enabled'],
        false,
      );
      expect(await direct.canPost('owner', id), false);
      expect(await direct.canPost('ai-account', id), false);
      expect(await direct.canRead('owner', id), true);
      expect(await direct.canRead('ai-account', id), false);
      expect(
        (await direct.open(actorId: 'owner', targetId: 'ai-account')).isErr,
        true,
      );
      expect(
        (await prefs.get(accountId: 'owner', conversationId: id)).isOk,
        true,
      );
      expect(
        (await prefs.set(
          accountId: 'ai-account',
          conversationId: id,
          pinned: true,
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
    },
  );

  test(
    'operator transfer revokes even without policy calls; transfer back never revives',
    () async {
      final id = (await open())['conversationId'] as String;
      await db.execute('UPDATE ai_operator SET operator_id=? WHERE ai_id=?', [
        'other',
        'ai-account',
      ]);
      expect(await direct.canPost('owner', id), false);
      expect(await direct.canRead('owner', id), true);
      expect(await direct.canRead('ai-account', id), false);
      expect(await direct.canRead('other', id), false);
      expect(
        (await prefs.get(accountId: 'ai-account', conversationId: id)).isErr,
        true,
      );
      expect((await direct.list('ai-account')).value, isEmpty);
      expect(
        (await direct.get(
          accountId: 'ai-account',
          conversationId: id,
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      final newId =
          (await consent.open(
                ownerId: 'other',
                aiProfileId: 'profile',
                expectedRevision: 0,
              )).value['conversationId']
              as String;
      expect(newId, isNot(id));
      await db.execute('UPDATE ai_operator SET operator_id=? WHERE ai_id=?', [
        'owner',
        'ai-account',
      ]);
      await reconnect();
      expect(await direct.canPost('owner', id), false);
      expect(await direct.canRead('ai-account', newId), false);
      final metadata = (await consent.get(
        ownerId: 'owner',
        aiProfileId: 'profile',
      )).value;
      expect(metadata['enabled'], false);
      expect(metadata['revision'], greaterThan(1));
      expect((await open(metadata['revision'] as int))['conversationId'], id);
    },
  );

  for (final disabled in ['owner', 'ai-account']) {
    test('disable $disabled then enable does not revive consent', () async {
      final id = (await open())['conversationId'] as String;
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', [disabled]);
      expect(await direct.canPost('owner', id), false);
      expect(await direct.canRead('ai-account', id), false);
      expect(
        (await consent.get(ownerId: 'owner', aiProfileId: 'profile')).isErr,
        true,
      );
      await db.execute('UPDATE account SET disabled=0 WHERE id=?', [disabled]);
      expect(await direct.canPost('owner', id), false);
      expect(
        (await consent.get(
          ownerId: 'owner',
          aiProfileId: 'profile',
        )).value['enabled'],
        false,
      );
    });
  }

  test('block then unblock revokes durably; no friendship fallback', () async {
    final id = (await open())['conversationId'] as String;
    await db.execute(
      'INSERT INTO account_blocks(blocker,target,created_at) VALUES(?,?,0)',
      ['owner', 'ai-account'],
    );
    expect(await direct.canPost('owner', id), false);
    expect(
      (await consent.open(
        ownerId: 'owner',
        aiProfileId: 'profile',
        expectedRevision: 2,
      )).isErr,
      true,
    );
    await db.execute('DELETE FROM account_blocks');
    await reconnect();
    expect(await direct.canPost('owner', id), false);
    expect(await direct.canRead('owner', id), true);
    expect(
      (await consent.get(
        ownerId: 'owner',
        aiProfileId: 'profile',
      )).value['enabled'],
      false,
    );
  });

  test(
    'operator delete and reinsert to same owner never revives grant',
    () async {
      final id = (await open())['conversationId'] as String;
      await db.execute('DELETE FROM ai_operator WHERE ai_id=?', ['ai-account']);
      await db.execute(
        'INSERT INTO ai_operator(ai_id,operator_id) VALUES(?,?)',
        ['ai-account', 'owner'],
      );
      expect(await direct.canPost('owner', id), false);
      expect(
        (await consent.get(
          ownerId: 'owner',
          aiProfileId: 'profile',
        )).value['revision'],
        2,
      );
    },
  );

  test(
    'block retargeted by UPDATE then removed does not revive grant',
    () async {
      final id = (await open())['conversationId'] as String;
      await db.execute(
        'INSERT INTO account_blocks(blocker,target,created_at) VALUES(?,?,0)',
        ['owner', 'other'],
      );
      await db.execute('UPDATE account_blocks SET target=? WHERE blocker=?', [
        'ai-account',
        'owner',
      ]);
      expect(await direct.canPost('owner', id), false);
      await db.execute('DELETE FROM account_blocks');
      expect(await direct.canPost('owner', id), false);
    },
  );

  test(
    'profile account remap and remap back never revive old consent',
    () async {
      final id = (await open())['conversationId'] as String;
      await account('other-ai-account', 'ai');
      await db.execute(
        'INSERT INTO ai_operator(ai_id,operator_id) VALUES(?,?)',
        ['other-ai-account', 'owner'],
      );
      await db.execute('UPDATE ai_profile SET account_id=? WHERE id=?', [
        'other-ai-account',
        'profile',
      ]);
      expect(await direct.canPost('owner', id), false);
      await db.execute('UPDATE ai_profile SET account_id=? WHERE id=?', [
        'ai-account',
        'profile',
      ]);
      expect(await direct.canPost('owner', id), false);
      expect(
        (await consent.get(
          ownerId: 'owner',
          aiProfileId: 'profile',
        )).value['enabled'],
        false,
      );
      expect(await direct.canRead('owner', id), true);
      expect(await direct.canRead('ai-account', id), false);
    },
  );

  test('profile id rename and restore never revive consent', () async {
    final id = (await open())['conversationId'] as String;
    await db.execute('UPDATE ai_profile SET id=? WHERE id=?', [
      'renamed-profile',
      'profile',
    ]);
    await db.execute('UPDATE ai_profile SET id=? WHERE id=?', [
      'profile',
      'renamed-profile',
    ]);
    expect(await direct.canPost('owner', id), false);
    expect(await direct.canRead('owner', id), true);
  });

  test(
    'profile delete retains revoked tag/history, reinsertion cannot friendship fallback',
    () async {
      final id = (await open())['conversationId'] as String;
      await db.execute(
        'INSERT INTO friendships(account_low,account_high,created_at) VALUES(?,?,0)',
        ['ai-account', 'owner'],
      );
      await db.execute('DELETE FROM ai_profile WHERE id=?', ['profile']);
      expect(
        await db.query('SELECT * FROM owner_ai_direct_grants'),
        hasLength(1),
      );
      expect(await direct.canPost('owner', id), false);
      expect(await direct.canRead('ai-account', id), false);
      expect(await direct.canRead('owner', id), true);
      await db.execute('INSERT INTO ai_profile(id,account_id) VALUES(?,?)', [
        'profile',
        'ai-account',
      ]);
      expect(await direct.canPost('owner', id), false);
      expect(
        (await direct.open(actorId: 'owner', targetId: 'ai-account')).isErr,
        true,
      );
    },
  );

  test('505 applies after an existing database already reached 120x', () async {
    final path = '${dir.path}/upgrade.sqlite';
    const old = [
      ...allMigrations,
      ...accountsMigrations,
      ...socialMigrations,
      friendshipMigration,
      privateConversationMigration,
      aiIdentityMigration,
      Migration(
        1200,
        'synthetic later migration',
        'CREATE TABLE later_schema(id INTEGER);',
      ),
    ];
    var oldDb = await SqliteDatabase.open(path, migrations: old);
    await oldDb.close();
    oldDb = await SqliteDatabase.open(
      path,
      migrations: [
        ...old,
        ownerAiDirectMigration,
        ownerAiProfileInvalidationMigration,
      ],
    );
    try {
      expect(
        await oldDb.query('SELECT 1 FROM schema_migrations WHERE version=505'),
        hasLength(1),
      );
      expect(
        await oldDb.query(
          "SELECT name FROM sqlite_master WHERE type='trigger' AND name IN ('owner_ai_direct_profile_update','owner_ai_direct_profile_delete')",
        ),
        hasLength(2),
      );
      expect(await oldDb.integrityCheck(), 'ok');
    } finally {
      await oldDb.close();
    }
  });

  test('concurrent CAS open has one winner and canonical pair', () async {
    final result = await Future.wait([
      consent.open(
        ownerId: 'owner',
        aiProfileId: 'profile',
        expectedRevision: 0,
      ),
      consent.open(
        ownerId: 'owner',
        aiProfileId: 'profile',
        expectedRevision: 0,
      ),
    ]);
    expect(result.where((r) => r.isOk), hasLength(1));
    expect(
      result.where((r) => r.failureOrNull?.code == FailureCode.conflict),
      hasLength(1),
    );
    expect(await db.query('SELECT * FROM direct_conversations'), hasLength(1));
  });

  test('failed grant write rolls back direct pair creation too', () async {
    await db.execute(
      '''CREATE TRIGGER reject_grant BEFORE INSERT ON owner_ai_direct_grants
BEGIN SELECT RAISE(ABORT, 'test rollback'); END''',
    );
    await expectLater(
      consent.open(
        ownerId: 'owner',
        aiProfileId: 'profile',
        expectedRevision: 0,
      ),
      throwsException,
    );
    expect(await db.query('SELECT * FROM direct_conversations'), isEmpty);
    expect(await db.query('SELECT * FROM owner_ai_direct_grants'), isEmpty);
  });
}
