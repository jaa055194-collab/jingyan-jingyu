import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/device_service.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

class _Hasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String value) async => 'fixture:$value';
  @override
  Future<bool> verifyAsync(String value, String hash) async =>
      hash == 'fixture:$value';
}

class _OnlyTx implements Database {
  _OnlyTx(this.inner);
  final Database inner;
  @override
  Future<T> transaction<T>(Future<T> Function(Tx tx) body) =>
      inner.transaction(body);
  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) => throw StateError('Outer query');
  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      throw StateError('Outer write');
  @override
  Future<int> schemaVersion() => throw StateError('Unexpected');
  @override
  Future<String> integrityCheck() => throw StateError('Unexpected');
}

void main() {
  late Directory directory;
  late Host host;
  late Database db;
  late AccountsDomain accounts;
  late ConversationService groups;
  late FakeClock clock;
  late Map<String, AccountId> ids;
  late Map<String, DeviceTokens> tokens;
  late String group;
  const password = 'group-name-test-password';
  Future<void> open() async {
    host = await buildHost(
      config: HostConfig(dataDir: directory.path),
      clock: clock,
    );
    db = host.registry.services.get<Database>();
    groups = host.registry.services.get<ConversationService>();
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _Hasher(),
    );
  }

  Future<HostResponse> rename(
    Object? body, {
    String actor = 'owner',
    String? conversation,
    String? bearer,
    bool anonymous = false,
    Pipeline? through,
    Map<String, String> query = const {},
  }) => (through ?? host.pipeline).handle(
    HostRequest(
      method: 'PUT',
      path: '/api/v1/conversations/${conversation ?? group}/name',
      query: query,
      body: body,
      headers: {
        if (!anonymous)
          'authorization': 'Bearer ${bearer ?? tokens[actor]!.accessToken}',
      },
    ),
  );
  Future<Map<String, Object?>> current() => db
      .query('SELECT * FROM social_conversations WHERE id=?', [group])
      .then((rows) => rows.single);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('group-name-');
    clock = FakeClock(DateTime.utc(2026, 11, 15));
    await open();
    ids = {};
    tokens = {};
    ids['admin'] = (await accounts.bootstrapAdmin(
      displayName: 'Admin',
      password: password,
    )).value;
    tokens['admin'] = (await accounts.login(
      ids['admin']!,
      password,
      deviceName: 'admin',
    )).value;
    final admin = (await accounts.scope(tokens['admin']!.accessToken)).value;
    for (final name in ['owner', 'member', 'outsider']) {
      ids[name] = (await admin.accounts.createHuman(
        displayName: name,
        password: password,
      )).value;
      tokens[name] = (await accounts.login(
        ids[name]!,
        password,
        deviceName: name,
      )).value;
    }
    group = (await groups.createGroup(
      ownerAccountId: ids['owner']!.value,
      name: 'Before',
      historyVisibility: HistoryVisibility.joined,
    )).value.id;
    await groups.addMember(
      actorAccountId: ids['owner']!.value,
      conversationId: group,
      memberAccountId: ids['member']!.value,
    );
  });
  tearDown(() async {
    await host.shutdown();
    await directory.delete(recursive: true);
  });

  test(
    'default host owner renames only name and existing list reflects trimmed persistent value',
    () async {
      final before = await current();
      final membership = await db.query('SELECT * FROM social_members');
      final response = await rename({'name': '  New group  '});
      expect(response.status, 200);
      final after = await current();
      expect(after, {...before, 'name': 'New group'});
      expect(await db.query('SELECT * FROM social_members'), membership);
      expect(
        (await groups.list(ids['member']!.value)).value.single.name,
        'New group',
      );
      final audit = await db.query(
        "SELECT * FROM audit_log WHERE action='group.name.set'",
      );
      expect(audit, hasLength(1));
      expect(audit.single['actor_id'], ids['owner']!.value);
      expect(jsonEncode(audit), isNot(contains('New group')));
      await host.shutdown();
      await open();
      expect((await current())['name'], 'New group');
    },
  );

  test(
    'strict body and raw name length match creation rules and invalid requests do not audit',
    () async {
      final initialAudit = await db.query('SELECT * FROM audit_log');
      for (final body in <Object?>[
        null,
        [],
        {},
        {'name': null},
        {'name': 2},
        {'name': ''},
        {'name': '  '},
        {'name': 'x' * 101},
        {'name': 'x', 'actorId': ids['owner']!.value},
        {'name': 'x', 'avatar': 'a'},
      ]) {
        expect((await rename(body)).status, 400);
      }
      expect(
        (await rename(
          {'name': 'x'},
          query: {'ownerId': ids['owner']!.value},
        )).status,
        400,
      );
      expect((await rename({'name': 'x'}, conversation: 'bad id')).status, 400);
      expect((await current())['name'], 'Before');
      expect(await db.query('SELECT * FROM audit_log'), initialAudit);
      expect((await rename({'name': 'x' * 100})).status, 200);
      expect((await rename({'name': ' ${'x' * 99} '})).status, 400);
      expect((await rename({'name': ' ${'x' * 98} '})).status, 200);
      expect((await current())['name'], 'x' * 98);
    },
  );

  test(
    'member outsider admin and missing group have no rename override',
    () async {
      for (final actor in ['member', 'outsider', 'admin']) {
        expect((await rename({'name': 'denied'}, actor: actor)).status, 404);
      }
      expect(
        (await rename({'name': 'denied'}, conversation: 'missing')).status,
        404,
      );
      expect((await current())['name'], 'Before');
      expect(
        await db.query("SELECT * FROM audit_log WHERE action='group.name.set'"),
        isEmpty,
      );
    },
  );

  test(
    'ownership transfer removed owner and disabled owner revalidate current authority',
    () async {
      await groups.transferOwnership(
        actorId: ids['owner']!.value,
        conversationId: group,
        newOwnerId: ids['member']!.value,
      );
      expect((await rename({'name': 'old owner'})).status, 404);
      expect(
        (await rename({'name': 'new owner'}, actor: 'member')).status,
        200,
      );
      await db.execute(
        'DELETE FROM social_members WHERE conversation_id=? AND account_id=?',
        [group, ids['member']!.value],
      );
      expect((await rename({'name': 'removed'}, actor: 'member')).status, 404);
      await db.execute('INSERT INTO social_members VALUES(?,?,?,?)', [
        group,
        ids['member']!.value,
        0,
        1,
      ]);
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', [
        ids['member']!.value,
      ]);
      expect((await rename({'name': 'disabled'}, actor: 'member')).status, 401);
      expect(
        (await groups.setName(
          actorId: ids['member']!.value,
          conversationId: group,
          name: 'direct disabled',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect((await current())['name'], 'new owner');
    },
  );

  test(
    'legacy active AI owner cannot use service rename even with canonical active operator',
    () async {
      final owner = (await accounts.scope(tokens['owner']!.accessToken)).value;
      final ai = (await owner.accounts.createAi(
        operator: ids['owner']!,
        displayName: 'AI',
      )).value;
      final legacy = (await groups.createGroup(
        ownerAccountId: ai.value,
        name: 'AI group',
      )).value;
      final result = await groups.setName(
        actorId: ai.value,
        conversationId: legacy.id,
        name: 'not allowed',
      );
      expect(result.failureOrNull?.code, FailureCode.notFound);
      expect(
        (await db.query('SELECT name FROM social_conversations WHERE id=?', [
          legacy.id,
        ])).single['name'],
        'AI group',
      );
    },
  );

  test('name update uses supplied Tx only and rolls back SQL failure', () async {
    final scoped = ConversationService(
      database: _OnlyTx(db),
      clock: clock,
      headSeq: (_, _) async => 0,
      accountExists: (_, _) async => true,
    );
    expect(
      (await scoped.setName(
        actorId: ids['owner']!.value,
        conversationId: group,
        name: 'Through Tx',
      )).isOk,
      true,
    );
    await db.execute(
      "CREATE TRIGGER refuse_name BEFORE UPDATE OF name ON social_conversations BEGIN SELECT RAISE(ABORT,'fixture'); END",
    );
    await expectLater(
      scoped.setName(
        actorId: ids['owner']!.value,
        conversationId: group,
        name: 'Rejected',
      ),
      throwsA(isA<Exception>()),
    );
    expect((await current())['name'], 'Through Tx');
    expect(
      await db.query("SELECT * FROM audit_log WHERE action='group.name.set'"),
      isEmpty,
    );
  });

  test(
    'live bearer and exact principal account device required including rotation revoke expiry',
    () async {
      expect((await rename({'name': 'x'}, anonymous: true)).status, 401);
      final principal = (await accounts.authenticate(
        tokens['owner']!.accessToken,
      ))!;
      final cached = Pipeline(
        router: host.registry.router,
        authenticate: (_) async => principal,
      );
      expect(
        (await rename({'name': 'x'}, actor: 'member', through: cached)).status,
        401,
      );
      final wrong = Pipeline(
        router: host.registry.router,
        authenticate: (_) async =>
            Principal(accountId: principal.accountId, deviceId: 'wrong'),
      );
      expect((await rename({'name': 'x'}, through: wrong)).status, 401);
      final fresh = (await accounts.refresh(
        tokens['owner']!.refreshToken,
      )).value;
      expect((await rename({'name': 'x'}, through: cached)).status, 401);
      final session = (await accounts.scope(fresh.accessToken)).value;
      await session.devices.revoke(ids['owner']!, fresh.deviceId);
      expect(
        (await rename({'name': 'x'}, bearer: fresh.accessToken)).status,
        401,
      );
      final again = (await accounts.login(
        ids['owner']!,
        password,
        deviceName: 'again',
      )).value;
      clock.advance(const Duration(hours: 1));
      expect(
        (await rename({'name': 'x'}, bearer: again.accessToken)).status,
        401,
      );
      expect((await current())['name'], 'Before');
    },
  );
}
