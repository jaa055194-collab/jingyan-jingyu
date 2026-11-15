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

  Future<void> editStyle(int version, String style) async {
    expect(
      (await call(
        'PATCH',
        body: {
          'expectedVersion': version,
          'reason': 'Style adjustment $style',
          'diff': {
            'p1': {'style': style},
          },
        },
      )).status,
      200,
    );
  }

  List<Map<String, Object?>> changes(Map<String, Object?> page) =>
      (page['changes'] as List)
          .map((e) => (e as Map).cast<String, Object?>())
          .toList();

  test(
    'history pages expose ordered changes with reasons and immutable snapshots',
    () async {
      expect((await call('GET', suffix: '/history')).status, 404);
      await initialize();
      await editStyle(1, 'brief');
      await editStyle(2, 'playful');
      final first = json(
        await call('GET', suffix: '/history', query: {'limit': '2'}),
      );
      expect(changes(first).map((c) => c['version']), [1, 2]);
      expect(first['nextAfterVersion'], 2);
      final edit = changes(first)[1];
      expect(edit['kind'], 'edit');
      expect(edit['actorAccountId'], ids['owner']!.value);
      expect(edit['before'], initial());
      expect((edit['after'] as Map)['p1'], {'style': 'brief'});
      expect(edit['diff'], {
        'p0': {},
        'p1': {'style': 'brief'},
        'p2': {},
      });
      expect(edit['reason'], 'Style adjustment brief');
      expect(edit['evidenceIds'], []);
      expect(DateTime.parse(edit['at'] as String), clock.now());
      expect(edit['lockedBefore'], false);
      expect(edit['lockedAfter'], false);
      expect(edit['revertsChangeId'], null);
      expect(edit['id'], isNotEmpty);
      final last = json(
        await call(
          'GET',
          suffix: '/history',
          query: {'afterVersion': '2', 'limit': '2'},
        ),
      );
      expect(changes(last).map((c) => c['version']), [3]);
      expect(last['nextAfterVersion'], null);
      expect(
        changes(
          json(
            await call('GET', suffix: '/history', query: {'afterVersion': '3'}),
          ),
        ),
        isEmpty,
      );
      await db.close();
      await open();
      expect(
        changes(
          json(await call('GET', suffix: '/history')),
        ).map((c) => c['version']),
        [1, 2, 3],
      );
    },
  );

  test(
    'history pagination validates bounds and does not decrypt outside its returned page',
    () async {
      await initialize();
      await editStyle(1, 'brief');
      for (final query in <Map<String, String>>[
        {'limit': '0'},
        {'limit': '101'},
        {'limit': '-1'},
        {'limit': '1.0'},
        {'limit': '+1'},
        {'limit': ' 1'},
        {'limit': '0x10'},
        {'limit': '1\n'},
        {'limit': '１'},
        {'afterVersion': ''},
        {'afterVersion': '+1'},
        {'limit': ''},
        {'afterVersion': '-1'},
        {'afterVersion': '1e2'},
        {'afterVersion': '9' * 100},
        {'ownerId': ids['owner']!.value},
      ]) {
        expect(
          (await call('GET', suffix: '/history', query: query)).status,
          400,
          reason: '$query',
        );
      }
      expect((await call('GET', query: {'limit': '1'})).status, 400);
      await db.execute('DROP TRIGGER persona_history_no_update');
      await db.execute(
        'UPDATE persona_history SET encrypted_reason=? WHERE version=2',
        ['damaged'],
      );
      final first = json(
        await call('GET', suffix: '/history', query: {'limit': '1'}),
      );
      expect(changes(first).map((c) => c['version']), [1]);
      expect(first['nextAfterVersion'], 1);
      final damaged = await call(
        'GET',
        suffix: '/history',
        query: {'afterVersion': '1'},
      );
      expect(damaged.status, 500);
      expect(damaged.json, {'error': 'internal'});
    },
  );

  test(
    'history rejects other owners admin stale identity transferred and disabled AI',
    () async {
      await initialize();
      for (final actor in ['other', 'admin']) {
        expect(
          (await call('GET', suffix: '/history', actor: actor)).status,
          404,
        );
      }
      expect(
        (await call('GET', suffix: '/history', anonymous: true)).status,
        401,
      );
      final principal = (await accounts.authenticate(
        tokens['owner']!.accessToken,
      ))!;
      final spoofed = Pipeline(
        router: router,
        authenticate: (_) async => principal,
      );
      expect(
        (await call(
          'GET',
          suffix: '/history',
          actor: 'other',
          through: spoofed,
        )).status,
        401,
      );
      await accounts.refresh(tokens['owner']!.refreshToken);
      expect((await call('GET', suffix: '/history')).status, 401);
      tokens['owner'] = (await accounts.login(
        ids['owner']!,
        password,
        deviceName: 'new',
      )).value;
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', [
        aiAccount.value,
      ]);
      expect((await call('GET', suffix: '/history')).status, 404);
      await db.execute('UPDATE account SET disabled=0 WHERE id=?', [
        aiAccount.value,
      ]);
      await db.execute('UPDATE ai_operator SET operator_id=? WHERE ai_id=?', [
        ids['other']!.value,
        aiAccount.value,
      ]);
      expect((await call('GET', suffix: '/history')).status, 404);
      expect(
        (await call('GET', suffix: '/history', actor: 'other')).status,
        404,
      );
    },
  );

  test(
    'new routes reject mismatched devices revoked sessions and cross-profile targets',
    () async {
      await initialize();
      await editStyle(1, 'brief');
      final change = (await db.query(
        'SELECT id FROM persona_history WHERE version=2',
      )).single['id'];
      final body = {
        'changeId': change,
        'expectedVersion': 2,
        'reason': 'Restore',
      };
      final principal = (await accounts.authenticate(
        tokens['owner']!.accessToken,
      ))!;
      final wrongDevice = Pipeline(
        router: router,
        authenticate: (_) async =>
            Principal(accountId: principal.accountId, deviceId: 'wrong'),
      );
      Future<void> rejected(
        int status, {
        Pipeline? through,
        String? bearer,
        String? profile,
      }) async {
        expect(
          (await call(
            'GET',
            suffix: '/history',
            through: through,
            bearer: bearer,
            profile: profile,
          )).status,
          status,
        );
        expect(
          (await call(
            'POST',
            suffix: '/revert',
            body: body,
            through: through,
            bearer: bearer,
            profile: profile,
          )).status,
          status,
        );
      }

      await rejected(401, through: wrongDevice);
      await rejected(404, profile: aiAccount.value);
      expect(
        (await call(
          'POST',
          suffix: '/revert',
          body: body,
          query: {'limit': '1'},
        )).status,
        400,
      );
      final ownerScope = (await accounts.scope(
        tokens['owner']!.accessToken,
      )).value;
      final siblingAccount = (await ownerScope.accounts.createAi(
        operator: ids['owner']!,
        displayName: 'Sibling',
      )).value;
      final sibling = (await AiIdentityResolver.forOwner(
        ownerId: ids['owner']!.value,
        db: db,
      ).register(siblingAccount)).value.profileId;
      expect(
        (await call(
          'POST',
          profile: sibling.value,
          suffix: '/initialize',
          body: initial(),
        )).status,
        200,
      );
      expect(
        (await call(
          'POST',
          profile: sibling.value,
          suffix: '/revert',
          body: {...body, 'expectedVersion': 1},
        )).status,
        404,
      );
      await ownerScope.devices.revoke(ids['owner']!, tokens['owner']!.deviceId);
      await rejected(401);
      tokens['owner'] = (await accounts.login(
        ids['owner']!,
        password,
        deviceName: 'fresh',
      )).value;
      clock.advance(const Duration(hours: 1));
      await rejected(401);
      expect(
        await db.query('SELECT * FROM persona_history WHERE ai_profile_id=?', [
          ai.value,
        ]),
        hasLength(2),
      );
    },
  );

  test(
    'revert restores selected before snapshot undoes later edits and retains current lock',
    () async {
      await initialize();
      await editStyle(1, 'brief');
      await editStyle(2, 'playful');
      expect(
        (await call(
          'PUT',
          suffix: '/lock',
          body: {'expectedVersion': 3, 'locked': true},
        )).status,
        200,
      );
      final original = await db.query(
        'SELECT * FROM persona_history ORDER BY version',
      );
      final changeId = original[1]['id'] as String;
      final reverted = json(
        await call(
          'POST',
          suffix: '/revert',
          body: {
            'changeId': changeId,
            'expectedVersion': 4,
            'reason': 'Restore original style',
          },
        ),
      );
      expect(reverted['version'], 5);
      expect(reverted['locked'], true);
      expect(reverted['layers'], initial());
      expect(
        (await db.query(
          'SELECT * FROM persona_history ORDER BY version',
        )).take(4).toList(),
        original,
      );
      final history = changes(json(await call('GET', suffix: '/history')));
      expect(history.last['kind'], 'revert');
      expect(history.last['revertsChangeId'], changeId);
      expect(history.last['reason'], 'Restore original style');
      expect(history.last['version'], 5);
      await db.close();
      await open();
      expect(json(await call('GET')), reverted);
      expect(
        (await call(
          'POST',
          suffix: '/revert',
          body: {
            'changeId': changeId,
            'expectedVersion': 5,
            'reason': 'Already restored',
          },
        )).status,
        409,
      );
    },
  );

  test(
    'revert input authorization non-content and stale targets never append changes',
    () async {
      await initialize();
      await editStyle(1, 'brief');
      expect(
        (await call(
          'PUT',
          suffix: '/lock',
          body: {'expectedVersion': 2, 'locked': true},
        )).status,
        200,
      );
      final records = await db.query(
        'SELECT id FROM persona_history ORDER BY version',
      );
      final valid = <String, Object?>{
        'changeId': records[1]['id'],
        'expectedVersion': 3,
        'reason': 'Restore',
      };
      for (final body in <Object?>[
        {},
        {...valid, 'expectedVersion': 3.0},
        {...valid, 'expectedVersion': 0},
        {...valid, 'reason': ''},
        {...valid, 'changeId': 'bad id'},
        {...valid, 'changeId': 7},
        {...valid, 'actorId': ids['owner']!.value},
        {...valid, 'ownerId': ids['owner']!.value},
        {...valid, 'reason': 'x' * ((1 << 20) + 1)},
        {...valid, 'changeId': records.first['id']},
        {...valid, 'changeId': records.last['id']},
      ]) {
        expect((await call('POST', suffix: '/revert', body: body)).status, 400);
      }
      expect(
        (await call(
          'POST',
          suffix: '/revert',
          body: {...valid, 'expectedVersion': 2},
        )).status,
        409,
      );
      expect(
        (await call(
          'POST',
          suffix: '/revert',
          body: {...valid, 'changeId': 'unknown'},
        )).status,
        404,
      );
      for (final actor in ['other', 'admin']) {
        expect(
          (await call(
            'POST',
            suffix: '/revert',
            body: valid,
            actor: actor,
          )).status,
          404,
        );
      }
      expect(
        (await call(
          'POST',
          suffix: '/revert',
          body: valid,
          anonymous: true,
        )).status,
        401,
      );
      expect(json(await call('GET'))['version'], 3);
      expect(
        await db.query('SELECT id FROM persona_history ORDER BY version'),
        records,
      );
    },
  );

  test(
    'concurrent revert and edit accept exactly one expected version',
    () async {
      await initialize();
      await editStyle(1, 'brief');
      final target = (await db.query(
        'SELECT id FROM persona_history WHERE version=2',
      )).single['id'];
      final responses = await Future.wait([
        call(
          'POST',
          suffix: '/revert',
          body: {'changeId': target, 'expectedVersion': 2, 'reason': 'Restore'},
        ),
        call(
          'PATCH',
          body: {
            'expectedVersion': 2,
            'reason': 'New edit',
            'diff': {
              'p1': {'style': 'new'},
            },
          },
        ),
      ]);
      expect(responses.map((r) => r.status).toList()..sort(), [200, 409]);
      expect(json(await call('GET'))['version'], 3);
      expect(await db.query('SELECT * FROM persona_history'), hasLength(3));
    },
  );

  test(
    'corrupt revert target fails safely without mutating current card',
    () async {
      await initialize();
      await editStyle(1, 'brief');
      final target = (await db.query(
        'SELECT id FROM persona_history WHERE version=2',
      )).single['id'];
      await db.execute('DROP TRIGGER persona_history_no_update');
      await db.execute(
        'UPDATE persona_history SET encrypted_before=? WHERE version=2',
        ['damaged'],
      );
      final response = await call(
        'POST',
        suffix: '/revert',
        body: {'changeId': target, 'expectedVersion': 2, 'reason': 'Restore'},
      );
      expect(response.status, 500);
      expect(response.json, {'error': 'internal'});
      expect(json(await call('GET'))['version'], 2);
      expect(await db.query('SELECT * FROM persona_history'), hasLength(2));
    },
  );

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
