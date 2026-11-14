import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/messages/blind_index.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/search.dart';
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
  late Pipeline pipeline;
  late FakeClock clock;
  late Map<String, AccountId> ids;
  late Map<String, String> tokens;
  const password = 'ack-boundary-test-password';

  Future<HostResponse> search(
    String? bearer, {
    Map<String, String> query = const {},
  }) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: Routes.search,
      query: query,
      headers: {if (bearer != null) 'authorization': 'Bearer $bearer'},
    ),
  );

  Future<HostResponse> sendMessage(
    String conversationId,
    String bearer,
    String clientMsgId,
    String text, {
    String kind = 'text',
  }) => pipeline.handle(
    HostRequest(
      method: 'POST',
      path: Routes.messages.replaceFirst('{conversationId}', conversationId),
      headers: {'authorization': 'Bearer $bearer'},
      body: {
        'clientMsgId': clientMsgId,
        'kind': kind,
        'body': {'text': text},
      },
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('message-search-');
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
    );
    final router = Router();
    final services = HostServices()
      ..provide<MembershipCheck>(membership, owner: 'search-test')
      ..provide<HistoryMembershipCheck>(membership, owner: 'search-test');
    final blind = BlindIndexService(database: db, cipher: cipher);
    final module = MessagesModule(
      store: messages,
      authenticate: DbAuthenticator(accounts).call,
      search: MessageSearchService(database: db, store: messages, blind: blind),
      blind: blind,
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

  List<Map<String, Object?>> hits(HostResponse response) =>
      ((response.json! as Map)['hits'] as List).cast<Map<String, Object?>>();

  test(
    'search only returns messages in conversations the caller can read',
    () async {
      final own = (await conversations.createGroup(
        ownerAccountId: ids['member']!.value,
        name: 'Own group',
      )).value;
      await sendMessage(own.id, tokens['member']!, 's1', '项目代号鲸落');
      final foreign = (await conversations.createGroup(
        ownerAccountId: ids['other']!.value,
        name: 'Foreign group',
      )).value;
      await sendMessage(foreign.id, tokens['other']!, 's2', '项目代号鲸落');

      final found = await search(tokens['member'], query: {'q': '鲸落'});
      expect(found.status, 200);
      expect(hits(found), hasLength(1));
      expect(hits(found).single['conversationId'], own.id);
      expect(hits(found).single['mode'], 'blind');

      final filteredOut = await search(
        tokens['member'],
        query: {'q': '鲸落', 'senderId': ids['other']!.value},
      );
      expect(hits(filteredOut), isEmpty);

      final kindFiltered = await search(
        tokens['member'],
        query: {'q': '鲸落', 'kind': 'image'},
      );
      expect(hits(kindFiltered), isEmpty);
    },
  );

  test('joined history hides messages sent before joining', () async {
    final group = (await conversations.createGroup(
      ownerAccountId: ids['member']!.value,
      name: 'Joined group',
      historyVisibility: HistoryVisibility.joined,
    )).value;
    await sendMessage(group.id, tokens['member']!, 'old', '入群前的旧秘密');
    await conversations.addMember(
      actorAccountId: ids['member']!.value,
      conversationId: group.id,
      memberAccountId: ids['other']!.value,
    );
    await sendMessage(group.id, tokens['member']!, 'new', '入群后的新秘密');

    final old = await search(tokens['other'], query: {'q': '旧秘密'});
    expect(hits(old), isEmpty);
    final fresh = await search(tokens['other'], query: {'q': '新秘密'});
    expect(hits(fresh), hasLength(1));
  });

  test('anonymous and malformed searches are rejected', () async {
    expect((await search(null, query: {'q': 'x'})).status, 401);
    expect((await search(tokens['member'], query: const {})).status, 400);
    expect((await search(tokens['member'], query: {'q': '  '})).status, 400);
    expect(
      (await search(tokens['member'], query: {'q': 'x', 'limit': '0'})).status,
      400,
    );
    expect(
      (await search(
        tokens['member'],
        query: {'q': 'x', 'limit': '101'},
      )).status,
      400,
    );
    expect(
      (await search(
        tokens['member'],
        query: {'q': 'x', 'kind': 'nope'},
      )).status,
      400,
    );
    expect(
      (await search(tokens['member'], query: {'q': 'x', 'from': 'bad'})).status,
      400,
    );
  });
}
