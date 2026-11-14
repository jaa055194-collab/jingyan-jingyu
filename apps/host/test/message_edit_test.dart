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
  var messageSerial = 0;
  const password = 'ack-boundary-test-password';

  String editPath(String conversationId, String messageId) => Routes.messageEdit
      .replaceFirst('{conversationId}', conversationId)
      .replaceFirst('{messageId}', messageId);
  String editsPath(String conversationId, String messageId) => Routes
      .messageEdits
      .replaceFirst('{conversationId}', conversationId)
      .replaceFirst('{messageId}', messageId);

  Future<HostResponse> postEdit(
    String conversationId,
    String messageId,
    String? bearer,
    Object? body,
  ) => pipeline.handle(
    HostRequest(
      method: 'POST',
      path: editPath(conversationId, messageId),
      headers: {if (bearer != null) 'authorization': 'Bearer $bearer'},
      body: body,
    ),
  );

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

  Future<HostResponse> getEdits(
    String conversationId,
    String messageId,
    String bearer,
  ) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: editsPath(conversationId, messageId),
      headers: {'authorization': 'Bearer $bearer'},
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('message-edit-');
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
    ids['admin'] = (await accounts.bootstrapAdmin(
      displayName: 'Admin',
      password: password,
    )).value;
    final adminLogin = (await accounts.login(
      ids['admin']!,
      password,
      deviceName: 'admin device',
    )).value;
    tokens['admin'] = adminLogin.accessToken;
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
      newId: () => 'edit-${++messageSerial}',
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
      ..provide<MembershipCheck>(membership, owner: 'edit-test')
      ..provide<HistoryMembershipCheck>(membership, owner: 'edit-test')
      ..provide<AuditLog>(audit, owner: 'edit-test');
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
    'sender edits a message: current body updates, old body stays encrypted',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['member']!.value,
        name: 'Edit group',
      )).value;
      final sent = await sendMessage(group.id, tokens['member']!, 'e1', '原始秘密');
      final messageId =
          ((sent.json! as Map)['message']! as Map)['messageId'] as String;
      final beforeCipher =
          (await db.query('SELECT body FROM messages WHERE message_id = ?', [
                messageId,
              ])).single['body']
              as String;

      final response = await postEdit(group.id, messageId, tokens['member'], {
        'body': {'text': '修改后'},
      });
      expect(response.status, 200);
      expect((response.json! as Map)['body'], {'text': '修改后'});

      final sync = await pipeline.handle(
        HostRequest(
          method: 'GET',
          path: Routes.sync.replaceFirst('{conversationId}', group.id),
          query: const {'afterSeq': '0'},
          headers: {'authorization': 'Bearer ${tokens['member']}'},
        ),
      );
      expect(
        (((sync.json! as Map)['messages'] as List).single as Map)['body'],
        {'text': '修改后'},
      );

      final afterCipher =
          (await db.query('SELECT body FROM messages WHERE message_id = ?', [
                messageId,
              ])).single['body']
              as String;
      expect(afterCipher, isNot(beforeCipher));
      final editRow = (await db.query(
        'SELECT body FROM message_edits WHERE message_id = ?',
        [messageId],
      )).single;
      expect(editRow['body'] as String, isNot(contains('原始秘密')));

      final entries = await audit.forTarget('message', messageId);
      expect(entries.single.action, 'message.edit');
      expect(entries.single.meta.keys, contains('editId'));
      expect(jsonEncode(entries.single.meta), isNot(contains('原始秘密')));
      expect(jsonEncode(entries.single.meta), isNot(contains('修改后')));

      final asAdmin = await getEdits(group.id, messageId, tokens['admin']!);
      expect(asAdmin.status, 200);
      final versions = (asAdmin.json! as Map)['edits'] as List;
      expect(((versions.single as Map)['body'] as Map)['text'], '原始秘密');

      final asMember = await getEdits(group.id, messageId, tokens['member']!);
      expect(asMember.status, 403);
    },
  );

  test(
    'non-sender, nonmember, unknown, anonymous and malformed edits are rejected',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['member']!.value,
        name: 'Edit group',
      )).value;
      final sent = await sendMessage(group.id, tokens['member']!, 'e2', '原文');
      final messageId =
          ((sent.json! as Map)['message']! as Map)['messageId'] as String;

      await conversations.addMember(
        actorAccountId: ids['member']!.value,
        conversationId: group.id,
        memberAccountId: ids['other']!.value,
      );
      expect(
        (await postEdit(group.id, messageId, tokens['other'], {
          'body': {'text': '越权'},
        })).status,
        403,
      );
      final foreign = (await conversations.createGroup(
        ownerAccountId: ids['other']!.value,
        name: 'Foreign',
      )).value;
      expect(
        (await postEdit(foreign.id, messageId, tokens['member'], {
          'body': {'text': 'x'},
        })).status,
        404,
      );
      expect(
        (await postEdit(group.id, 'missing-message', tokens['member'], {
          'body': {'text': 'x'},
        })).status,
        404,
      );
      expect(
        (await postEdit(group.id, messageId, null, {
          'body': {'text': 'x'},
        })).status,
        401,
      );
      for (final body in [
        null,
        [],
        {},
        {'body': 'x'},
        {
          'body': {'text': 'x'},
          'extra': 1,
        },
      ]) {
        expect(
          (await postEdit(group.id, messageId, tokens['member'], body)).status,
          400,
          reason: '$body',
        );
      }
    },
  );

  test('a recalled message cannot be edited', () async {
    final group = (await conversations.createGroup(
      ownerAccountId: ids['member']!.value,
      name: 'Edit group',
    )).value;
    final sent = await sendMessage(group.id, tokens['member']!, 'e3', '原文');
    final messageId =
        ((sent.json! as Map)['message']! as Map)['messageId'] as String;
    final recalled = await pipeline.handle(
      HostRequest(
        method: 'POST',
        path: Routes.messageRecall
            .replaceFirst('{conversationId}', group.id)
            .replaceFirst('{messageId}', messageId),
        headers: {'authorization': 'Bearer ${tokens['member']}'},
      ),
    );
    expect(recalled.status, 200);
    expect(
      (await postEdit(group.id, messageId, tokens['member'], {
        'body': {'text': '撤回后编辑'},
      })).status,
      400,
    );
  });
}
