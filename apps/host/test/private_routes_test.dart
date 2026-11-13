import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/messages_module.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/social/combined_membership.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/friendship_routes.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/private_conversations.dart';
import 'package:jingyu_host/src/social/private_routes.dart';
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
  late AccountsDomain accounts;
  late Router router;
  late Pipeline pipeline;
  late ConversationService groups;
  late CombinedMembership membership;
  late AesGcmColumnCipher cipher;
  late Map<String, AccountId> ids;
  late Map<String, String> tokens;
  const password = 'private-routes-test-password';
  final clock = FakeClock(DateTime.utc(2026, 11, 13));

  Future<HostResponse> send(
    String method,
    String path, {
    String actor = 'a',
    Object? body,
    Pipeline? through,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: method,
      path: path,
      headers: {'authorization': 'Bearer ${tokens[actor]}'},
      body: body,
    ),
  );
  String friend(String route, String target) =>
      route.replaceFirst('{accountId}', ids[target]!.value);
  String message(String route, String id) =>
      route.replaceFirst('{conversationId}', id);
  Future<void> consent() async {
    expect((await send('POST', friend(Routes.friendRequest, 'b'))).status, 200);
    expect(
      (await send('POST', friend(Routes.friendAccept, 'a'), actor: 'b')).status,
      200,
    );
  }

  Future<HostResponse> open({String actor = 'a', String target = 'b'}) => send(
    'POST',
    Routes.directConversations,
    actor: actor,
    body: {'accountId': ids[target]!.value},
  );
  Future<HostResponse> post(
    String id, {
    String actor = 'a',
    String client = 'm1',
  }) => send(
    'POST',
    message(Routes.messages, id),
    actor: actor,
    body: {
      'clientMsgId': client,
      'kind': 'text',
      'body': {'text': 'private hello'},
    },
  );
  Future<HostResponse> sync(String id, {String actor = 'a'}) =>
      send('GET', message(Routes.sync, id), actor: actor);

  setUp(() async {
    clock.set(DateTime.utc(2026, 11, 13));
    directory = await Directory.systemTemp.createTemp('private-routes-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...messagesMigrations,
        ...socialMigrations,
        friendshipMigration,
        privateConversationMigration,
      ],
    );
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    ids = {};
    tokens = {};
    ids['a'] = (await accounts.bootstrapAdmin(
      displayName: 'A',
      password: password,
    )).value;
    tokens['a'] = (await accounts.login(
      ids['a']!,
      password,
      deviceName: 'A device',
    )).value.accessToken;
    final admin = (await accounts.scope(tokens['a']!)).value;
    for (final name in ['b', 'c']) {
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
    groups = ConversationService(
      database: db,
      clock: clock,
      headSeq: (tx, id) async =>
          (await tx.query(
                'SELECT COALESCE(MAX(seq),0) AS head FROM messages WHERE conversation_id=?',
                [id],
              )).single['head']
              as int,
      accountExists: (tx, id) async => (await tx.query(
        'SELECT 1 FROM account WHERE id=? AND disabled=0',
        [id],
      )).isNotEmpty,
    );
    final direct = PrivateConversations(db: db, clock: clock);
    membership = CombinedMembership(db: db, group: groups, direct: direct);
    router = Router();
    final audit = SqliteAuditLog(db);
    mountFriendshipRoutes(
      router,
      db: db,
      clock: clock,
      accounts: accounts,
      audit: audit,
    );
    mountPrivateRoutes(
      router,
      db: db,
      clock: clock,
      accounts: accounts,
      audit: audit,
      direct: direct,
    );
    cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
    final messages = MessagesModule(
      store: SqliteMessageStore(database: db, cipher: cipher, clock: clock),
    );
    final services = HostServices();
    services.provide<MembershipCheck>(membership, owner: 'test');
    services.provide<HistoryMembershipCheck>(membership, owner: 'test');
    await messages.configure(services);
    messages.mount(router);
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
    'mutual consent opens canonical private chat; block keeps history and requires fresh consent',
    () async {
      expect((await open()).status, 403);
      await consent();
      final opened = await open();
      expect(opened.status, 200);
      final data = opened.json as Map;
      final id = data['id'] as String;
      expect(data['kind'], 'direct');
      expect((await open(actor: 'b', target: 'a')).json, opened.json);
      expect((await post(id)).status, 200);
      for (final actor in ['a', 'b']) {
        final page = await sync(id, actor: actor);
        expect(page.status, 200);
        expect(((page.json as Map)['messages'] as List).single['body'], {
          'text': 'private hello',
        });
      }
      expect((await send('POST', friend(Routes.friendBlock, 'b'))).status, 200);
      for (final actor in ['a', 'b']) {
        expect(
          (await post(id, actor: actor, client: 'blocked-$actor')).status,
          404,
        );
        expect((await sync(id, actor: actor)).status, 200);
        final listed = await send(
          'GET',
          Routes.directConversations,
          actor: actor,
        );
        expect(
          ((listed.json as Map)['conversations'] as List).single['id'],
          id,
        );
      }
      expect((await open()).status, 403);
      expect(
        (await send('DELETE', friend(Routes.friendBlock, 'b'))).status,
        200,
      );
      for (final actor in ['a', 'b']) {
        expect(
          (await post(id, actor: actor, client: 'unblocked-$actor')).status,
          404,
        );
        expect((await sync(id, actor: actor)).status, 200);
      }
      expect(
        (await send('POST', friend(Routes.friendRequest, 'b'))).status,
        200,
      );
      for (final actor in ['a', 'b']) {
        expect(
          (await post(id, actor: actor, client: 'pending-$actor')).status,
          404,
        );
      }
      expect(
        (await send(
          'POST',
          friend(Routes.friendAccept, 'a'),
          actor: 'b',
        )).status,
        200,
      );
      for (final actor in ['a', 'b']) {
        expect(
          (await post(id, actor: actor, client: 'fresh-consent-$actor')).status,
          200,
        );
      }
      expect((await open()).json, opened.json);
      final safe = jsonEncode([
        opened.json,
        await db.query('SELECT * FROM audit_log'),
      ]);
      for (final secret in [
        ...tokens.values,
        password,
        'password_hash',
        'private hello',
      ]) {
        expect(safe, isNot(contains(secret)));
      }
      final stored = await db.query('SELECT * FROM messages');
      expect(jsonEncode(stored), isNot(contains('private hello')));
    },
  );

  test('third party cannot list, send or read private conversation', () async {
    await consent();
    final id = ((await open()).json as Map)['id'] as String;
    expect((await post(id)).status, 200);
    final listed = await send('GET', Routes.directConversations, actor: 'c');
    expect(listed.status, 200);
    expect(listed.json, {'conversations': []});
    expect((await sync(id, actor: 'c')).status, 404);
    expect((await post(id, actor: 'c')).status, 404);
    expect(await membership.firstVisibleSeq(ids['c']!.value, id), isNull);
  });

  test(
    'private routes reject body identity injection and malformed target',
    () async {
      for (final body in [
        null,
        [],
        '',
        1,
        {},
        {'accountId': 1},
        {'accountId': 'bad!id'},
        {'accountId': ids['b']!.value, 'actorId': ids['c']!.value},
        {'accountId': ids['b']!.value, 'apiKey': 'secret'},
      ]) {
        expect(
          (await send('POST', Routes.directConversations, body: body)).status,
          400,
        );
      }
      expect(
        (await send(
          'GET',
          Routes.directConversations,
          body: {'accountId': ids['b']!.value},
        )).status,
        400,
      );
      expect(await db.query('SELECT * FROM direct_conversations'), isEmpty);
      expect(await db.query('SELECT * FROM audit_log'), isEmpty);
    },
  );

  test(
    'private routes revalidate bearer account and device, including revoked sessions',
    () async {
      final a = (await accounts.authenticate(tokens['a']!))!;
      final b = (await accounts.authenticate(tokens['b']!))!;
      for (final principal in [
        null,
        b,
        Principal(accountId: a.accountId, deviceId: 'wrong-device'),
      ]) {
        final forged = Pipeline(
          router: router,
          authenticate: (_) async => principal,
        );
        expect(
          (await send(
            'GET',
            Routes.directConversations,
            through: forged,
          )).status,
          401,
        );
        expect(
          (await send(
            'POST',
            Routes.directConversations,
            through: forged,
            body: {'accountId': ids['b']!.value},
          )).status,
          401,
        );
      }
      final scope = (await accounts.scope(tokens['a']!)).value;
      await scope.devices.revoke(ids['a']!, DeviceId.parse(a.deviceId));
      final stale = Pipeline(router: router, authenticate: (_) async => a);
      expect(
        (await send('GET', Routes.directConversations, through: stale)).status,
        401,
      );
      expect(
        (await send(
          'POST',
          Routes.directConversations,
          through: stale,
          body: {'accountId': ids['b']!.value},
        )).status,
        401,
      );
    },
  );

  test(
    'combined membership preserves group boundaries and rejects ambiguous shared message IDs',
    () async {
      final group = (await groups.createGroup(
        ownerAccountId: ids['c']!.value,
        name: 'C group',
      )).value;
      expect((await post(group.id, actor: 'c')).status, 200);
      expect((await sync(group.id, actor: 'a')).status, 404);
      await consent();
      final id = ((await open()).json as Map)['id'] as String;
      expect((await post(id)).status, 200);
      await db.execute('INSERT INTO social_conversations VALUES (?,?,?,?,?)', [
        id,
        ids['c']!.value,
        'collision',
        'all',
        0,
      ]);
      await db.execute('INSERT INTO social_members VALUES (?,?,?,?)', [
        id,
        ids['c']!.value,
        0,
        1,
      ]);
      for (final actor in ['a', 'b', 'c']) {
        expect((await sync(id, actor: actor)).status, 404);
        expect((await post(id, actor: actor)).status, 404);
        expect(await membership.firstVisibleSeq(ids[actor]!.value, id), isNull);
      }
    },
  );
}
