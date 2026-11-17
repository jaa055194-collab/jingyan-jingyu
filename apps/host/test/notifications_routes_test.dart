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
  late Pipeline pipeline;
  late Map<String, AccountId> ids;
  late Map<String, String> tokens;
  const password = 'test-password-long';

  Future<HostResponse> send(
    String method,
    String route, {
    String actor = 'a',
    String target = 'b',
    Object? body,
    String? bearer,
  }) => pipeline.handle(
    HostRequest(
      method: method,
      path: route.replaceFirst('{accountId}', ids[target]!.value),
      headers: {'authorization': 'Bearer ${bearer ?? tokens[actor]}'},
      body: body,
    ),
  );

  Future<HostResponse> notifications({
    String actor = 'b',
    Map<String, String> query = const {},
    Object? body,
    String? bearer,
  }) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: Routes.notifications,
      query: query,
      headers: {'authorization': 'Bearer ${bearer ?? tokens[actor]}'},
      body: body,
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('notifications-');
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
    final router = Router();
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
    'owner-scoped notifications expose only metadata of incoming invites',
    () async {
      await send('POST', Routes.friendRequest, actor: 'a', target: 'b');
      await send('POST', Routes.friendRequest, actor: 'c', target: 'b');

      final forB = await notifications(actor: 'b');
      expect(forB.status, 200);
      final items = (forB.json! as List).cast<Map<String, Object?>>();
      expect(items.length, 2);
      expect(items.map((i) => i['refId']).toSet(), {
        ids['a']!.value,
        ids['c']!.value,
      });
      for (final item in items) {
        expect(item.keys.toSet(), {
          'kind',
          'title',
          'status',
          'createdAt',
          'refId',
        });
        expect(item['kind'], 'friendRequest');
        expect(item['status'], 'pending');
        expect(DateTime.tryParse(item['createdAt'] as String), isNotNull);
      }
      // No private content / message / blob fields are ever emitted.
      final encoded = jsonEncode(forB.json);
      expect(encoded, isNot(contains('message')));
      expect(encoded, isNot(contains('text')));
      expect(encoded, isNot(contains('body')));

      // Sender and unrelated account see no incoming invites.
      expect((await notifications(actor: 'a')).json, isEmpty);
      expect((await notifications(actor: 'c')).json, isEmpty);
    },
  );

  test(
    'resolved invites leave the inbox and limit bounds are enforced',
    () async {
      await send('POST', Routes.friendRequest, actor: 'a', target: 'b');
      await send('POST', Routes.friendRequest, actor: 'c', target: 'b');
      expect((await notifications(actor: 'b')).status, 200);
      expect(((await notifications(actor: 'b')).json as List).length, 2);

      expect(
        (await notifications(actor: 'b', query: {'limit': '1'})).json,
        hasLength(1),
      );
      expect(
        (await send(
          'POST',
          Routes.friendAccept,
          actor: 'b',
          target: 'a',
        )).status,
        200,
      );
      final after = (await notifications(actor: 'b')).json as List;
      expect(after.length, 1);
      expect((after.single as Map)['refId'], ids['c']!.value);
    },
  );

  test('malformed parameters and anonymous calls fail safely', () async {
    for (final query in [
      {'limit': '0'},
      {'limit': '101'},
      {'limit': 'abc'},
      {'unknown': '1'},
    ]) {
      expect((await notifications(actor: 'b', query: query)).status, 400);
    }
    expect((await notifications(actor: 'b', body: const {'x': 1})).status, 400);
    expect((await notifications(bearer: 'invalid-token')).status, 401);
  });
}
