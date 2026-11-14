import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/social/combined_membership.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/private_conversations.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _FastHasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String value) async => 'test:$value';

  @override
  Future<bool> verifyAsync(String value, String encodedHash) async =>
      encodedHash == 'test:$value';
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late AccountsDomain accounts;
  late SqliteMessageStore messages;
  late ConversationService conversations;
  late InMemoryAuditLog audit;
  late Pipeline pipeline;
  late FakeClock clock;
  late Map<String, AccountId> ids;
  late Map<String, String> tokens;
  late Map<String, String> refreshTokens;
  const password = 'ack-boundary-test-password';

  Future<HostResponse> sendMessage(
    String conversationId,
    String bearer,
    String clientMsgId,
    String text,
  ) => pipeline.handle(
    HostRequest(
      method: 'POST',
      path: Routes.messages.replaceFirst('{conversationId}', conversationId),
      headers: {'authorization': 'Bearer $bearer'},
      body: {
        'clientMsgId': clientMsgId,
        'kind': 'text',
        'body': {'text': text},
      },
    ),
  );

  Future<HostResponse> recall(
    String conversationId,
    String messageId,
    String? bearer,
  ) => pipeline.handle(
    HostRequest(
      method: 'POST',
      path: Routes.messageRecall
          .replaceFirst('{conversationId}', conversationId)
          .replaceFirst('{messageId}', messageId),
      headers: {if (bearer != null) 'authorization': 'Bearer $bearer'},
    ),
  );

  Future<List<Map<String, Object?>>> syncMessages(String conversationId) async {
    final response = await pipeline.handle(
      HostRequest(
        method: 'GET',
        path: Routes.sync.replaceFirst('{conversationId}', conversationId),
        query: const {'afterSeq': '0'},
        headers: {'authorization': 'Bearer ${tokens['member']}'},
      ),
    );
    expect(response.status, 200);
    return [
      for (final message in (response.json! as Map)['messages'] as List)
        (message as Map).cast<String, Object?>(),
    ];
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('message-recall-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...messagesMigrations,
        ...socialMigrations,
        privateConversationMigration,
      ],
    );
    cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
    clock = FakeClock(DateTime.utc(2026, 11, 14, 9));
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    ids = {};
    tokens = {};
    refreshTokens = {};
    ids['admin'] = (await accounts.bootstrapAdmin(
      displayName: 'Admin',
      password: password,
    )).value;
    final adminLogin = (await accounts.login(
      ids['admin']!,
      password,
      deviceName: 'admin device',
    )).value;
    final admin = (await accounts.scope(adminLogin.accessToken)).value;
    ids['member'] = (await admin.accounts.createHuman(
      displayName: 'Member',
      password: password,
    )).value;
    ids['other'] = (await admin.accounts.createHuman(
      displayName: 'Other',
      password: password,
    )).value;
    for (final name in ['member', 'other']) {
      final login = (await accounts.login(
        ids[name]!,
        password,
        deviceName: '$name device',
      )).value;
      tokens[name] = login.accessToken;
      refreshTokens[name] = login.refreshToken;
    }
    messages = SqliteMessageStore(
      database: db,
      cipher: cipher,
      clock: clock,
      newId: () => 'recall-message',
    );
    conversations = ConversationService(
      database: db,
      clock: clock,
      headSeq: (tx, id) async {
        final rows = await tx.query(
          'SELECT seq FROM message_heads WHERE conversation_id = ?',
          [id],
        );
        return rows.isEmpty ? 0 : rows.single['seq'] as int;
      },
      accountExists: (tx, id) async => (await tx.query(
        'SELECT id FROM account WHERE id = ? AND disabled = 0',
        [id],
      )).isNotEmpty,
    );
    final membership = CombinedMembership(
      db: db,
      group: conversations,
      direct: PrivateConversations(db: db, clock: clock),
    );
    audit = InMemoryAuditLog(clock: clock);
    final router = Router();
    final services = HostServices()
      ..provide<MembershipCheck>(membership, owner: 'recall-test')
      ..provide<HistoryMembershipCheck>(membership, owner: 'recall-test')
      ..provide<AuditLog>(audit, owner: 'recall-test');
    final module = MessagesModule(
      store: messages,
      authenticate: DbAuthenticator(accounts).call,
      clock: clock,
    );
    await module.configure(services);
    module.mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(accounts).call,
      onError: (error, stack, request) =>
          Error.throwWithStackTrace(error, stack),
    );
  });

  tearDown(() async {
    cipher.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'sender recalls a recent message: tombstone replaces body, audit has no body',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['member']!.value,
        name: 'Recall group',
      )).value;
      final sent = await sendMessage(
        group.id,
        tokens['member']!,
        'recall-1',
        '只有我知道的秘密',
      );
      expect(sent.status, 200);
      final messageId =
          ((sent.json! as Map)['message'] as Map)['messageId'] as String;
      final beforeCipher =
          (await db.query('SELECT body FROM messages WHERE message_id = ?', [
                messageId,
              ])).single['body']
              as String;

      final recalled = await recall(group.id, messageId, tokens['member']);
      expect(recalled.status, 200);
      expect((recalled.json! as Map)['recalled'], isTrue);

      final messagesPage = await syncMessages(group.id);
      expect(messagesPage.single['body'], {'recalled': true});
      expect(jsonEncode(messagesPage), isNot(contains('只有我知道的秘密')));

      final row = (await db.query(
        'SELECT body, recalled_at FROM messages WHERE message_id = ?',
        [messageId],
      )).single;
      expect(row['body'], isNot(beforeCipher));
      expect(row['recalled_at'], isNotNull);

      final entries = await audit.forTarget('message', messageId);
      expect(entries, hasLength(1));
      expect(entries.single.action, 'message.recall');
      expect(entries.single.actorId, ids['member']!.value);
      expect(jsonEncode(entries.single.meta), isNot(contains('秘密')));
      expect(
        entries.single.meta.keys.toSet().intersection(AuditEntry.forbiddenKeys),
        isEmpty,
      );

      final again = await recall(group.id, messageId, tokens['member']);
      expect(again.status, 400);
    },
  );

  test('another member cannot recall; stored body stays unchanged', () async {
    final group = (await conversations.createGroup(
      ownerAccountId: ids['member']!.value,
      name: 'Recall group',
    )).value;
    await conversations.addMember(
      actorAccountId: ids['member']!.value,
      conversationId: group.id,
      memberAccountId: ids['other']!.value,
    );
    final sent = await sendMessage(group.id, tokens['member']!, 'owned', '私密');
    final messageId =
        ((sent.json! as Map)['message']! as Map)['messageId'] as String;

    expect((await recall(group.id, messageId, tokens['other'])).status, 403);
    final messagesPage = await syncMessages(group.id);
    expect((messagesPage.single['body'] as Map)['text'], '私密');
    expect(await audit.forTarget('message', messageId), isEmpty);
  });

  test(
    'nonmember, unknown message and anonymous requests are rejected',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['member']!.value,
        name: 'Recall group',
      )).value;
      final sent = await sendMessage(group.id, tokens['member']!, 'known', 'x');
      final messageId =
          ((sent.json! as Map)['message']! as Map)['messageId'] as String;

      final foreign = (await conversations.createGroup(
        ownerAccountId: ids['other']!.value,
        name: 'Foreign group',
      )).value;
      expect(
        (await recall(foreign.id, messageId, tokens['member'])).status,
        404,
      );
      expect(
        (await recall(group.id, 'missing-message', tokens['member'])).status,
        404,
      );
      expect((await recall(group.id, messageId, null)).status, 401);
      final messagesPage = await syncMessages(group.id);
      expect((messagesPage.single['body'] as Map)['text'], 'x');
    },
  );

  test(
    'recall after the 24h window fails and keeps the original body',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['other']!.value,
        name: 'Expiry group',
      )).value;
      final sent = await sendMessage(group.id, tokens['other']!, 'old', '旧消息');
      final messageId =
          ((sent.json! as Map)['message']! as Map)['messageId'] as String;

      clock.advance(const Duration(hours: 24, seconds: 1));
      final refreshed = (await accounts.refresh(refreshTokens['other']!)).value;

      expect(
        (await recall(group.id, messageId, refreshed.accessToken)).status,
        403,
      );
      final row = (await db.query(
        'SELECT recalled_at FROM messages WHERE message_id = ?',
        [messageId],
      )).single;
      expect(row['recalled_at'], isNull);
      final body = (await messages.since(
        conversationId: group.id,
        afterSeq: 0,
      )).value.messages.single.body;
      expect(body['text'], '旧消息');
    },
  );

  test('exactly 24h is still inside the window', () async {
    final group = (await conversations.createGroup(
      ownerAccountId: ids['other']!.value,
      name: 'Boundary group',
    )).value;
    final sent = await sendMessage(group.id, tokens['other']!, 'edge', '边界');
    final messageId =
        ((sent.json! as Map)['message']! as Map)['messageId'] as String;

    clock.advance(const Duration(hours: 24));
    final refreshed = (await accounts.refresh(refreshTokens['other']!)).value;
    final response = await recall(group.id, messageId, refreshed.accessToken);
    expect(response.status, 200);
    expect(
      (await db.query('SELECT recalled_at FROM messages WHERE message_id = ?', [
        messageId,
      ])).single['recalled_at'],
      isNotNull,
    );
  });

  test(
    'in-memory recall honours the injected clock at the 24h boundary',
    () async {
      final memoryClock = FakeClock(DateTime.utc(2026, 11, 14, 9));
      final memory = InMemoryMessageStore(clock: memoryClock);
      final sent = (await memory.append(
        conversationId: 'c',
        senderId: 'u',
        clientMsgId: 'edge',
        kind: MessageKind.text,
        body: {'text': '边界'},
      )).value;

      memoryClock.advance(const Duration(hours: 24));
      expect(
        (await memory.recall(
          conversationId: 'c',
          messageId: sent.message.messageId,
          senderId: 'u',
        )).isOk,
        isTrue,
      );

      final late = (await memory.append(
        conversationId: 'c',
        senderId: 'u',
        clientMsgId: 'late',
        kind: MessageKind.text,
        body: {'text': '迟'},
      )).value;
      memoryClock.advance(const Duration(hours: 24, seconds: 1));
      final expired = await memory.recall(
        conversationId: 'c',
        messageId: late.message.messageId,
        senderId: 'u',
      );
      expect(expired.isErr, isTrue);
      expect(expired.failureOrNull!.code, FailureCode.forbidden);
    },
  );

  test('audit failure does not turn an applied recall into a 500', () async {
    final group = (await conversations.createGroup(
      ownerAccountId: ids['member']!.value,
      name: 'Audit failure group',
    )).value;
    final sent = await sendMessage(group.id, tokens['member']!, 'audit', '内容');
    final messageId =
        ((sent.json! as Map)['message']! as Map)['messageId'] as String;

    final router = Router();
    final services = HostServices()
      ..provide<MembershipCheck>(
        CombinedMembership(
          db: db,
          group: conversations,
          direct: PrivateConversations(db: db, clock: clock),
        ),
        owner: 'recall-audit-test',
      )
      ..provide<HistoryMembershipCheck>(
        CombinedMembership(
          db: db,
          group: conversations,
          direct: PrivateConversations(db: db, clock: clock),
        ),
        owner: 'recall-audit-test',
      )
      ..provide<AuditLog>(_FailingAuditLog(), owner: 'recall-audit-test');
    final module = MessagesModule(
      store: messages,
      authenticate: DbAuthenticator(accounts).call,
      clock: clock,
    );
    await module.configure(services);
    module.mount(router);
    final failingPipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(accounts).call,
    );
    final response = await failingPipeline.handle(
      HostRequest(
        method: 'POST',
        path: Routes.messageRecall
            .replaceFirst('{conversationId}', group.id)
            .replaceFirst('{messageId}', messageId),
        headers: {'authorization': 'Bearer ${tokens['member']}'},
      ),
    );
    expect(response.status, 200);
    expect(
      (await db.query('SELECT recalled_at FROM messages WHERE message_id = ?', [
        messageId,
      ])).single['recalled_at'],
      isNotNull,
    );
  });
}

class _FailingAuditLog implements AuditLog {
  @override
  Future<void> record(AuditEntry entry) async =>
      throw StateError('audit store unavailable');

  @override
  Future<List<AuditEntry>> forTarget(
    String targetKind,
    String targetId,
  ) async => const [];
}
