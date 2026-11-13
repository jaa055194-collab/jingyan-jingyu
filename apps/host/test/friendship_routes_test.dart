import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/friendship_routes.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_audit_log.dart';
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
  late FakeClock clock;
  late Router router;
  late Pipeline pipeline;
  late Map<String, AccountId> ids;
  late Map<String, String> tokens;
  const password = 'test-password-long';

  String path(String route, String target) =>
      route.replaceFirst('{accountId}', ids[target]?.value ?? target);
  Future<HostResponse> send(
    String method,
    String route, {
    String actor = 'a',
    String target = 'b',
    Object? body,
    String? bearer,
    Pipeline? through,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: method,
      path: path(route, target),
      headers: {'authorization': 'Bearer ${bearer ?? tokens[actor]}'},
      body: body,
    ),
  );
  Future<void> state(String actor, String target, String expected) async {
    final response = await send(
      'GET',
      Routes.friendState,
      actor: actor,
      target: target,
    );
    expect(response.status, 200);
    expect(response.json, {'state': expected});
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('friendship-routes-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        friendshipMigration,
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
    final owner = (await accounts.scope(tokens['b']!)).value;
    ids['ai'] = (await owner.accounts.createAi(
      operator: ids['b']!,
      displayName: 'B AI',
    )).value;
    router = Router();
    mountFriendshipRoutes(
      router,
      db: db,
      clock: clock,
      accounts: accounts,
      audit: SqliteAuditLog(db),
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

  test(
    'only target consent creates friendship; C and sender cannot accept',
    () async {
      await state('a', 'b', 'none');
      final requested = await send('POST', Routes.friendRequest);
      expect(requested.status, 200);
      expect(requested.json, isNull);
      await state('a', 'b', 'outgoingPending');
      await state('b', 'a', 'incomingPending');
      await state('c', 'a', 'none');
      expect((await send('POST', Routes.friendAccept)).status, 404);
      expect(
        (await send(
          'POST',
          Routes.friendAccept,
          actor: 'c',
          target: 'a',
        )).status,
        404,
      );
      final accepted = await send(
        'POST',
        Routes.friendAccept,
        actor: 'b',
        target: 'a',
        body: <String, Object?>{},
      );
      expect(accepted.status, 200);
      expect(accepted.json, isNull);
      await state('a', 'b', 'friends');
      await state('b', 'a', 'friends');
      expect((await db.query('SELECT * FROM friendships')).length, 1);
      final audit = await db.query('SELECT * FROM audit_log ORDER BY id');
      expect(audit.map((r) => r['action']).toList(), [
        'friendship.request',
        'friendship.accept',
      ]);
      expect(audit.map((r) => r['actor_id']).toList(), [
        ids['a']!.value,
        ids['b']!.value,
      ]);
      expect(audit.map((r) => r['target_id']).toList(), [
        ids['b']!.value,
        ids['a']!.value,
      ]);
      for (final row in audit) {
        expect(row['target_kind'], 'account');
        expect(jsonDecode(row['meta'] as String), isEmpty);
        expect(row['at'], '2026-11-13T00:00:00.000Z');
      }
      final safe = jsonEncode([requested.json, accepted.json, audit]);
      for (final secret in [
        ...tokens.values,
        password,
        'password_hash',
        'body',
      ]) {
        expect(safe, isNot(contains(secret)));
      }
    },
  );

  test(
    'deny allows reapplication; block and unblock require new consent',
    () async {
      await send('POST', Routes.friendRequest);
      expect(
        (await send('POST', Routes.friendDeny, actor: 'b', target: 'a')).status,
        200,
      );
      await state('a', 'b', 'none');
      expect(
        (await send(
          'POST',
          Routes.friendAccept,
          actor: 'b',
          target: 'a',
        )).status,
        409,
      );
      await send('POST', Routes.friendRequest);
      await send('POST', Routes.friendAccept, actor: 'b', target: 'a');
      expect((await send('POST', Routes.friendBlock)).status, 200);
      await state('b', 'a', 'blocked');
      expect(
        (await send(
          'POST',
          Routes.friendRequest,
          actor: 'b',
          target: 'a',
        )).status,
        403,
      );
      expect(
        (await send(
          'DELETE',
          Routes.friendBlock,
          actor: 'b',
          target: 'a',
        )).status,
        200,
      );
      await state('a', 'b', 'blocked');
      expect((await send('DELETE', Routes.friendBlock)).status, 200);
      await state('a', 'b', 'none');
      expect(
        (await send(
          'POST',
          Routes.friendAccept,
          actor: 'b',
          target: 'a',
        )).status,
        404,
      );
      await send('POST', Routes.friendRequest);
      await send('POST', Routes.friendAccept, actor: 'b', target: 'a');
      await state('a', 'b', 'friends');
      final actions = (await db.query(
        'SELECT action FROM audit_log',
      )).map((r) => r['action']).toList();
      expect(
        actions,
        containsAll([
          'friendship.deny',
          'friendship.block',
          'friendship.unblock',
        ]),
      );
    },
  );

  test(
    'every mutation rejects body identities and malformed or missing targets',
    () async {
      for (final endpoint in [
        ('POST', Routes.friendRequest),
        ('POST', Routes.friendAccept),
        ('POST', Routes.friendDeny),
        ('POST', Routes.friendBlock),
        ('DELETE', Routes.friendBlock),
      ]) {
        for (final body in [
          {'actor': ids['b']!.value},
          {'target': ids['c']!.value},
          {'body': 'private', 'api_key': 'private-key'},
          [],
          '',
          1,
        ]) {
          expect(
            (await send(endpoint.$1, endpoint.$2, body: body)).status,
            400,
          );
        }
        expect(
          (await send(endpoint.$1, endpoint.$2, target: 'bad!id')).status,
          400,
        );
        expect(
          (await send(endpoint.$1, endpoint.$2, target: 'missing')).status,
          404,
        );
        expect((await send(endpoint.$1, endpoint.$2, target: 'a')).status, 400);
      }
      expect(
        (await send('GET', Routes.friendState, target: 'bad!id')).status,
        400,
      );
      expect(
        (await send('GET', Routes.friendState, target: 'missing')).status,
        404,
      );
      expect(await db.query('SELECT * FROM audit_log'), isEmpty);
      expect(await db.query('SELECT * FROM friend_requests'), isEmpty);
    },
  );

  test(
    'all routes revalidate bearer account and device against principal',
    () async {
      final a = await accounts.authenticate(tokens['a']!);
      final b = await accounts.authenticate(tokens['b']!);
      for (final principal in [
        null,
        b,
        Principal(accountId: a!.accountId, deviceId: 'wrong-device'),
        Principal(accountId: 'bad!principal', deviceId: a.deviceId),
      ]) {
        final stale = Pipeline(
          router: router,
          authenticate: (_) async => principal,
        );
        for (final endpoint in [
          ('GET', Routes.friendState),
          ('POST', Routes.friendRequest),
          ('POST', Routes.friendAccept),
          ('POST', Routes.friendDeny),
          ('POST', Routes.friendBlock),
          ('DELETE', Routes.friendBlock),
        ]) {
          expect(
            (await send(endpoint.$1, endpoint.$2, through: stale)).status,
            401,
          );
        }
      }
      expect(
        (await pipeline.handle(
          HostRequest(method: 'POST', path: path(Routes.friendRequest, 'b')),
        )).status,
        401,
      );
      expect(
        (await send('POST', Routes.friendRequest, bearer: 'invalid')).status,
        401,
      );
      final stale = Pipeline(router: router, authenticate: (_) async => a);
      final session = (await accounts.scope(tokens['a']!)).value;
      await session.devices.revoke(ids['a']!, DeviceId.parse(a.deviceId));
      expect(
        (await send('POST', Routes.friendRequest, through: stale)).status,
        401,
      );
      expect(await db.query('SELECT * FROM audit_log'), isEmpty);
      expect(await db.query('SELECT * FROM friend_requests'), isEmpty);
    },
  );

  test('owner cannot accept pending request addressed to AI', () async {
    expect(
      (await send('POST', Routes.friendRequest, target: 'ai')).status,
      200,
    );
    expect(
      (await send('POST', Routes.friendAccept, actor: 'b', target: 'a')).status,
      404,
    );
    expect(
      (await send(
        'POST',
        Routes.friendAccept,
        actor: 'b',
        target: 'a',
        body: {'actor': ids['ai']!.value},
      )).status,
      400,
    );
    await state('a', 'ai', 'outgoingPending');
    expect(await db.query('SELECT * FROM friendships'), isEmpty);
    expect((await db.query('SELECT * FROM audit_log')).length, 1);
  });
}
