import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/audit/audit_log.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/group_management_routes.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
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
  late AccountsDomain accounts;
  late ConversationService conversations;
  late FakeClock clock;
  late InMemoryAuditLog audit;
  late Pipeline pipeline;
  late Map<String, AccountId> ids;
  late Map<String, String> tokens;
  var serial = 0;
  const password = 'test-password-long';

  String path(String route, String conversation, [String? account]) => route
      .replaceFirst('{conversationId}', conversation)
      .replaceFirst(
        '{accountId}',
        account == null ? '{accountId}' : ids[account]?.value ?? account,
      );

  Future<HostResponse> send(
    String method,
    String route, {
    String actor = 'alice',
    String conversation = 'missing',
    String? target,
    Object? body,
    String? bearer,
    Pipeline? through,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: method,
      path: path(route, conversation, target),
      headers: {'authorization': 'Bearer ${bearer ?? tokens[actor]}'},
      body: body,
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'group-management-routes-',
    );
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...socialMigrations,
      ],
    );
    clock = FakeClock(DateTime.utc(2026, 11, 13));
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    ids = {};
    tokens = {};
    ids['alice'] = (await accounts.bootstrapAdmin(
      displayName: 'Alice',
      password: password,
    )).value;
    tokens['alice'] = (await accounts.login(
      ids['alice']!,
      password,
      deviceName: 'alice device',
    )).value.accessToken;
    final admin = (await accounts.scope(tokens['alice']!)).value;
    for (final name in ['bob', 'charlie']) {
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
    final owner = (await accounts.scope(tokens['alice']!)).value;
    ids['aliceAi'] = (await owner.accounts.createAi(
      operator: ids['alice']!,
      displayName: 'Alice AI',
    )).value;
    final bobOwner = (await accounts.scope(tokens['bob']!)).value;
    ids['bobAi'] = (await bobOwner.accounts.createAi(
      operator: ids['bob']!,
      displayName: 'Bob AI',
    )).value;
    conversations = ConversationService(
      database: db,
      clock: clock,
      newId: () => 'group_${++serial}',
      headSeq: (_, _) async => 1,
      accountExists: (tx, id) async => (await tx.query(
        'SELECT id FROM account WHERE id = ? AND disabled = 0',
        [id],
      )).isNotEmpty,
    );
    audit = InMemoryAuditLog();
    final router = Router();
    mountGroupManagementRoutes(
      router,
      conversations: conversations,
      accounts: accounts,
      clock: clock,
      audit: audit,
    );
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(accounts).call,
    );
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test('route constants expose the approved management paths', () {
    expect(Routes.groupOwner, '/api/v1/conversations/{conversationId}/owner');
    expect(Routes.groupLeave, '/api/v1/conversations/{conversationId}/leave');
    expect(
      Routes.groupMember,
      '/api/v1/conversations/{conversationId}/members/{accountId}',
    );
    expect(
      Routes.groupAiWithdraw,
      '/api/v1/conversations/{conversationId}/ai/{accountId}/withdraw',
    );
  });

  test('transfer makes old owner lose control and new owner gain it', () async {
    final group = (await conversations.createGroup(
      ownerAccountId: ids['alice']!.value,
      name: 'group',
    )).value;
    expect(
      (await conversations.addMember(
        actorAccountId: ids['alice']!.value,
        conversationId: group.id,
        memberAccountId: ids['bob']!.value,
      )).isOk,
      isTrue,
    );
    final response = await send(
      'PUT',
      Routes.groupOwner,
      conversation: group.id,
      body: {'accountId': ids['bob']!.value},
    );
    expect(response.status, 200);
    expect(
      (await send(
        'PUT',
        Routes.groupOwner,
        actor: 'bob',
        conversation: group.id,
        body: {'accountId': ids['charlie']!.value},
      )).status,
      404,
    );
    expect(
      (await send(
        'DELETE',
        Routes.groupMember,
        actor: 'bob',
        conversation: group.id,
        target: 'alice',
      )).status,
      200,
    );
    expect(
      (await audit.forTarget('conversation', group.id)).map((e) => e.action),
      contains('group.owner.transfer'),
    );
  });

  test(
    'owner cannot leave until transfer and member leave removes membership',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['alice']!.value,
        name: 'group',
      )).value;
      await conversations.addMember(
        actorAccountId: ids['alice']!.value,
        conversationId: group.id,
        memberAccountId: ids['bob']!.value,
      );
      expect(
        (await send('POST', Routes.groupLeave, conversation: group.id)).status,
        403,
      );
      expect(
        (await send(
          'POST',
          Routes.groupLeave,
          actor: 'bob',
          conversation: group.id,
        )).status,
        200,
      );
      expect(await conversations.canRead(ids['bob']!.value, group.id), isFalse);
    },
  );

  test(
    'nonmember cannot administer and own AI can withdraw only itself',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['alice']!.value,
        name: 'group',
      )).value;
      await conversations.addMember(
        actorAccountId: ids['alice']!.value,
        conversationId: group.id,
        memberAccountId: ids['aliceAi']!.value,
      );
      expect(
        (await send(
          'DELETE',
          Routes.groupMember,
          actor: 'bob',
          conversation: group.id,
          target: 'alice',
        )).status,
        404,
      );
      expect(
        (await send(
          'POST',
          Routes.groupAiWithdraw,
          actor: 'alice',
          conversation: group.id,
          target: 'aliceAi',
        )).status,
        200,
      );
      expect(
        (await send(
          'POST',
          Routes.groupAiWithdraw,
          actor: 'alice',
          conversation: group.id,
          target: 'bobAi',
        )).status,
        404,
      );
    },
  );

  test(
    'body must be exact and bearer must match principal account and device',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['alice']!.value,
        name: 'group',
      )).value;
      expect(
        (await send(
          'POST',
          Routes.groupLeave,
          conversation: group.id,
          body: {},
        )).status,
        400,
      );
      final principal = (await accounts.authenticate(tokens['alice']!))!;
      final stale = Pipeline(
        router: Router(),
        authenticate: (_) async => principal,
      );
      mountGroupManagementRoutes(
        stale.router,
        conversations: conversations,
        accounts: accounts,
        clock: clock,
        audit: audit,
      );
      expect(
        (await send(
          'POST',
          Routes.groupLeave,
          conversation: group.id,
          bearer: tokens['bob'],
          through: stale,
        )).status,
        401,
      );
    },
  );
}
