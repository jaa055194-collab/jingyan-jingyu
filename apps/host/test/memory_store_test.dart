import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/ai/memory/memory_migrations.dart';
import 'package:jingyu_host/src/ai/memory/memory_store.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

const migrations = [
  ...allMigrations,
  ...accountsMigrations,
  ...messagesMigrations,
  ...socialMigrations,
  aiIdentityMigration,
  ...memoryMigrations,
];

// Test fixture only: group authorization is deliberately restricted to one
// supported scope. This is NOT a production or cross-user authorizer.
final class GroupSqlAuthorization implements MemoryAuthorization {
  Future<bool> valid(Tx tx, MemoryEntry entry) async {
    final identity = await tx.query(
      '''
SELECT p.account_id FROM ai_profile p
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id
JOIN account owner ON owner.id=o.operator_id AND owner.kind='human' AND owner.disabled=0
JOIN account source ON source.id=? AND source.disabled=0
WHERE p.id=? AND o.operator_id=?''',
      [entry.sourceAccountId, entry.aiProfileId, entry.owningOperatorId],
    );
    if (identity.length != 1 ||
        entry.scopeKey != 'group:profile:room' ||
        entry.sourceMessageIds.isEmpty) {
      return false;
    }
    for (final id in entry.sourceMessageIds) {
      final rows = await tx.query(
        '''
SELECT m.message_id FROM messages m
JOIN social_members ai ON ai.conversation_id=m.conversation_id AND ai.account_id=?
JOIN social_members source ON source.conversation_id=m.conversation_id AND source.account_id=m.sender_id
WHERE m.message_id=? AND m.conversation_id='room' AND m.sender_id=?
AND m.seq>=ai.first_visible_seq AND m.seq>=source.first_visible_seq''',
        [identity.single['account_id'], id, entry.sourceAccountId],
      );
      if (rows.length != 1) return false;
    }
    return true;
  }

  @override
  Future<bool> authorizeCapture(Tx tx, MemoryCandidate candidate) =>
      valid(tx, candidate.entry);
  @override
  Future<bool> authorizeRead(
    Tx tx,
    MemoryEntry entry,
    MemoryContext context,
  ) async {
    if (context.owningOperatorId != entry.owningOperatorId ||
        context.aiProfileId != entry.aiProfileId ||
        !await valid(tx, entry)) {
      return false;
    }
    final member = await tx.query(
      'SELECT 1 FROM social_members WHERE conversation_id=? AND account_id=?',
      ['room', context.talkingWith],
    );
    return member.isNotEmpty;
  }

  @override
  Future<bool> authorizeTransition(
    Tx tx,
    MemoryEntry entry,
    MemoryContext context,
    MemoryStatus to,
  ) async =>
      context.actorAccountId == entry.owningOperatorId &&
      !context.isModelActor &&
      await authorizeRead(tx, entry, context);
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late MemoryStore store;
  final clock = FakeClock(DateTime.utc(2026, 11, 13));
  const context = MemoryContext(
    owningOperatorId: 'owner',
    aiProfileId: 'profile',
    talkingWith: 'source',
    actorAccountId: 'owner',
    isModelActor: false,
  );
  MemoryCandidate candidate({
    String body = 'unique-secret-memory-鲸',
    List<MemoryTier> tiers = const [MemoryTier.t0],
    bool optedOut = false,
    EvidenceLevel evidence = EvidenceLevel.userStated,
    String source = 'source',
    List<String> messages = const ['m1'],
  }) => MemoryCandidate(
    owningOperatorId: 'owner',
    aiProfileId: 'profile',
    sourceAccountId: source,
    aboutAccountId: 'owner',
    scopeKey: 'group:profile:room',
    sourceMessageIds: messages,
    body: body,
    overlappingTiers: tiers,
    evidence: evidence,
    userOptedOut: optedOut,
  );
  MemoryStore makeStore() => MemoryStore(
    database: db,
    cipher: cipher,
    clock: clock,
    authorizer: GroupSqlAuthorization(),
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('memory-store-');
    db = await SqliteDatabase.open(
      '${directory.path}/memory.sqlite',
      migrations: migrations,
    );
    cipher = AesGcmColumnCipher(List.filled(32, 7));
    for (final id in ['owner', 'source', 'other', 'ai']) {
      await db.execute(
        '''INSERT INTO account
(id,display_name,kind,is_admin,disabled,password_hash,failed_passwords,locked_until)
VALUES (?,?,?,0,0,?,0,0)''',
        [id, id, id == 'ai' ? 'ai' : 'human', id == 'ai' ? null : 'fixture'],
      );
    }
    await db.execute("INSERT INTO ai_operator VALUES ('ai','owner')");
    await db.execute("INSERT INTO ai_profile VALUES ('profile','ai')");
    await db.execute(
      "INSERT INTO social_conversations VALUES ('room','owner','Room','all',0)",
    );
    for (final id in ['ai', 'source', 'owner']) {
      await db.execute("INSERT INTO social_members VALUES ('room',?,0,1)", [
        id,
      ]);
    }
    await db.execute(
      "INSERT INTO messages VALUES ('m1','room',1,'source','c1','text','encrypted-fixture','2026-11-13')",
    );
    store = makeStore();
  });
  tearDown(() async {
    await db.close();
    cipher.dispose();
    await directory.delete(recursive: true);
  });

  test('missing classification remains pending and never injects', () async {
    final item = (await store.capture(candidate(tiers: []))).value!;
    expect(item.tier, MemoryTier.t1);
    expect(item.status, MemoryStatus.pending);
    expect((await store.retrieve(context)).value, isEmpty);
  });

  test(
    'opt out produces no memory, link, or audit even with invalid source',
    () async {
      expect(
        (await store.capture(
          candidate(optedOut: true, source: 'missing'),
        )).value,
        isNull,
      );
      for (final table in [
        'encrypted_memory',
        'memory_source_messages',
        'audit_log',
      ]) {
        expect(await db.query('SELECT * FROM $table'), isEmpty);
      }
    },
  );
  test(
    'active is retrieved with safe source prefix; pending and all T2 excluded',
    () async {
      final active = (await store.capture(candidate())).value!;
      final pending = (await store.capture(
        candidate(tiers: [MemoryTier.t0, MemoryTier.t1]),
      )).value!;
      final secret = (await store.capture(
        candidate(tiers: [MemoryTier.t2]),
      )).value!;
      final inferred = (await store.capture(
        candidate(evidence: EvidenceLevel.modelClaim),
      )).value!;
      expect(active.status, MemoryStatus.active);
      expect(pending.status, MemoryStatus.pending);
      expect(inferred.status, MemoryStatus.pending);
      expect(
        (await store.transition(context, secret.id, MemoryStatus.active)).isOk,
        isTrue,
      );
      final hits = (await store.retrieve(context, query: 'secret')).value;
      expect(hits.map((h) => h.id), [active.id]);
      expect(hits.single.text, startsWith('source 跟我说过：'));
      expect(hits.single.text, contains('unique-secret-memory-鲸'));
      expect((await store.retrieve(context, query: 'absent')).value, isEmpty);
    },
  );
  test(
    'trusted operator transition uses policy and model cannot self confirm',
    () async {
      final item = (await store.capture(
        candidate(tiers: [MemoryTier.t1]),
      )).value!;
      const model = MemoryContext(
        owningOperatorId: 'owner',
        aiProfileId: 'profile',
        talkingWith: 'source',
        actorAccountId: 'owner',
        isModelActor: true,
      );
      expect(
        (await store.transition(model, item.id, MemoryStatus.active)).isErr,
        isTrue,
      );
      expect(
        (await store.transition(context, item.id, MemoryStatus.deleted)).isErr,
        isTrue,
      );
      expect(
        (await store.transition(context, item.id, MemoryStatus.active)).isOk,
        isTrue,
      );
      expect((await store.retrieve(context)).value.single.id, item.id);
      expect(
        (await store.transition(context, item.id, MemoryStatus.archived)).isOk,
        isTrue,
      );
      expect((await store.retrieve(context)).value, isEmpty);
      expect((await db.query('SELECT * FROM audit_log')).length, 2);
    },
  );
  test(
    'real source identity, AI membership and history visibility fail closed',
    () async {
      expect((await store.capture(candidate(source: 'other'))).isErr, isTrue);
      expect(
        (await store.capture(candidate(messages: ['missing']))).isErr,
        isTrue,
      );
      await db.execute(
        "UPDATE social_members SET first_visible_seq=2 WHERE account_id='ai'",
      );
      expect((await store.capture(candidate())).isErr, isTrue);
      await db.execute(
        "UPDATE social_members SET first_visible_seq=1 WHERE account_id='ai'",
      );
      await store.capture(candidate());
      await db.execute("DELETE FROM social_members WHERE account_id='ai'");
      expect((await store.retrieve(context)).value, isEmpty);
      expect((await store.capture(candidate())).isErr, isTrue);
    },
  );
  test(
    'cross owner, disabled AI and reassigned operator cannot read or transition',
    () async {
      final item = (await store.capture(candidate())).value!;
      const other = MemoryContext(
        owningOperatorId: 'other',
        aiProfileId: 'profile',
        talkingWith: 'source',
        actorAccountId: 'other',
        isModelActor: false,
      );
      expect((await store.retrieve(other)).value, isEmpty);
      expect(
        (await store.transition(other, item.id, MemoryStatus.archived)).isErr,
        isTrue,
      );
      await db.execute("UPDATE account SET disabled=1 WHERE id='ai'");
      expect((await store.retrieve(context)).value, isEmpty);
      await db.execute("UPDATE account SET disabled=0 WHERE id='ai'");
      await db.execute(
        "UPDATE ai_operator SET operator_id='other' WHERE ai_id='ai'",
      );
      expect((await store.retrieve(context)).value, isEmpty);
      expect((await store.capture(candidate())).isErr, isTrue);
    },
  );
  test(
    'AAD binds owner AI scope and id; ciphertext survives restart without plaintext',
    () async {
      final item = (await store.capture(candidate())).value!;
      final row = (await db.query('SELECT * FROM encrypted_memory')).single;
      final sealed = row['encrypted_body'] as String;
      for (final aad in [
        '["other","profile","group:profile:room","${item.id}"]',
        '["owner","other","group:profile:room","${item.id}"]',
        '["owner","profile","wrong","${item.id}"]',
        '["owner","profile","group:profile:room","wrong"]',
      ]) {
        expect(cipher.decrypt(sealed, aad: aad).isErr, isTrue);
      }
      await db.close();
      for (final file in directory.listSync().whereType<File>()) {
        expect(
          latin1.decode(await file.readAsBytes()),
          isNot(contains('unique-secret-memory-')),
        );
      }
      db = await SqliteDatabase.open(
        '${directory.path}/memory.sqlite',
        migrations: migrations,
      );
      store = makeStore();
      expect((await store.retrieve(context)).value.single.id, item.id);
      await db.execute(
        'UPDATE encrypted_memory SET encrypted_body=? WHERE id=?',
        [cipher.encrypt('tampered', aad: 'wrong'), item.id],
      );
      expect(
        (await store.retrieve(context)).failureOrNull?.code,
        FailureCode.internal,
      );
    },
  );
}
