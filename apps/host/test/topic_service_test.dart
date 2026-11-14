import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/social/topic_migrations.dart';
import 'package:jingyu_host/src/social/topic_service.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

const baseMigrations = [
  ...allMigrations,
  ...accountsMigrations,
  ...messagesMigrations,
  ...socialMigrations,
  privateConversationMigration,
  aiIdentityMigration,
  Migration(504, 'higher migration', 'CREATE TABLE higher(id TEXT);'),
];
const migrations = [...baseMigrations, topicMigration];

// Real SQLite underneath; reject any accidental use of a second operation
// outside the transaction that owns the authorization snapshot.
class _TransactionOnlyDatabase implements Database {
  _TransactionOnlyDatabase(this.inner);
  final Database inner;
  @override
  Future<T> transaction<T>(Future<T> Function(Tx) body) =>
      inner.transaction(body);
  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) => throw StateError('Topic reads must use the caller transaction');
  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      throw StateError('Topic writes must use the caller transaction');
  @override
  Future<int> schemaVersion() => inner.schemaVersion();
  @override
  Future<String> integrityCheck() => inner.integrityCheck();
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late SqliteMessageStore messages;
  late ConversationService groups;
  late TopicService topics;
  late FakeClock clock;
  var topicCounter = 0;
  var messageCounter = 0;

  Future<String> post(String group, String sender) async =>
      (await messages.append(
        conversationId: group,
        senderId: sender,
        clientMsgId: 'client-${++messageCounter}',
        kind: MessageKind.text,
        body: {'text': 'private source $messageCounter'},
      )).value.message.messageId;

  Future<String> create({
    String actor = 'owner',
    String group = 'g',
    String? root,
  }) async => (await topics.create(
    actorAccountId: actor,
    conversationId: group,
    rootMessageId: root ?? await post(group, actor),
  )).value.id;

  void missing(Result<Object?> result) =>
      expect(result.failureOrNull?.code, FailureCode.notFound);

  setUp(() async {
    topicCounter = 0;
    messageCounter = 0;
    directory = await Directory.systemTemp.createTemp('topic-service-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: baseMigrations,
    );
    await db.close();
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: migrations,
    );
    cipher = AesGcmColumnCipher(List<int>.filled(32, 19));
    clock = FakeClock(DateTime.utc(2026, 11, 14));
    var messageId = 0;
    messages = SqliteMessageStore(
      database: db,
      cipher: cipher,
      clock: clock,
      newId: () => 'source-${++messageId}',
    );
    var groupId = 0;
    groups = ConversationService(
      database: db,
      clock: clock,
      headSeq: messages.headSeqInTransaction,
      accountExists: (tx, id) async => (await tx.query(
        'SELECT 1 FROM account WHERE id=? AND disabled=0',
        [id],
      )).isNotEmpty,
      newId: () => ++groupId == 1 ? 'g' : 'g2',
    );
    topics = TopicService(
      database: _TransactionOnlyDatabase(db),
      clock: clock,
      newId: () => 'topic-${++topicCounter}',
    );
    for (final id in ['owner', 'member', 'late', 'outsider', 'ai', 'orphan']) {
      final ai = id == 'ai' || id == 'orphan';
      await db.execute(
        '''INSERT INTO account
        (id,display_name,kind,is_admin,disabled,password_hash,failed_passwords,locked_until)
        VALUES (?,?,?,0,0,?,0,0)''',
        [id, id, ai ? 'ai' : 'human', ai ? null : 'hash'],
      );
    }
    await db.execute("INSERT INTO ai_operator VALUES ('ai','owner')");
    await db.execute("INSERT INTO ai_profile VALUES ('profile-a','ai')");
    for (final g in ['g', 'g2']) {
      expect(
        (await groups.createGroup(
          ownerAccountId: 'owner',
          name: 'Group',
          historyVisibility: HistoryVisibility.joined,
        )).value.id,
        g,
      );
      for (final member in ['member', 'ai', 'orphan']) {
        expect(
          (await groups.addMember(
            actorAccountId: 'owner',
            conversationId: g,
            memberAccountId: member,
          )).isOk,
          isTrue,
        );
      }
    }
  });

  tearDown(() async {
    await db.close();
    cipher.dispose();
    await directory.delete(recursive: true);
  });

  test(
    '304 is opt-in and applies below a higher version exactly once',
    () async {
      expect(
        (await db.query(
          'SELECT version FROM schema_migrations WHERE version=304',
        )).length,
        1,
      );
      await db.close();
      db = await SqliteDatabase.open(
        '${directory.path}/host.sqlite',
        migrations: migrations,
      );
      expect(
        (await db.query(
          'SELECT version FROM schema_migrations WHERE version=304',
        )).length,
        1,
      );
      final bare = await SqliteDatabase.open(
        ':memory:',
        migrations: baseMigrations,
      );
      try {
        expect(
          await bare.query(
            "SELECT name FROM sqlite_master WHERE name='social_topics'",
          ),
          isEmpty,
        );
      } finally {
        await bare.close();
      }
    },
  );

  test(
    'creates on another sender visible root and persists metadata only',
    () async {
      final root = await post('g', 'owner');
      final before = await db.query('SELECT * FROM messages ORDER BY seq');
      final result = await topics.create(
        actorAccountId: 'member',
        conversationId: 'g',
        rootMessageId: root,
      );
      final topic = result.value;
      expect(topic.id, 'topic-1');
      expect(topic.conversationId, 'g');
      expect(topic.rootMessageId, root);
      expect(topic.createdBy, 'member');
      expect(topic.createdAt, DateTime.utc(2026, 11, 14));
      expect(
        (await topics.get(
          actorAccountId: 'member',
          topicId: topic.id,
        )).value.id,
        topic.id,
      );
      expect(
        (await topics.list(
          actorAccountId: 'member',
          conversationId: 'g',
        )).value.map((t) => t.id),
        ['topic-1'],
      );
      expect(
        (await topics.list(
          actorAccountId: 'member',
          conversationId: 'g2',
        )).value,
        isEmpty,
      );
      final refs = (await topics.references(
        actorAccountId: 'member',
        topicId: topic.id,
      )).value;
      expect(refs.map((r) => r.messageId), [root]);
      expect(refs.single.seq, 1);
      expect(refs.single.senderId, 'owner');
      expect(await db.query('SELECT * FROM messages ORDER BY seq'), before);
      expect(await messages.headSeq('g'), 1);
      final columns = await db.query('PRAGMA table_info(social_topics)');
      expect(columns.map((r) => r['name']), isNot(contains('body')));
      // New service instance reads the durable state without a process cache.
      expect(
        (await TopicService(
          database: db,
          clock: clock,
        ).get(actorAccountId: 'owner', topicId: topic.id)).value.rootMessageId,
        root,
      );
    },
  );

  test(
    'own later message can be associated idempotently without appending',
    () async {
      final topic = await create();
      final source = await post('g', 'member');
      final before = await db.query('SELECT * FROM messages ORDER BY seq');
      for (var i = 0; i < 2; i++) {
        expect(
          (await topics.associate(
            actorAccountId: 'member',
            topicId: topic,
            messageId: source,
          )).isOk,
          isTrue,
        );
      }
      expect(
        (await topics.references(
          actorAccountId: 'owner',
          topicId: topic,
        )).value.map((r) => r.messageId),
        ['source-1', source],
      );
      expect(
        (await db.query('SELECT * FROM social_topic_references')).length,
        1,
      );
      expect(await db.query('SELECT * FROM messages ORDER BY seq'), before);
      expect(await messages.headSeq('g'), 2);
    },
  );

  test(
    'only source sender or group owner may associate another message',
    () async {
      final topic = await create();
      final source = await post('g', 'ai');
      missing(
        await topics.associate(
          actorAccountId: 'member',
          topicId: topic,
          messageId: source,
        ),
      );
      expect(await db.query('SELECT * FROM social_topic_references'), isEmpty);
      expect(
        (await topics.associate(
          actorAccountId: 'owner',
          topicId: topic,
          messageId: source,
        )).isOk,
        isTrue,
      );
    },
  );

  test(
    'each root and source must be an existing message in the parent group',
    () async {
      final foreign = await post('g2', 'member');
      missing(
        await topics.create(
          actorAccountId: 'owner',
          conversationId: 'g',
          rootMessageId: foreign,
        ),
      );
      missing(
        await topics.create(
          actorAccountId: 'owner',
          conversationId: 'g',
          rootMessageId: 'missing',
        ),
      );
      expect(await db.query('SELECT * FROM social_topics'), isEmpty);
      final topic = await create();
      missing(
        await topics.associate(
          actorAccountId: 'member',
          topicId: topic,
          messageId: foreign,
        ),
      );
      missing(
        await topics.associate(
          actorAccountId: 'owner',
          topicId: topic,
          messageId: 'missing',
        ),
      );
      expect(await db.query('SELECT * FROM social_topic_references'), isEmpty);
    },
  );

  test('nonmembers receive notFound for every metadata operation', () async {
    final topic = await create();
    final source = await post('g', 'outsider');
    missing(
      await topics.create(
        actorAccountId: 'outsider',
        conversationId: 'g',
        rootMessageId: source,
      ),
    );
    missing(await topics.get(actorAccountId: 'outsider', topicId: topic));
    missing(await topics.list(actorAccountId: 'outsider', conversationId: 'g'));
    missing(
      await topics.references(actorAccountId: 'outsider', topicId: topic),
    );
    missing(
      await topics.associate(
        actorAccountId: 'outsider',
        topicId: topic,
        messageId: source,
      ),
    );
    missing(await topics.scope(actorAccountId: 'outsider', topicId: topic));
  });

  test(
    'hidden root hides the whole topic even with visible later references',
    () async {
      final topic = await create();
      expect(
        (await groups.addMember(
          actorAccountId: 'owner',
          conversationId: 'g',
          memberAccountId: 'late',
        )).isOk,
        isTrue,
      );
      final later = await post('g', 'late');
      expect(
        (await topics.associate(
          actorAccountId: 'owner',
          topicId: topic,
          messageId: later,
        )).isOk,
        isTrue,
      );
      missing(
        await topics.create(
          actorAccountId: 'late',
          conversationId: 'g',
          rootMessageId: 'source-1',
        ),
      );
      missing(await topics.get(actorAccountId: 'late', topicId: topic));
      expect(
        (await topics.list(actorAccountId: 'late', conversationId: 'g')).value,
        isEmpty,
      );
      missing(await topics.references(actorAccountId: 'late', topicId: topic));
      missing(
        await topics.associate(
          actorAccountId: 'late',
          topicId: topic,
          messageId: later,
        ),
      );
      missing(await topics.scope(actorAccountId: 'late', topicId: topic));
    },
  );

  test('first visible sequence is inclusive for roots and sources', () async {
    await post('g', 'owner');
    await groups.addMember(
      actorAccountId: 'owner',
      conversationId: 'g',
      memberAccountId: 'late',
    );
    final root = await post('g', 'owner');
    final topic = await create(actor: 'late', root: root);
    expect(
      (await topics.references(
        actorAccountId: 'late',
        topicId: topic,
      )).value.single.seq,
      2,
    );
    final source = await post('g', 'late');
    expect(
      (await topics.associate(
        actorAccountId: 'late',
        topicId: topic,
        messageId: source,
      )).isOk,
      isTrue,
    );
  });

  test(
    'source history boundary is checked independently of visible root',
    () async {
      final hidden = await post('g', 'late');
      await groups.addMember(
        actorAccountId: 'owner',
        conversationId: 'g',
        memberAccountId: 'late',
      );
      final root = await post('g', 'owner');
      final topic = await create(root: root);
      missing(
        await topics.associate(
          actorAccountId: 'late',
          topicId: topic,
          messageId: hidden,
        ),
      );
      expect(
        (await topics.associate(
          actorAccountId: 'owner',
          topicId: topic,
          messageId: hidden,
        )).isOk,
        isTrue,
      );
      expect(
        (await topics.references(
          actorAccountId: 'late',
          topicId: topic,
        )).value.map((r) => r.messageId),
        [root],
      );
      expect(
        (await topics.references(
          actorAccountId: 'owner',
          topicId: topic,
        )).value.map((r) => r.messageId),
        [hidden, root],
      );
    },
  );

  test(
    'physical source loss cannot leave readable dangling references',
    () async {
      final topic = await create();
      final source = await post('g', 'member');
      await topics.associate(
        actorAccountId: 'member',
        topicId: topic,
        messageId: source,
      );
      await db.execute('DELETE FROM messages WHERE message_id=?', [source]);
      expect(
        (await topics.references(
          actorAccountId: 'member',
          topicId: topic,
        )).value.map((r) => r.messageId),
        ['source-1'],
      );
      await db.execute("DELETE FROM messages WHERE message_id='source-1'");
      missing(await topics.get(actorAccountId: 'owner', topicId: topic));
      missing(await topics.references(actorAccountId: 'owner', topicId: topic));
      expect(
        (await topics.list(actorAccountId: 'owner', conversationId: 'g')).value,
        isEmpty,
      );
    },
  );

  test(
    'references recheck every source and never return hidden or foreign metadata',
    () async {
      final topic = await create();
      final source = await post('g', 'member');
      await topics.associate(
        actorAccountId: 'member',
        topicId: topic,
        messageId: source,
      );
      // Fail closed for stale metadata after an upstream source changes its origin.
      await db.execute(
        "UPDATE messages SET conversation_id='g2' WHERE message_id=?",
        [source],
      );
      expect(
        (await topics.references(
          actorAccountId: 'member',
          topicId: topic,
        )).value.map((r) => r.messageId),
        ['source-1'],
      );
      await db.execute(
        "UPDATE messages SET conversation_id='g2' WHERE message_id='source-1'",
      );
      missing(await topics.get(actorAccountId: 'owner', topicId: topic));
      expect(
        (await topics.list(actorAccountId: 'owner', conversationId: 'g')).value,
        isEmpty,
      );
    },
  );

  test(
    'leaving and rejoining immediately revoke old root visibility',
    () async {
      final topic = await create();
      final source = await post('g', 'member');
      await topics.associate(
        actorAccountId: 'member',
        topicId: topic,
        messageId: source,
      );
      expect(
        (await groups.leave(actorId: 'member', conversationId: 'g')).isOk,
        isTrue,
      );
      missing(await topics.get(actorAccountId: 'member', topicId: topic));
      missing(await topics.list(actorAccountId: 'member', conversationId: 'g'));
      missing(
        await topics.references(actorAccountId: 'member', topicId: topic),
      );
      missing(
        await topics.associate(
          actorAccountId: 'member',
          topicId: topic,
          messageId: source,
        ),
      );
      await groups.addMember(
        actorAccountId: 'owner',
        conversationId: 'g',
        memberAccountId: 'member',
      );
      missing(await topics.get(actorAccountId: 'member', topicId: topic));
      expect(
        (await topics.list(
          actorAccountId: 'member',
          conversationId: 'g',
        )).value,
        isEmpty,
      );
    },
  );

  test(
    'scope belongs only to the active AI principal and distinct topics stay isolated',
    () async {
      final one = await create();
      final two = await create();
      expect(
        (await topics.scope(actorAccountId: 'ai', topicId: one)).value.key,
        'topic:profile-a:g:topic-1',
      );
      expect(
        (await topics.scope(actorAccountId: 'ai', topicId: two)).value.key,
        'topic:profile-a:g:topic-2',
      );
      missing(await topics.scope(actorAccountId: 'member', topicId: one));
      missing(await topics.scope(actorAccountId: 'orphan', topicId: one));
      await db.execute("UPDATE account SET disabled=1 WHERE id='owner'");
      missing(await topics.scope(actorAccountId: 'ai', topicId: one));
      missing(await topics.get(actorAccountId: 'ai', topicId: one));
      missing(await topics.get(actorAccountId: 'owner', topicId: one));
    },
  );

  test('unregistered AI cannot obtain a topic memory namespace', () async {
    final topic = await create();
    await db.execute("DELETE FROM ai_profile WHERE account_id='ai'");
    expect(
      (await topics.get(actorAccountId: 'ai', topicId: topic)).isOk,
      isTrue,
    );
    missing(await topics.scope(actorAccountId: 'ai', topicId: topic));
  });

  test('removing AI membership revokes its scope immediately', () async {
    final topic = await create();
    expect(
      (await topics.scope(actorAccountId: 'ai', topicId: topic)).isOk,
      isTrue,
    );
    await groups.removeMember(
      actorId: 'owner',
      conversationId: 'g',
      targetId: 'ai',
    );
    missing(await topics.scope(actorAccountId: 'ai', topicId: topic));
  });

  test(
    'group and direct ID collision fails closed on every operation',
    () async {
      final topic = await create();
      final source = await post('g', 'member');
      await db.execute(
        "INSERT INTO direct_conversations VALUES ('g','member','owner',0)",
      );
      missing(
        await topics.create(
          actorAccountId: 'member',
          conversationId: 'g',
          rootMessageId: source,
        ),
      );
      missing(await topics.get(actorAccountId: 'member', topicId: topic));
      missing(await topics.list(actorAccountId: 'member', conversationId: 'g'));
      missing(
        await topics.associate(
          actorAccountId: 'member',
          topicId: topic,
          messageId: source,
        ),
      );
      missing(
        await topics.references(actorAccountId: 'member', topicId: topic),
      );
      missing(await topics.scope(actorAccountId: 'ai', topicId: topic));
      expect(await db.query('SELECT * FROM social_topic_references'), isEmpty);
    },
  );

  test('invalid IDs do not create metadata', () async {
    expect(
      (await topics.create(
        actorAccountId: '',
        conversationId: 'g',
        rootMessageId: 'm',
      )).failureOrNull?.code,
      FailureCode.invalidArgument,
    );
    expect(
      (await topics.get(
        actorAccountId: 'owner',
        topicId: '../topic',
      )).failureOrNull?.code,
      FailureCode.invalidArgument,
    );
    expect(
      (await topics.list(
        actorAccountId: 'owner',
        conversationId: '',
      )).failureOrNull?.code,
      FailureCode.invalidArgument,
    );
    expect(
      (await topics.associate(
        actorAccountId: 'owner',
        topicId: 'topic',
        messageId: '',
      )).failureOrNull?.code,
      FailureCode.invalidArgument,
    );
    expect(
      (await topics.references(
        actorAccountId: 'owner',
        topicId: '',
      )).failureOrNull?.code,
      FailureCode.invalidArgument,
    );
    expect(
      (await topics.scope(
        actorAccountId: '',
        topicId: 'topic',
      )).failureOrNull?.code,
      FailureCode.invalidArgument,
    );
    expect(await db.query('SELECT * FROM social_topics'), isEmpty);
  });
}
