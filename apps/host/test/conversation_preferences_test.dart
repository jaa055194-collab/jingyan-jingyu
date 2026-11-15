import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/device_service.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/social/conversation_preferences.dart';
import 'package:jingyu_host/src/social/conversation_preferences_migration.dart';
import 'package:jingyu_host/src/social/conversation_preferences_routes.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

class _Hasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String value) async => 'fixture:$value';
  @override
  Future<bool> verifyAsync(String value, String hash) async =>
      hash == 'fixture:$value';
}

// Enforce supplied-Tx membership/read/write composition, never outer DB calls.
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
      throw StateError('Outer execute');
  @override
  Future<int> schemaVersion() => throw StateError('Unexpected');
  @override
  Future<String> integrityCheck() => throw StateError('Unexpected');
}

const _migrations = [
  ...allMigrations,
  ...accountsMigrations,
  ...socialMigrations,
  friendshipMigration,
  privateConversationMigration,
  conversationPreferencesMigration,
];
void main() {
  late Directory directory;
  late SqliteDatabase db;
  late FakeClock clock;
  late AccountsDomain accounts;
  late Map<String, AccountId> ids;
  late Map<String, DeviceTokens> tokens;
  late ConversationPreferences prefs;
  late Router router;
  late Pipeline pipeline;
  const password = 'conversation-preference-test';

  Future<void> open() async {
    db = await SqliteDatabase.open(
      '${directory.path}/db.sqlite',
      migrations: _migrations,
    );
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _Hasher(),
    );
    prefs = ConversationPreferences(database: db);
    router = Router();
    mountConversationPreferenceRoutes(router, db: db, accounts: accounts);
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(accounts).call,
    );
  }

  Future<void> group(String id, {String owner = 'owner'}) async {
    await db.execute('INSERT INTO social_conversations VALUES(?,?,?,?,?)', [
      id,
      ids[owner]!.value,
      'Group',
      'all',
      0,
    ]);
    await db.execute('INSERT INTO social_members VALUES(?,?,?,?)', [
      id,
      ids[owner]!.value,
      0,
      1,
    ]);
  }

  Future<void> member(String group, String actor) => db.execute(
    'INSERT INTO social_members VALUES(?,?,?,?)',
    [group, ids[actor]!.value, 0, 1],
  );
  Future<void> direct(String id) async {
    final pair = [ids['owner']!.value, ids['other']!.value]..sort();
    await db.execute('INSERT INTO direct_conversations VALUES(?,?,?,?)', [
      id,
      ...pair,
      0,
    ]);
  }

  Future<HostResponse> call(
    String method, {
    String conversation = 'group',
    String actor = 'owner',
    Object? body,
    bool anonymous = false,
    String? bearer,
    Pipeline? through,
    Map<String, String> query = const {},
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: method,
      path: '/api/v1/conversations/$conversation/preferences',
      body: body,
      query: query,
      headers: {
        if (!anonymous)
          'authorization': 'Bearer ${bearer ?? tokens[actor]!.accessToken}',
      },
    ),
  );
  Map<String, Object?> json(HostResponse response) {
    expect(response.status, 200, reason: response.encodeBody());
    return (response.json as Map).cast<String, Object?>();
  }

  Future<Result<Map<String, Object?>>> get({
    String actor = 'owner',
    String conversation = 'group',
  }) => prefs.get(accountId: ids[actor]!.value, conversationId: conversation);
  Future<Result<Map<String, Object?>>> set(
    bool pinned, {
    String actor = 'owner',
    String conversation = 'group',
  }) => prefs.set(
    accountId: ids[actor]!.value,
    conversationId: conversation,
    pinned: pinned,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('conversation-prefs-');
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
    for (final name in ['owner', 'other']) {
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
    await group('group');
    await member('group', 'other');
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'absent preference is false without insert; true false and repeat are persistent',
    () async {
      expect((await get()).value, {'pinned': false});
      expect(await db.query('SELECT * FROM conversation_preferences'), isEmpty);
      expect((await set(true)).value, {'pinned': true});
      expect((await set(true)).value, {'pinned': true});
      expect(
        await db.query('SELECT * FROM conversation_preferences'),
        hasLength(1),
      );
      await db.close();
      await open();
      expect((await get()).value, {'pinned': true});
      expect((await set(false)).value, {'pinned': false});
      expect((await get()).value, {'pinned': false});
    },
  );

  test(
    'preferences bind both account and conversation and do not reorder lists',
    () async {
      await group('another');
      await set(true);
      expect((await get(actor: 'other')).value, {'pinned': false});
      expect((await get(conversation: 'another')).value, {'pinned': false});
      expect((await set(true, actor: 'other')).isOk, true);
      expect(
        await db.query('SELECT * FROM conversation_preferences'),
        hasLength(2),
      );
      expect(
        (await db.query(
          'SELECT id FROM social_conversations ORDER BY created_at,id',
        )).map((r) => r['id']),
        ['another', 'group'],
      );
    },
  );

  test(
    'outsider admin missing and ambiguous kinds deny without changing preferences',
    () async {
      expect(
        (await get(actor: 'admin')).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await set(true, actor: 'admin')).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await get(conversation: 'missing')).failureOrNull?.code,
        FailureCode.notFound,
      );
      await direct('group');
      for (final actor in ['owner', 'other', 'admin']) {
        expect(
          (await get(actor: actor)).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await set(true, actor: actor)).failureOrNull?.code,
          FailureCode.notFound,
        );
      }
      expect(await db.query('SELECT * FROM conversation_preferences'), isEmpty);
    },
  );

  test(
    'fixed direct participants can pin their history even when posting blocked',
    () async {
      await direct('direct');
      await db.execute('INSERT INTO account_blocks VALUES(?,?,?)', [
        ids['owner']!.value,
        ids['other']!.value,
        0,
      ]);
      expect((await set(true, conversation: 'direct')).value, {'pinned': true});
      expect((await get(actor: 'other', conversation: 'direct')).value, {
        'pinned': false,
      });
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', [
        ids['other']!.value,
      ]);
      expect((await get(conversation: 'direct')).value, {'pinned': true});
      expect(
        (await get(actor: 'other', conversation: 'direct')).failureOrNull?.code,
        FailureCode.notFound,
      );
    },
  );

  test(
    'leaving hides but does not clear own preference and current rejoin restores access',
    () async {
      await set(true, actor: 'other');
      await db.execute(
        'DELETE FROM social_members WHERE conversation_id=? AND account_id=?',
        ['group', ids['other']!.value],
      );
      expect(
        (await get(actor: 'other')).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await set(false, actor: 'other')).failureOrNull?.code,
        FailureCode.notFound,
      );
      await member('group', 'other');
      expect((await get(actor: 'other')).value, {'pinned': true});
    },
  );

  test(
    'inactive account and invalid canonical AI operator deny both operations',
    () async {
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', [
        ids['owner']!.value,
      ]);
      expect((await get()).failureOrNull?.code, FailureCode.notFound);
      expect((await set(true)).failureOrNull?.code, FailureCode.notFound);
      await db.execute('UPDATE account SET disabled=0 WHERE id=?', [
        ids['owner']!.value,
      ]);
      final owner = (await accounts.scope(tokens['owner']!.accessToken)).value;
      ids['ai'] = (await owner.accounts.createAi(
        operator: ids['owner']!,
        displayName: 'AI',
      )).value;
      await member('group', 'ai');
      expect((await set(true, actor: 'ai')).isOk, true);
      await db.execute('DELETE FROM ai_operator WHERE ai_id=?', [
        ids['ai']!.value,
      ]);
      expect(
        (await get(actor: 'ai')).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await set(false, actor: 'ai')).failureOrNull?.code,
        FailureCode.notFound,
      );
    },
  );

  test(
    'HTTP reads writes strict boolean only and rejects actor overrides without writes',
    () async {
      expect(json(await call('GET')), {'pinned': false});
      expect(json(await call('PUT', body: {'pinned': true})), {'pinned': true});
      for (final body in <Object?>[
        null,
        [],
        {},
        {'pinned': null},
        {'pinned': 'true'},
        {'pinned': 1},
        {'pinned': true, 'accountId': ids['other']!.value},
        {'pinned': true, 'mute': true},
      ]) {
        expect((await call('PUT', body: body)).status, 400);
      }
      expect(
        (await call('GET', query: {'accountId': ids['other']!.value})).status,
        400,
      );
      expect((await call('GET', conversation: 'bad id')).status, 400);
      expect((await call('GET', actor: 'admin')).status, 404);
      expect(
        (await call('PUT', actor: 'admin', body: {'pinned': true})).status,
        404,
      );
      expect(json(await call('GET')), {'pinned': true});
      expect(
        await db.query('SELECT * FROM conversation_preferences'),
        hasLength(1),
      );
    },
  );

  test(
    'HTTP anonymous stale revoked expired and mismatched identity fail closed',
    () async {
      expect((await call('GET', anonymous: true)).status, 401);
      final principal = (await accounts.authenticate(
        tokens['owner']!.accessToken,
      ))!;
      final cached = Pipeline(
        router: router,
        authenticate: (_) async => principal,
      );
      expect((await call('GET', actor: 'other', through: cached)).status, 401);
      final wrong = Pipeline(
        router: router,
        authenticate: (_) async =>
            Principal(accountId: principal.accountId, deviceId: 'wrong'),
      );
      expect((await call('GET', through: wrong)).status, 401);
      final fresh = (await accounts.refresh(
        tokens['owner']!.refreshToken,
      )).value;
      expect(
        (await call('PUT', body: {'pinned': true}, through: cached)).status,
        401,
      );
      final session = (await accounts.scope(fresh.accessToken)).value;
      await session.devices.revoke(ids['owner']!, fresh.deviceId);
      expect((await call('GET', bearer: fresh.accessToken)).status, 401);
      final again = (await accounts.login(
        ids['owner']!,
        password,
        deviceName: 'again',
      )).value;
      clock.advance(const Duration(hours: 1));
      expect((await call('GET', bearer: again.accessToken)).status, 401);
      expect(await db.query('SELECT * FROM conversation_preferences'), isEmpty);
    },
  );

  test(
    'membership and preference operations use only supplied Tx and rollback on failure',
    () async {
      final scoped = ConversationPreferences(database: _OnlyTx(db));
      expect(
        (await scoped.set(
          accountId: ids['owner']!.value,
          conversationId: 'group',
          pinned: true,
        )).isOk,
        true,
      );
      expect(
        (await scoped.get(
          accountId: ids['owner']!.value,
          conversationId: 'group',
        )).value,
        {'pinned': true},
      );
      await db.execute(
        "CREATE TRIGGER refuse_unpin BEFORE UPDATE ON conversation_preferences BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      await expectLater(set(false), throwsA(isA<Exception>()));
      expect((await get()).value, {'pinned': true});
    },
  );
}
