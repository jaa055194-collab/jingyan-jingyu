import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/ai_routes.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

// Only replace costly password derivation; accounts, sessions and SQL stay real.
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
  late AccountsDomain domain;
  late Router router;
  late Pipeline pipeline;
  late AccountId owner;
  late AccountId other;
  late AccountId ai;
  late String token;
  late String otherToken;
  const password = 'route-fixture-password';
  const register = '/api/v1/ai-profiles/register';

  Future<HostResponse> call(
    String method,
    String path, {
    Object? body,
    String? bearer,
  }) => pipeline.handle(
    HostRequest(
      method: method,
      path: path,
      body: body,
      headers: {'authorization': 'Bearer ${bearer ?? token}'},
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ai-routes-');
    db = await SqliteDatabase.open(
      '${directory.path}/routes.sqlite',
      migrations: [...allMigrations],
    );
    domain = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: SystemClock(),
      hasher: _FastHasher(),
    );
    owner = (await domain.bootstrapAdmin(
      displayName: 'Owner',
      password: password,
    )).value;
    token = (await domain.login(
      owner,
      password,
      deviceName: 'Owner device',
    )).value.accessToken;
    final session = (await domain.scope(token)).value;
    other = (await session.accounts.createHuman(
      displayName: 'Other',
      password: password,
    )).value;
    otherToken = (await domain.login(
      other,
      password,
      deviceName: 'Other device',
    )).value.accessToken;
    ai = (await session.accounts.createAi(
      operator: owner,
      displayName: 'AI',
    )).value;
    await db.transaction((tx) => tx.execute(aiIdentityMigration.sql));
    router = Router();
    mountAiRoutes(router, accounts: domain, db: db);
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(domain).call,
    );
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'register existing AI returns only safe identities and is idempotent',
    () async {
      final first = await call('POST', register, body: {'accountId': ai.value});
      expect(first.status, 200);
      final json = first.json as Map;
      expect(
        json.keys,
        unorderedEquals(['profileId', 'accountId', 'ownerAccountId']),
      );
      expect(json['accountId'], ai.value);
      expect(json['ownerAccountId'], owner.value);
      expect(json['profileId'], isNot(ai.value));
      expect(
        (await call('POST', register, body: {'accountId': ai.value})).json,
        json,
      );
      expect(
        (await call('GET', '/api/v1/ai-profiles/${json['profileId']}')).json,
        json,
      );
      expect(await db.query('SELECT id FROM ai_profile'), hasLength(1));
    },
  );

  test(
    'rejects malformed input and owner spoofing without mutations',
    () async {
      for (final body in <Object?>[
        null,
        [],
        {},
        {'accountId': 7},
        {'accountId': ''},
        {'accountId': ai.value, 'ownerAccountId': owner.value},
        {'accountId': ai.value, 'displayName': 'unexpected'},
      ]) {
        expect((await call('POST', register, body: body)).status, 400);
      }
      expect((await call('GET', '/api/v1/ai-profiles/%20')).status, 400);
      expect(await db.query('SELECT id FROM ai_profile'), isEmpty);
    },
  );

  test('another owner and admin cannot access somebody else AI', () async {
    final otherSession = (await domain.scope(otherToken)).value;
    final otherAi = (await otherSession.accounts.createAi(
      operator: other,
      displayName: 'Other AI',
    )).value;
    final identity = (await AiIdentityResolver.forOwner(
      ownerId: other.value,
      db: db,
    ).register(otherAi)).value;
    expect(
      (await call('POST', register, body: {'accountId': otherAi.value})).status,
      404,
    );
    expect(
      (await call(
        'GET',
        '/api/v1/ai-profiles/${identity.profileId.value}',
      )).status,
      404,
    );
    expect(
      (await call(
        'POST',
        register,
        bearer: otherToken,
        body: {'accountId': ai.value},
      )).status,
      404,
    );
    for (final id in [owner.value, 'missing']) {
      expect(
        (await call('POST', register, body: {'accountId': id})).status,
        404,
      );
    }
  });

  test(
    'resolve does not register and rechecks disabled AI and ownership',
    () async {
      expect(
        (await call('GET', '/api/v1/ai-profiles/${ai.value}')).status,
        404,
      );
      expect(await db.query('SELECT id FROM ai_profile'), isEmpty);
      final created = await call(
        'POST',
        register,
        body: {'accountId': ai.value},
      );
      final id = (created.json as Map)['profileId'];
      await db.execute('UPDATE account SET disabled = 1 WHERE id = ?', [
        ai.value,
      ]);
      expect((await call('GET', '/api/v1/ai-profiles/$id')).status, 404);
      expect(
        (await call('POST', register, body: {'accountId': ai.value})).status,
        404,
      );
      await db.execute('UPDATE account SET disabled = 0 WHERE id = ?', [
        ai.value,
      ]);
      await db.execute(
        'UPDATE ai_operator SET operator_id = ? WHERE ai_id = ?',
        [other.value, ai.value],
      );
      expect((await call('GET', '/api/v1/ai-profiles/$id')).status, 404);
      expect(
        (await call(
          'GET',
          '/api/v1/ai-profiles/$id',
          bearer: otherToken,
        )).status,
        200,
      );
    },
  );

  test(
    'scope revalidates bearer even after middleware authenticated principal',
    () async {
      final principal = (await domain.authenticate(token))!;
      final devices = await (await domain.scope(
        token,
      )).value.devices.list(owner);
      await (await domain.scope(
        token,
      )).value.devices.revoke(owner, devices.single.id);
      // Simulate authentication completed before a concurrent device revocation.
      pipeline = Pipeline(router: router, authenticate: (_) async => principal);
      expect(
        (await call('POST', register, body: {'accountId': ai.value})).status,
        401,
      );
      expect((await call('GET', '/api/v1/ai-profiles/missing')).status, 401);
      expect(
        (await call(
          'POST',
          register,
          bearer: '',
          body: {'accountId': ai.value},
        )).status,
        401,
      );
      expect(await db.query('SELECT id FROM ai_profile'), isEmpty);
    },
  );

  test('no create route can leave an unregistered AI account', () async {
    final before = await db.query('SELECT id FROM account');
    expect(
      (await call(
        'POST',
        '/api/v1/ai-profiles',
        body: {'displayName': 'New AI'},
      )).status,
      404,
    );
    expect(await db.query('SELECT id FROM account'), before);
  });
}
