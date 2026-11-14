import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/device_service.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/ai/persona/persona_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_module.dart';
import 'package:jingyu_host/src/ai/persona/persona_service.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

class _FastHasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String value) async => 'test:$value';
  @override
  Future<bool> verifyAsync(String value, String hash) async =>
      hash == 'test:$value';
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late FakeClock clock;
  late AccountsDomain accounts;
  late Map<String, AccountId> ids;
  late Map<String, DeviceTokens> tokens;
  late AccountId aiAccount;
  late AiId ai;
  late Router router;
  late Pipeline pipeline;
  const password = 'persona-route-test-password';

  Map<String, Object?> initial() => {
    'p0': {'name': 'Nora', 'boundary': 'Respect privacy'},
    'p1': {'style': 'warm'},
    'p2': {'mood': 'calm'},
  };

  Future<void> open() async {
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        aiIdentityMigration,
        ...personaMigrations,
      ],
    );
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    final module = PersonaModule(
      database: db,
      cipher: cipher,
      clock: clock,
      authenticate: DbAuthenticator(accounts).call,
    );
    router = Router();
    module.mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(accounts).call,
    );
  }

  Future<HostResponse> call(
    String method, {
    String suffix = '',
    Object? body,
    String actor = 'owner',
    bool anonymous = false,
    String? bearer,
    String? profile,
    Pipeline? through,
    Map<String, String> query = const {},
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: method,
      path: '/api/v1/ai-profiles/${profile ?? ai.value}/persona$suffix',
      body: body,
      query: query,
      headers: {
        if (!anonymous)
          'authorization': 'Bearer ${bearer ?? tokens[actor]!.accessToken}',
      },
    ),
  );

  Future<void> initialize() async {
    final response = await call('POST', suffix: '/initialize', body: initial());
    expect(response.status, 200, reason: response.encodeBody());
  }

  Map<String, Object?> json(HostResponse response) {
    expect(response.status, 200, reason: response.encodeBody());
    return (response.json as Map).cast<String, Object?>();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('persona-http-');
    clock = FakeClock(DateTime.utc(2026, 11, 15));
    cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
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
    final owner = (await accounts.scope(tokens['owner']!.accessToken)).value;
    aiAccount = (await owner.accounts.createAi(
      operator: ids['owner']!,
      displayName: 'AI',
    )).value;
    ai = (await AiIdentityResolver.forOwner(
      ownerId: ids['owner']!.value,
      db: db,
    ).register(aiAccount)).value.profileId;
  });

  tearDown(() async {
    await db.close();
    cipher.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'read does not initialize; explicit complete initialization persists encrypted card/history',
    () async {
      expect((await call('GET')).status, 404);
      expect(await db.query('SELECT * FROM persona_cards'), isEmpty);
      final initialized = json(
        await call('POST', suffix: '/initialize', body: initial()),
      );
      expect(initialized, {
        'aiId': ai.value,
        'version': 1,
        'locked': false,
        'layers': initial(),
      });
      expect(json(await call('GET')), initialized);
      expect(
        (await call('POST', suffix: '/initialize', body: initial())).status,
        409,
      );
      for (final table in ['persona_cards', 'persona_history']) {
        final raw = jsonEncode(await db.query('SELECT * FROM $table'));
        for (final text in ['Nora', 'Respect privacy', 'warm', 'calm']) {
          expect(raw, isNot(contains(text)));
        }
      }
      await db.close();
      await open();
      expect(json(await call('GET')), initialized);
    },
  );

  test(
    'manual edits use CAS and append history without caller actor or version metadata',
    () async {
      await initialize();
      final edited = json(
        await call(
          'PATCH',
          body: {
            'expectedVersion': 1,
            'reason': 'Owner changed speaking style',
            'diff': {
              'p1': {'style': 'concise', 'humor': 'gentle'},
            },
          },
        ),
      );
      expect(edited['version'], 2);
      expect(((edited['layers'] as Map)['p1'] as Map)['style'], 'concise');
      expect(
        (await call(
          'PATCH',
          body: {
            'expectedVersion': 1,
            'reason': 'stale',
            'diff': {
              'p1': {'style': 'old'},
            },
          },
        )).status,
        409,
      );
      expect(
        (await db.query(
          'SELECT version,actor_id,kind FROM persona_history ORDER BY version',
        )).map((r) => r['version']),
        [1, 2],
      );
      expect(
        (await db.query(
          'SELECT actor_id FROM persona_history WHERE version=2',
        )).single['actor_id'],
        ids['owner']!.value,
      );
    },
  );

  test(
    'lock/unlock consumes versions but owner edits remain allowed; P2 stays autonomous internally',
    () async {
      await initialize();
      expect(
        json(
          await call(
            'PUT',
            suffix: '/lock',
            body: {'expectedVersion': 1, 'locked': true},
          ),
        )['version'],
        2,
      );
      expect(
        (await call(
          'PUT',
          suffix: '/lock',
          body: {'expectedVersion': 2, 'locked': true},
        )).status,
        409,
      );
      final edited = json(
        await call(
          'PATCH',
          body: {
            'expectedVersion': 2,
            'reason': 'Manual owner edit',
            'diff': {
              'p0': {'name': 'Nova'},
            },
          },
        ),
      );
      expect(edited['version'], 3);
      expect(edited['locked'], true);
      final internal = SqlitePersonaService.forOwner(
        ownerId: ids['owner']!.value,
        actorAccountId: aiAccount.value,
        database: db,
        cipher: cipher,
        clock: clock,
      );
      expect(
        (await internal.selfIterate(
          ai,
          PersonaDiff(p1: {'style': 'blocked'}),
          expectedVersion: 3,
          reason: 'internal check',
          evidenceIds: ['source'],
        )).failureOrNull?.code,
        FailureCode.forbidden,
      );
      expect(
        (await internal.selfIterate(
          ai,
          PersonaDiff(p2: {'mood': 'happy'}),
          expectedVersion: 3,
          reason: 'internal check',
          evidenceIds: ['source'],
        )).isOk,
        true,
      );
      expect(
        json(
          await call(
            'PUT',
            suffix: '/lock',
            body: {'expectedVersion': 4, 'locked': false},
          ),
        )['version'],
        5,
      );
    },
  );

  test(
    'concurrent patches on one expected version cannot lose an accepted update',
    () async {
      await initialize();
      final responses = await Future.wait(
        ['short', 'playful'].map(
          (style) => call(
            'PATCH',
            body: {
              'expectedVersion': 1,
              'reason': 'Owner adjustment',
              'diff': {
                'p1': {'style': style},
              },
            },
          ),
        ),
      );
      expect(responses.where((r) => r.status == 200), hasLength(1));
      expect(responses.where((r) => r.status == 409), hasLength(1));
      expect(json(await call('GET'))['version'], 2);
      expect(await db.query('SELECT * FROM persona_history'), hasLength(2));
    },
  );

  test(
    'strict initialization rejects missing layers forged ownership and malformed maps without writes',
    () async {
      for (final body in <Object?>[
        null,
        [],
        {},
        {
          'p0': {},
          'p1': {'style': 'warm'},
          'p2': {'mood': 'calm'},
        },
        {
          'p0': {'name': 3},
          'p1': {'style': 'warm'},
          'p2': {'mood': 'calm'},
        },
        {...initial(), 'ownerId': ids['other']!.value},
        {...initial(), 'actorAccountId': aiAccount.value},
        {...initial(), 'locked': true},
      ]) {
        expect(
          (await call('POST', suffix: '/initialize', body: body)).status,
          400,
        );
      }
      expect(await db.query('SELECT * FROM persona_cards'), isEmpty);
      expect(await db.query('SELECT * FROM persona_history'), isEmpty);
    },
  );

  test('invalid patch or lock never changes version or history', () async {
    await initialize();
    for (final body in <Object?>[
      {},
      {
        'expectedVersion': '1',
        'reason': 'x',
        'diff': {
          'p1': {'style': 'x'},
        },
      },
      {
        'expectedVersion': 1.0,
        'reason': 'x',
        'diff': {
          'p1': {'style': 'x'},
        },
      },
      {
        'expectedVersion': 1,
        'reason': '',
        'diff': {
          'p1': {'style': 'x'},
        },
      },
      {
        'expectedVersion': 1,
        'reason': 'x',
        'diff': {
          'p3': {'style': 'x'},
        },
      },
      {
        'expectedVersion': 1,
        'reason': 'x',
        'diff': {
          'p1': {'style': 3},
        },
      },
      {
        'expectedVersion': 1,
        'reason': 'x',
        'diff': {
          'p1': {'style': null},
        },
      },
      {'expectedVersion': 1, 'reason': 'x', 'diff': {}},
      {
        'expectedVersion': 1,
        'reason': 'x',
        'diff': {
          'p1': {'style': 'warm'},
        },
        'actorId': aiAccount.value,
      },
    ]) {
      expect((await call('PATCH', body: body)).status, 400);
    }
    expect(
      (await call(
        'PUT',
        suffix: '/lock',
        body: {'expectedVersion': 1, 'locked': true, 'actorId': 'other'},
      )).status,
      400,
    );
    expect(
      (await call(
        'PUT',
        suffix: '/lock',
        body: {'expectedVersion': 1, 'locked': 'true'},
      )).status,
      400,
    );
    expect(json(await call('GET'))['version'], 1);
    expect(await db.query('SELECT * FROM persona_history'), hasLength(1));
  });

  test(
    'other people and admin cannot read or mutate persona; AI account id is not profile id',
    () async {
      await initialize();
      for (final actor in ['admin', 'other']) {
        expect((await call('GET', actor: actor)).status, 404);
        expect(
          (await call(
            'POST',
            actor: actor,
            suffix: '/initialize',
            body: initial(),
          )).status,
          404,
        );
        expect(
          (await call(
            'PATCH',
            actor: actor,
            body: {
              'expectedVersion': 1,
              'reason': 'x',
              'diff': {
                'p1': {'style': 'x'},
              },
            },
          )).status,
          404,
        );
        expect(
          (await call(
            'PUT',
            actor: actor,
            suffix: '/lock',
            body: {'expectedVersion': 1, 'locked': true},
          )).status,
          404,
        );
      }
      expect((await call('GET', profile: aiAccount.value)).status, 404);
      expect((await call('GET', profile: 'bad id')).status, 400);
      expect(
        (await call('GET', query: {'ownerId': ids['other']!.value})).status,
        400,
      );
    },
  );

  test(
    'operator transfer neither leaks old ciphertext nor silently reinitializes persona',
    () async {
      await initialize();
      await db.execute('UPDATE ai_operator SET operator_id=? WHERE ai_id=?', [
        ids['other']!.value,
        aiAccount.value,
      ]);
      expect((await call('GET')).status, 404);
      expect((await call('GET', actor: 'other')).status, 404);
      expect(
        (await call(
          'POST',
          actor: 'other',
          suffix: '/initialize',
          body: initial(),
        )).status,
        409,
      );
      expect(await db.query('SELECT * FROM persona_history'), hasLength(1));
    },
  );

  test(
    'anonymous stale and mismatched account/device bearers fail closed',
    () async {
      await initialize();
      expect((await call('GET', anonymous: true)).status, 401);
      final principal = (await accounts.authenticate(
        tokens['owner']!.accessToken,
      ))!;
      final spoofed = Pipeline(
        router: router,
        authenticate: (_) async => principal,
      );
      expect((await call('GET', actor: 'other', through: spoofed)).status, 401);
      final wrong = Pipeline(
        router: router,
        authenticate: (_) async =>
            Principal(accountId: principal.accountId, deviceId: 'wrong'),
      );
      expect((await call('GET', through: wrong)).status, 401);
      final fresh = (await accounts.refresh(
        tokens['owner']!.refreshToken,
      )).value;
      expect((await call('GET')).status, 401);
      final session = (await accounts.scope(fresh.accessToken)).value;
      await session.devices.revoke(ids['owner']!, fresh.deviceId);
      expect((await call('GET', bearer: fresh.accessToken)).status, 401);
      final relogged = (await accounts.login(
        ids['owner']!,
        password,
        deviceName: 'expired-session',
      )).value;
      clock.advance(const Duration(hours: 1));
      expect((await call('GET', bearer: relogged.accessToken)).status, 401);
    },
  );

  test(
    'oversized in-process initialization and patch cannot write persona data',
    () async {
      final tooLarge = 'x' * ((1 << 20) + 1);
      final rejected = await call(
        'POST',
        suffix: '/initialize',
        body: {
          'p0': {'name': tooLarge},
          'p1': {'style': 'warm'},
          'p2': {'mood': 'calm'},
        },
      );
      expect(rejected.status, 400);
      expect(await db.query('SELECT * FROM persona_cards'), isEmpty);
      await initialize();
      expect(
        (await call(
          'PATCH',
          body: {
            'expectedVersion': 1,
            'reason': tooLarge,
            'diff': {
              'p1': {'style': 'brief'},
            },
          },
        )).status,
        400,
      );
      expect(json(await call('GET'))['version'], 1);
      expect(await db.query('SELECT * FROM persona_history'), hasLength(1));
    },
  );

  test(
    'AI bearer cannot impersonate its owner at the configuration boundary',
    () async {
      await initialize();
      final forged = Pipeline(
        router: router,
        authenticate: (_) async =>
            Principal(accountId: aiAccount.value, deviceId: 'ai-device'),
      );
      // Even with an active AI execution identity supplied by a trusted custom
      // authenticator, owner scope must be that AI itself, never its human owner.
      final module = PersonaModule(
        database: db,
        cipher: cipher,
        clock: clock,
        authenticate: (_) async =>
            Principal(accountId: aiAccount.value, deviceId: 'ai-device'),
      );
      final aiRouter = Router();
      module.mount(aiRouter);
      final aiPipeline = Pipeline(
        router: aiRouter,
        authenticate: (_) async =>
            Principal(accountId: aiAccount.value, deviceId: 'ai-device'),
      );
      expect((await call('GET', through: aiPipeline)).status, 404);
      expect((await call('GET', through: forged)).status, 401);
      expect(await db.query('SELECT * FROM persona_history'), hasLength(1));
    },
  );

  test('disabled AI or human cannot access persona', () async {
    await initialize();
    await db.execute('UPDATE account SET disabled=1 WHERE id=?', [
      aiAccount.value,
    ]);
    expect((await call('GET')).status, 404);
    await db.execute('UPDATE account SET disabled=0 WHERE id=?', [
      aiAccount.value,
    ]);
    await db.execute('UPDATE account SET disabled=1 WHERE id=?', [
      ids['owner']!.value,
    ]);
    expect((await call('GET')).status, 401);
  });

  test(
    'corrupt card is a safe internal error and does not append history',
    () async {
      await initialize();
      await db.execute(
        'UPDATE persona_cards SET encrypted_card=? WHERE ai_profile_id=?',
        ['damaged', ai.value],
      );
      final response = await call('GET');
      expect(response.status, 500);
      expect(response.json, {'error': 'internal'});
      expect(
        (await call(
          'PATCH',
          body: {
            'expectedVersion': 1,
            'reason': 'x',
            'diff': {
              'p1': {'style': 'x'},
            },
          },
        )).status,
        500,
      );
      expect(await db.query('SELECT * FROM persona_history'), hasLength(1));
    },
  );
}
