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
  late Pipeline pipeline;
  late Map<String, AccountId> ids;
  late Map<String, String> tokens;
  const password = 'test-password-long';

  Future<HostResponse> list(
    String actor, {
    Map<String, String> query = const {},
    Object? body,
    bool authenticated = true,
  }) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: Routes.friends,
      headers: authenticated
          ? {'authorization': 'Bearer ${tokens[actor]}'}
          : const {},
      query: query,
      body: body,
    ),
  );

  Future<HostResponse> post(
    String route, {
    required String actor,
    required String target,
  }) => pipeline.handle(
    HostRequest(
      method: 'POST',
      path: route.replaceFirst('{accountId}', ids[target]!.value),
      headers: {'authorization': 'Bearer ${tokens[actor]}'},
    ),
  );

  List<Map<String, Object?>> rows(HostResponse response) {
    expect(response.status, 200);
    return (response.json as List).cast<Map<String, Object?>>();
  }

  Future<void> befriend(String a, String b) async {
    expect((await post(Routes.friendRequest, actor: a, target: b)).status, 200);
    expect((await post(Routes.friendAccept, actor: b, target: a)).status, 200);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('friends-list-route-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        friendshipMigration,
      ],
    );
    final clock = FakeClock(DateTime.utc(2026, 11, 17));
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    ids = {};
    tokens = {};
    ids['a'] = (await accounts.bootstrapAdmin(
      displayName: 'Alice',
      password: password,
    )).value;
    tokens['a'] = (await accounts.login(
      ids['a']!,
      password,
      deviceName: 'A device',
    )).value.accessToken;
    final admin = (await accounts.scope(tokens['a']!)).value;
    for (final name in ['Bob', 'Carol']) {
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
    // Short aliases keep the test call sites readable.
    ids['b'] = ids['Bob']!;
    ids['c'] = ids['Carol']!;
    tokens['b'] = tokens['Bob']!;
    tokens['c'] = tokens['Carol']!;
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

  test('empty list for an account without relationships', () async {
    expect(rows(await list('a')), isEmpty);
  });

  test('owner-scoped friends only, with account display names', () async {
    await befriend('a', 'b');

    final alice = rows(await list('a'));
    expect(alice, [
      {'accountId': ids['b']!.value, 'displayName': 'Bob', 'state': 'friends'},
    ]);
    final bob = rows(await list('Bob'));
    expect(bob, [
      {
        'accountId': ids['a']!.value,
        'displayName': 'Alice',
        'state': 'friends',
      },
    ]);
    // Unrelated account sees nothing; friends are not globally visible.
    expect(rows(await list('Carol')), isEmpty);
  });

  test('pending requests map to outgoing/incoming state per caller', () async {
    expect(
      (await post(Routes.friendRequest, actor: 'a', target: 'Bob')).status,
      200,
    );

    expect(rows(await list('a')), [
      {
        'accountId': ids['Bob']!.value,
        'displayName': 'Bob',
        'state': 'outgoingPending',
      },
    ]);
    expect(rows(await list('Bob')), [
      {
        'accountId': ids['a']!.value,
        'displayName': 'Alice',
        'state': 'incomingPending',
      },
    ]);
  });

  test(
    'blocked contacts are listed only for the blocker, never the blocked side',
    () async {
      expect(
        (await post(Routes.friendRequest, actor: 'a', target: 'Carol')).status,
        200,
      );
      expect(
        (await post(Routes.friendBlock, actor: 'a', target: 'Carol')).status,
        200,
      );

      expect(rows(await list('a')), [
        {
          'accountId': ids['Carol']!.value,
          'displayName': 'Carol',
          'state': 'blocked',
        },
      ]);
      // Carol blocked back? No: Alice is the blocker. Carol must not learn Alice's list.
      expect(rows(await list('Carol')), isEmpty);

      // A separate incoming block is not disclosed to the blocked side.
      expect(
        (await post(Routes.friendBlock, actor: 'Carol', target: 'Bob')).status,
        200,
      );
      expect(rows(await list('Bob')), isEmpty);
    },
  );

  test(
    'state mapping across friends, pending and blocked is deterministic',
    () async {
      await befriend('a', 'b');
      expect(
        (await post(Routes.friendRequest, actor: 'a', target: 'Carol')).status,
        200,
      );

      final contacts = rows(await list('a'));
      expect(contacts.map((row) => row['state']).toList(), [
        'friends',
        'outgoingPending',
      ]);
      expect(contacts.map((row) => row['accountId']).toSet(), {
        ids['b']!.value,
        ids['Carol']!.value,
      });
    },
  );

  test(
    'unauthenticated, query, body and malformed callers fail safely',
    () async {
      expect((await list('a', authenticated: false)).status, 401);
      expect((await list('a', query: const {'owner': 'b'})).status, 400);
      expect((await list('a', body: const <String, Object?>{})).status, 400);
      expect((await list('a', body: <String, Object?>{'x': 1})).status, 400);
    },
  );
}
