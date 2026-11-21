import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/reactions.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/social/combined_membership.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/private_conversations.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_audit_log.dart';
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
  late Pipeline pipeline;
  late FakeClock clock;
  late Map<String, AccountId> ids;
  late Map<String, String> tokens;
  const password = 'ack-boundary-test-password';

  String reactionsPath(String conversationId, String messageId) => Routes
      .messageReactions
      .replaceFirst('{conversationId}', conversationId)
      .replaceFirst('{messageId}', messageId);

  Future<HostResponse> toggle(
    String conversationId,
    String messageId,
    String? bearer,
    Object? body,
  ) => pipeline.handle(
    HostRequest(
      method: 'POST',
      path: reactionsPath(conversationId, messageId),
      headers: {if (bearer != null) 'authorization': 'Bearer $bearer'},
      body: body,
    ),
  );

  Future<HostResponse> list(
    String conversationId,
    String messageId,
    String bearer,
  ) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: reactionsPath(conversationId, messageId),
      headers: {'authorization': 'Bearer $bearer'},
    ),
  );

  Future<HostResponse> sendMessage(
    String conversationId,
    String bearer,
    String clientMsgId,
  ) => pipeline.handle(
    HostRequest(
      method: 'POST',
      path: Routes.messages.replaceFirst('{conversationId}', conversationId),
      headers: {'authorization': 'Bearer $bearer'},
      body: {
        'clientMsgId': clientMsgId,
        'kind': 'text',
        'body': {'text': clientMsgId},
      },
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('message-reactions-');
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
    messages = SqliteMessageStore(database: db, cipher: cipher, clock: clock);
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
      groupHistoryInTransaction: conversations.firstVisibleSeqInTransaction,
      groupPostingHistoryInTransaction:
          conversations.firstVisibleSeqInTransaction,
    );
    final router = Router();
    final services = HostServices()
      ..provide<MembershipCheck>(membership, owner: 'reactions-test')
      ..provide<HistoryMembershipCheck>(membership, owner: 'reactions-test');
    final module = MessagesModule(
      store: messages,
      authenticate: DbAuthenticator(accounts).call,
      reactions: ReactionsService(
        database: db,
        historyAccess: membership.firstVisibleSeqInTransaction,
        writeAudit: SqliteAuditLog.recordInTransaction,
        clock: clock,
      ),
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
    'toggling a reaction adds then removes it and lists per message',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['member']!.value,
        name: 'Reactions group',
      )).value;
      final sent = await sendMessage(group.id, tokens['member']!, 'r1');
      final messageId =
          ((sent.json! as Map)['message']! as Map)['messageId'] as String;

      final first = await toggle(group.id, messageId, tokens['member'], {
        'emoji': '👍',
      });
      expect(first.status, 200);
      expect(first.json, {'emoji': '👍', 'active': true});
      final listed = await list(group.id, messageId, tokens['member']!);
      expect(listed.status, 200);
      expect((listed.json! as Map)['reactions'], [
        {'accountId': ids['member']!.value, 'emoji': '👍'},
      ]);

      final second = await toggle(group.id, messageId, tokens['member'], {
        'emoji': '👍',
      });
      expect(second.json, {'emoji': '👍', 'active': false});
      final empty = await list(group.id, messageId, tokens['member']!);
      expect((empty.json! as Map)['reactions'], isEmpty);
    },
  );

  test(
    'nonmember, unknown message, anonymous and malformed are rejected',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['member']!.value,
        name: 'Reactions group',
      )).value;
      final sent = await sendMessage(group.id, tokens['member']!, 'r2');
      final messageId =
          ((sent.json! as Map)['message']! as Map)['messageId'] as String;

      final foreign = (await conversations.createGroup(
        ownerAccountId: ids['other']!.value,
        name: 'Foreign',
      )).value;
      expect(
        (await toggle(foreign.id, messageId, tokens['member'], {
          'emoji': '👍',
        })).status,
        404,
      );
      expect(
        (await toggle(group.id, 'missing-message', tokens['member'], {
          'emoji': '👍',
        })).status,
        404,
      );
      expect(
        (await toggle(group.id, messageId, null, {'emoji': '👍'})).status,
        401,
      );
      for (final body in [
        null,
        [],
        {},
        {'emoji': ''},
        {'emoji': 'x' * 33},
        {'emoji': 1},
      ]) {
        expect(
          (await toggle(group.id, messageId, tokens['member'], body)).status,
          400,
          reason: '$body',
        );
      }
      expect((await list(group.id, messageId, tokens['other']!)).status, 404);
    },
  );
}
