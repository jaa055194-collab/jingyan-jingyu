import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_module.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/device_service.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/ai/persona/persona_migrations.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/binding_migrations.dart';
import 'package:jingyu_host/src/models/models_migrations.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
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
  late String temporaryPath;
  late SqliteDatabase db;
  late AccountsDomain domain;
  late FakeClock clock;
  late Router router;
  late Pipeline pipeline;
  late Map<String, AccountId> ids;
  late Map<String, DeviceTokens> tokens;
  const password = 'own-ai-test-password';

  void mount() {
    router = Router();
    AccountsModule(domain: domain).mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(domain).call,
    );
  }

  Future<HostResponse> send(
    String method, {
    String actor = 'owner',
    Object? body,
    String? bearer,
    Pipeline? through,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: method,
      path: Routes.ownAiAccounts,
      headers: {
        'authorization': 'Bearer ${bearer ?? tokens[actor]!.accessToken}',
      },
      body: body,
    ),
  );

  Future<AccountSession> session(String actor) async =>
      (await domain.scope(tokens[actor]!.accessToken)).value;

  Future<String> create(String name, {String actor = 'owner'}) async {
    final response = await send(
      'POST',
      actor: actor,
      body: {'displayName': name},
    );
    expect(response.status, 200, reason: response.encodeBody());
    expect((response.json as Map).keys, ['accountId']);
    return (response.json as Map)['accountId'] as String;
  }

  Future<List<Object?>> list({String actor = 'owner'}) async {
    final response = await send('GET', actor: actor);
    expect(response.status, 200, reason: response.encodeBody());
    return response.json as List<Object?>;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('own-ai-accounts-');
    temporaryPath = directory.absolute.path;
    db = await SqliteDatabase.open(
      '$temporaryPath/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        friendshipMigration,
        privateConversationMigration,
        ...modelsMigrations,
        aiIdentityMigration,
        bindingMigration,
        ...personaMigrations,
      ],
    );
    clock = FakeClock(DateTime.utc(2026, 11, 14));
    domain = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    ids = {};
    tokens = {};
    ids['admin'] = (await domain.bootstrapAdmin(
      displayName: 'Admin',
      password: password,
    )).value;
    tokens['admin'] = (await domain.login(
      ids['admin']!,
      password,
      deviceName: 'admin',
    )).value;
    final admin = await session('admin');
    for (final name in ['owner', 'other']) {
      ids[name] = (await admin.accounts.createHuman(
        displayName: name,
        password: password,
      )).value;
      tokens[name] = (await domain.login(
        ids[name]!,
        password,
        deviceName: name,
      )).value;
    }
    mount();
  });

  tearDown(() async {
    await db.close();
    // Delete only the exact temporary directory created by this test.
    expect(directory.absolute.path, temporaryPath);
    expect(
      temporaryPath.startsWith(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}',
      ),
      isTrue,
    );
    expect(
      directory.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last
          .startsWith('own-ai-accounts-'),
      isTrue,
    );
    await directory.delete(recursive: true);
  });

  test(
    'nonadmin creates multiple own AI with trimmed names and isolated sorted metadata',
    () async {
      expect(await list(), isEmpty);
      final first = await create('  First AI  ');
      final second = await create('Second AI');
      final other = await create('Other AI', actor: 'other');
      final admin = await create('Admin AI', actor: 'admin');
      final expected =
          [
            {'accountId': first, 'displayName': 'First AI', 'disabled': false},
            {
              'accountId': second,
              'displayName': 'Second AI',
              'disabled': false,
            },
          ]..sort(
            (a, b) =>
                (a['accountId'] as String).compareTo(b['accountId'] as String),
          );
      expect(await list(), expected);
      expect(await list(actor: 'other'), [
        {'accountId': other, 'displayName': 'Other AI', 'disabled': false},
      ]);
      expect(await list(actor: 'admin'), [
        {'accountId': admin, 'displayName': 'Admin AI', 'disabled': false},
      ]);
      expect(
        await db.query('SELECT operator_id FROM ai_operator WHERE ai_id = ?', [
          first,
        ]),
        [
          {'operator_id': ids['owner']!.value},
        ],
      );
    },
  );

  test(
    'strict create body rejects owner admin credential and provisioning fields without writes',
    () async {
      for (final actor in ['owner', 'admin']) {
        for (final body in <Object?>[
          null,
          [],
          '',
          1,
          {},
          {'displayName': null},
          {'displayName': 3},
          {'displayName': ''},
          {'displayName': '   '},
          {'displayName': 'a' * 101},
          for (final field in [
            'operator',
            'operatorId',
            'accountId',
            'ownerId',
            'isAdmin',
            'password',
            'profileId',
            'persona',
            'model',
            'friendship',
          ])
            {'displayName': 'Rejected', field: ids['other']!.value},
        ]) {
          expect(
            (await send('POST', actor: actor, body: body)).status,
            400,
            reason: '$actor $body',
          );
        }
      }
      expect(
        await db.query("SELECT id FROM account WHERE kind = 'ai'"),
        isEmpty,
      );
    },
  );

  test(
    'creation grants no AI credentials profile persona model friendship or DM',
    () async {
      final ai = await create('Independent principal');
      expect(
        await db.query(
          'SELECT kind, is_admin, disabled, password_hash FROM account WHERE id = ?',
          [ai],
        ),
        [
          {'kind': 'ai', 'is_admin': 0, 'disabled': 0, 'password_hash': null},
        ],
      );
      expect(
        await db.query('SELECT id FROM device WHERE account_id = ?', [ai]),
        isEmpty,
      );
      expect((await db.query('SELECT device_id FROM refresh_token')).length, 3);
      expect(
        (await domain.login(
          AccountId.parse(ai),
          password,
          deviceName: 'AI login',
        )).isErr,
        isTrue,
      );
      for (final table in [
        'ai_profile',
        'persona_cards',
        'persona_history',
        'model_bindings',
        'providers',
        'friend_requests',
        'friendships',
        'account_blocks',
        'direct_conversations',
      ]) {
        expect(await db.query('SELECT * FROM $table'), isEmpty, reason: table);
      }
    },
  );

  test(
    'live metadata follows canonical mapping name and disabled state without cached ownership',
    () async {
      final ai = await create('Before');
      final retained = await session('owner');
      expect((await retained.ownAiMetadata()).value, [
        {'accountId': ai, 'displayName': 'Before', 'disabled': false},
      ]);
      await db.execute(
        'UPDATE account SET display_name = ?, disabled = 1 WHERE id = ?',
        ['After', ai],
      );
      expect((await retained.ownAiMetadata()).value, [
        {'accountId': ai, 'displayName': 'After', 'disabled': true},
      ]);
      expect(await list(), [
        {'accountId': ai, 'displayName': 'After', 'disabled': true},
      ]);
      await db.execute(
        'UPDATE ai_operator SET operator_id = ? WHERE ai_id = ?',
        [ids['other']!.value, ai],
      );
      expect((await retained.ownAiMetadata()).value, isEmpty);
      expect(await list(), isEmpty);
      expect(await list(actor: 'other'), [
        {'accountId': ai, 'displayName': 'After', 'disabled': true},
      ]);
      expect(await list(actor: 'admin'), isEmpty);
    },
  );

  test(
    'routes reject forged account device missing or invalid bearer before creating',
    () async {
      final current = (await domain.authenticate(
        tokens['owner']!.accessToken,
      ))!;
      final other = (await domain.authenticate(tokens['other']!.accessToken))!;
      for (final principal in <Principal?>[
        null,
        other,
        Principal(accountId: current.accountId, deviceId: 'wrong-device'),
        Principal(accountId: 'bad!account', deviceId: current.deviceId),
      ]) {
        final forged = Pipeline(
          router: router,
          authenticate: (_) async => principal,
        );
        for (final method in ['GET', 'POST']) {
          expect(
            (await send(
              method,
              through: forged,
              body: {'displayName': 'Spoof'},
            )).status,
            401,
          );
        }
      }
      for (final method in ['GET', 'POST']) {
        expect(
          (await send(
            method,
            bearer: 'invalid',
            body: {'displayName': 'Invalid'},
          )).status,
          401,
        );
        final forged = Pipeline(
          router: router,
          authenticate: (_) async => current,
        );
        expect(
          (await forged.handle(
            HostRequest(
              method: method,
              path: Routes.ownAiAccounts,
              body: {'displayName': 'Missing'},
            ),
          )).status,
          401,
        );
      }
      expect(
        await db.query("SELECT id FROM account WHERE kind = 'ai'"),
        isEmpty,
      );
    },
  );

  test(
    'refresh rotation revocation and expiry invalidate retained sessions and stale principals',
    () async {
      final old = tokens['owner']!;
      final principal = (await domain.authenticate(old.accessToken))!;
      final retained = await session('owner');
      final stale = Pipeline(
        router: router,
        authenticate: (_) async => principal,
      );
      tokens['owner'] = (await domain.refresh(old.refreshToken)).value;
      expect(
        (await retained.ownAiMetadata()).failureOrNull?.code,
        FailureCode.unauthenticated,
      );
      for (final method in ['GET', 'POST']) {
        expect(
          (await send(
            method,
            bearer: old.accessToken,
            through: stale,
            body: {'displayName': 'Stale'},
          )).status,
          401,
        );
      }
      await create('Current token');
      final live = await session('owner');
      await live.devices.revoke(ids['owner']!, tokens['owner']!.deviceId);
      expect((await send('GET', through: stale)).status, 401);
      expect(
        (await send(
          'POST',
          through: stale,
          body: {'displayName': 'Revoked'},
        )).status,
        401,
      );
      tokens['owner'] = (await domain.login(
        ids['owner']!,
        password,
        deviceName: 'Again',
      )).value;
      clock.advance(const Duration(hours: 1));
      expect((await send('GET', through: stale)).status, 401);
      expect(
        (await send(
          'POST',
          through: stale,
          body: {'displayName': 'Expired'},
        )).status,
        401,
      );
      expect(
        (await db.query("SELECT id FROM account WHERE kind = 'ai'")).length,
        1,
      );
    },
  );

  test(
    'disabled operator loses list and create even with previously valid capability',
    () async {
      await create('Managed AI');
      final retained = await session('owner');
      final principal = await domain.authenticate(tokens['owner']!.accessToken);
      final stale = Pipeline(
        router: router,
        authenticate: (_) async => principal,
      );
      expect(
        (await (await session('admin')).accounts.disable(ids['owner']!)).isOk,
        isTrue,
      );
      expect(
        (await retained.ownAiMetadata()).failureOrNull?.code,
        FailureCode.unauthenticated,
      );
      expect((await send('GET', through: stale)).status, 401);
      expect(
        (await send(
          'POST',
          through: stale,
          body: {'displayName': 'Disabled'},
        )).status,
        401,
      );
      expect(
        (await db.query("SELECT id FROM account WHERE kind = 'ai'")).length,
        1,
      );
    },
  );

  test(
    'existing createAi authority still denies admin creating for another owner',
    () async {
      expect(
        (await (await session('admin')).accounts.createAi(
          operator: ids['owner']!,
          displayName: 'Cross owner',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await (await session('owner')).accounts.createAi(
          operator: ids['other']!,
          displayName: 'Cross owner',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        await db.query("SELECT id FROM account WHERE kind = 'ai'"),
        isEmpty,
      );
    },
  );

  test(
    'AI accounts and disabled metadata survive reopen with current original human token',
    () async {
      final ai = await create('Persisted');
      expect(
        (await (await session(
          'owner',
        )).accounts.disable(AccountId.parse(ai))).isOk,
        isTrue,
      );
      await db.close();
      db = await SqliteDatabase.open('$temporaryPath/host.sqlite');
      domain = AccountsDomain(
        store: SqlAccountsStore(db),
        clock: clock,
        hasher: _FastHasher(),
      );
      mount();
      expect(await list(), [
        {'accountId': ai, 'displayName': 'Persisted', 'disabled': true},
      ]);
      expect(await list(actor: 'other'), isEmpty);
      await create('After reopen');
      expect((await list()).length, 2);
      expect(await db.query('PRAGMA foreign_key_check'), isEmpty);
    },
  );
}
