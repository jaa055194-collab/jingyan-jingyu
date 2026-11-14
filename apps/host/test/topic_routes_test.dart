import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/audit/audit_log.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/social/topic_migrations.dart';
import 'package:jingyu_host/src/social/topic_routes.dart';
import 'package:jingyu_host/src/social/topic_service.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _FastHasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String password) async => 'test:$password';

  @override
  Future<bool> verifyAsync(String password, String encodedHash) async =>
      encodedHash == 'test:$password';
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late AccountsDomain accounts;
  late ConversationService groups;
  late SqliteMessageStore messages;
  late TopicService topics;
  late FakeClock clock;
  late InMemoryAuditLog audit;
  late Pipeline pipeline;
  late Map<String, AccountId> ids;
  late Map<String, String> tokens;
  late String group;
  var serial = 0;
  const password = 'test-password-123!';

  Pipeline mounted({Principal? cachedPrincipal}) {
    final router = Router();
    mountTopicRoutes(
      router,
      topics: topics,
      accounts: accounts,
      clock: clock,
      audit: audit,
    );
    return Pipeline(
      router: router,
      authenticate: cachedPrincipal == null
          ? DbAuthenticator(accounts).call
          : (_) async => cachedPrincipal,
    );
  }

  Future<HostResponse> send(
    String method,
    String route, {
    String actor = 'owner',
    String? conversation,
    String topic = 'topic-1',
    Object? body,
    String? bearer,
    Pipeline? through,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: method,
      path: route
          .replaceFirst('{conversationId}', conversation ?? group)
          .replaceFirst('{topicId}', topic),
      headers: {'authorization': 'Bearer ${bearer ?? tokens[actor]}'},
      body: body,
    ),
  );

  Future<String> post({String actor = 'owner', String? conversation}) async =>
      (await messages.append(
        conversationId: conversation ?? group,
        senderId: ids[actor]!.value,
        clientMsgId: 'client-${++serial}',
        kind: MessageKind.text,
        body: {'text': 'private source text $serial'},
      )).value.message.messageId;

  Future<String> create({String actor = 'owner', String? root}) async {
    final response = await send(
      'POST',
      Routes.groupTopics,
      actor: actor,
      body: {'rootMessageId': root ?? await post()},
    );
    expect(response.status, 200);
    return (response.json as Map)['id'] as String;
  }

  setUp(() async {
    serial = 0;
    directory = await Directory.systemTemp.createTemp('topic-routes-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...messagesMigrations,
        ...socialMigrations,
        privateConversationMigration,
        topicMigration,
      ],
    );
    clock = FakeClock(DateTime.utc(2026, 11, 14));
    cipher = AesGcmColumnCipher(List<int>.filled(32, 19));
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    ids = {};
    tokens = {};
    ids['owner'] = (await accounts.bootstrapAdmin(
      displayName: 'Owner',
      password: password,
    )).value;
    tokens['owner'] = (await accounts.login(
      ids['owner']!,
      password,
      deviceName: 'owner device',
    )).value.accessToken;
    final admin = (await accounts.scope(tokens['owner']!)).value;
    for (final name in ['sender', 'third', 'late', 'outsider']) {
      ids[name] = (await admin.accounts.createHuman(
        displayName: name,
        password: password,
      )).value;
      tokens[name] = (await accounts.login(
        ids[name]!,
        password,
        deviceName: '$name device',
      )).value.accessToken;
    }
    messages = SqliteMessageStore(
      database: db,
      cipher: cipher,
      clock: clock,
      newId: () => 'message-${++serial}',
    );
    groups = ConversationService(
      database: db,
      clock: clock,
      headSeq: messages.headSeqInTransaction,
      accountExists: (tx, id) async => (await tx.query(
        'SELECT id FROM account WHERE id = ? AND disabled = 0',
        [id],
      )).isNotEmpty,
      newId: () => 'group-${++serial}',
    );
    group = (await groups.createGroup(
      ownerAccountId: ids['owner']!.value,
      name: 'Group',
      historyVisibility: HistoryVisibility.joined,
    )).value.id;
    for (final name in ['sender', 'third']) {
      expect(
        (await groups.addMember(
          actorAccountId: ids['owner']!.value,
          conversationId: group,
          memberAccountId: ids[name]!.value,
        )).isOk,
        isTrue,
      );
    }
    var topicId = 0;
    topics = TopicService(
      database: db,
      clock: clock,
      newId: () => 'topic-${++topicId}',
    );
    audit = InMemoryAuditLog();
    pipeline = mounted();
  });

  tearDown(() async {
    await db.close();
    cipher.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'metadata endpoints persist pointers without reading source bodies',
    () async {
      final root = await post();
      final source = await post(actor: 'sender');
      // Corrupt ciphertext deliberately: any accidental body decryption must fail.
      await db.execute('UPDATE messages SET body = ?', [
        'unreadable ciphertext',
      ]);
      final before = await db.query('SELECT * FROM messages ORDER BY seq');
      final topic = await create(actor: 'sender', root: root);
      final expected = {
        'id': topic,
        'conversationId': group,
        'rootMessageId': root,
        'createdBy': ids['sender']!.value,
        'createdAt': '2026-11-14T00:00:00.000Z',
      };
      expect((await send('GET', Routes.topic, topic: topic)).json, expected);
      expect((await send('GET', Routes.groupTopics)).json, [expected]);
      expect(
        (await send(
          'POST',
          Routes.topicReferences,
          actor: 'sender',
          topic: topic,
          body: {'messageId': source},
        )).status,
        200,
      );
      final refs = await send('GET', Routes.topicReferences, topic: topic);
      expect(refs.json, [
        {'messageId': root, 'seq': 1, 'senderId': ids['owner']!.value},
        {'messageId': source, 'seq': 2, 'senderId': ids['sender']!.value},
      ]);
      expect(await db.query('SELECT * FROM messages ORDER BY seq'), before);
      final entries = await audit.forTarget('topic', topic);
      expect(entries.map((entry) => entry.action), [
        'topic.create',
        'topic.reference.associate',
      ]);
      expect(entries.map((entry) => entry.actorId), [
        ids['sender']!.value,
        ids['sender']!.value,
      ]);
      expect(entries.map((entry) => entry.meta), [
        {'conversationId': group, 'rootMessageId': root},
        {'messageId': source},
      ]);
      expect(refs.encodeBody(), isNot(contains('body')));
      expect(refs.encodeBody(), isNot(contains('ciphertext')));
    },
  );

  test('nonmembers get 404 from every endpoint and cannot mutate', () async {
    final root = await post();
    final topic = await create(root: root);
    for (final request in [
      ('GET', Routes.groupTopics, null),
      ('POST', Routes.groupTopics, {'rootMessageId': root}),
      ('GET', Routes.topic, null),
      ('GET', Routes.topicReferences, null),
      ('POST', Routes.topicReferences, {'messageId': root}),
    ]) {
      expect(
        (await send(
          request.$1,
          request.$2,
          actor: 'outsider',
          topic: topic,
          body: request.$3,
        )).status,
        404,
      );
    }
    expect((await db.query('SELECT * FROM social_topics')).length, 1);
    expect(await db.query('SELECT * FROM social_topic_references'), isEmpty);
    expect((await audit.forTarget('topic', topic)).length, 1);
  });

  test(
    'hidden roots hide topics and late members cannot create on old roots',
    () async {
      final root = await post();
      final topic = await create(root: root);
      expect(
        (await groups.addMember(
          actorAccountId: ids['owner']!.value,
          conversationId: group,
          memberAccountId: ids['late']!.value,
        )).isOk,
        isTrue,
      );
      final visibleSource = await post(actor: 'late');
      expect((await send('GET', Routes.groupTopics, actor: 'late')).json, []);
      for (final route in [Routes.topic, Routes.topicReferences]) {
        expect(
          (await send('GET', route, actor: 'late', topic: topic)).status,
          404,
        );
      }
      expect(
        (await send(
          'POST',
          Routes.groupTopics,
          actor: 'late',
          body: {'rootMessageId': root},
        )).status,
        404,
      );
      expect(
        (await send(
          'POST',
          Routes.topicReferences,
          actor: 'late',
          topic: topic,
          body: {'messageId': visibleSource},
        )).status,
        404,
      );
      expect((await db.query('SELECT * FROM social_topics')).length, 1);
      expect(await db.query('SELECT * FROM social_topic_references'), isEmpty);
    },
  );

  test(
    'leaving revokes access immediately with the same valid bearer',
    () async {
      final topic = await create();
      expect(
        (await send('GET', Routes.topic, actor: 'sender', topic: topic)).status,
        200,
      );
      expect(
        (await groups.leave(
          actorId: ids['sender']!.value,
          conversationId: group,
        )).isOk,
        isTrue,
      );
      expect(
        (await send('GET', Routes.topic, actor: 'sender', topic: topic)).status,
        404,
      );
      expect(
        (await send('GET', Routes.groupTopics, actor: 'sender')).status,
        404,
      );
      expect(
        (await send(
          'GET',
          Routes.topicReferences,
          actor: 'sender',
          topic: topic,
        )).status,
        404,
      );
    },
  );

  test(
    'only sender or current owner associates and third party changes nothing',
    () async {
      final topic = await create();
      final source = await post(actor: 'sender');
      expect(
        (await send(
          'POST',
          Routes.topicReferences,
          actor: 'third',
          topic: topic,
          body: {'messageId': source},
        )).status,
        404,
      );
      expect(await db.query('SELECT * FROM social_topic_references'), isEmpty);
      expect((await audit.forTarget('topic', topic)).length, 1);
      expect(
        (await send(
          'POST',
          Routes.topicReferences,
          actor: 'sender',
          topic: topic,
          body: {'messageId': source},
        )).status,
        200,
      );
      final another = await post(actor: 'third');
      expect(
        (await send(
          'POST',
          Routes.topicReferences,
          topic: topic,
          body: {'messageId': another},
        )).status,
        200,
      );
      expect(
        (await db.query('SELECT * FROM social_topic_references')).length,
        2,
      );
    },
  );

  test(
    'strict bodies and invalid IDs cannot supply actor or parent identity',
    () async {
      final root = await post();
      final topic = await create(root: root);
      for (final body in <Object?>[
        null,
        {},
        [],
        'text',
        {'rootMessageId': 7},
        {'rootMessageId': ''},
        {'rootMessageId': 'bad/id'},
        {'rootMessageId': root, 'actorAccountId': ids['owner']!.value},
        {'rootMessageId': root, 'conversationId': group},
        {'rootMessageId': root, 'body': 'private text'},
      ]) {
        expect(
          (await send('POST', Routes.groupTopics, body: body)).status,
          400,
        );
      }
      for (final body in <Object?>[
        null,
        {},
        [],
        {'messageId': 7},
        {'messageId': ''},
        {'messageId': 'bad/id'},
        {'messageId': root, 'actorAccountId': ids['owner']!.value},
        {'messageId': root, 'topicId': topic},
      ]) {
        expect(
          (await send(
            'POST',
            Routes.topicReferences,
            topic: topic,
            body: body,
          )).status,
          400,
        );
      }
      for (final route in [
        Routes.groupTopics,
        Routes.topic,
        Routes.topicReferences,
      ]) {
        expect((await send('GET', route, topic: topic, body: {})).status, 400);
      }
      expect(
        (await send(
          'GET',
          Routes.groupTopics,
          conversation: 'bad%2Fid',
        )).status,
        400,
      );
      expect((await send('GET', Routes.topic, topic: 'bad%2Fid')).status, 400);
      expect((await db.query('SELECT * FROM social_topics')).length, 1);
      expect(await db.query('SELECT * FROM social_topic_references'), isEmpty);
    },
  );

  test(
    'cached principal cannot authorize another account or device bearer',
    () async {
      final root = await post();
      final topic = await create(root: root);
      final principal = (await accounts.authenticate(tokens['owner']!))!;
      final cached = mounted(cachedPrincipal: principal);
      final secondDevice = (await accounts.login(
        ids['owner']!,
        password,
        deviceName: 'second owner device',
      )).value.accessToken;
      for (final bearer in [tokens['sender']!, secondDevice, 'invalid']) {
        for (final request in [
          ('GET', Routes.groupTopics, null),
          ('POST', Routes.groupTopics, {'rootMessageId': root}),
          ('GET', Routes.topic, null),
          ('GET', Routes.topicReferences, null),
          ('POST', Routes.topicReferences, {'messageId': root}),
        ]) {
          expect(
            (await send(
              request.$1,
              request.$2,
              topic: topic,
              body: request.$3,
              bearer: bearer,
              through: cached,
            )).status,
            401,
          );
        }
      }
      final owner = (await accounts.scope(tokens['owner']!)).value;
      expect(
        (await owner.devices.revoke(
          ids['owner']!,
          DeviceId.parse(principal.deviceId),
        )).isOk,
        isTrue,
      );
      expect(
        (await send('GET', Routes.topic, topic: topic, through: cached)).status,
        401,
      );
      expect((await db.query('SELECT * FROM social_topics')).length, 1);
      expect(await db.query('SELECT * FROM social_topic_references'), isEmpty);
      expect((await audit.forTarget('topic', topic)).length, 1);
    },
  );

  test(
    'foreign source and unsupported scope or AI routes stay inaccessible',
    () async {
      final other = (await groups.createGroup(
        ownerAccountId: ids['owner']!.value,
        name: 'Other',
      )).value.id;
      final foreign = await post(conversation: other);
      expect(
        (await send(
          'POST',
          Routes.groupTopics,
          body: {'rootMessageId': foreign},
        )).status,
        404,
      );
      final topic = await create();
      expect(
        (await send(
          'POST',
          Routes.topicReferences,
          topic: topic,
          body: {'messageId': foreign},
        )).status,
        404,
      );
      for (final suffix in ['scope', 'messages', 'ai', 'model']) {
        expect(
          (await send('POST', '/api/v1/topics/$topic/$suffix')).status,
          404,
        );
      }
    },
  );
}
