import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/audit/audit_log.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/binding_matrix.dart';
import 'package:jingyu_host/src/models/binding_migrations.dart';
import 'package:jingyu_host/src/models/config_routes.dart';
import 'package:jingyu_host/src/models/models_migrations.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

// Keep session/account persistence real, replacing only expensive derivation.
class _FastHasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String value) async => 'fixture:$value';
  @override
  Future<bool> verifyAsync(String value, String encodedHash) async =>
      encodedHash == 'fixture:$value';
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AccountsDomain accounts;
  late InMemoryAuditLog audit;
  late Router router;
  late Pipeline pipeline;
  late AccountId owner;
  late AccountId other;
  late AccountId aiAccount;
  late AiId ai;
  late AiId otherAi;
  late String token;
  late String otherToken;
  const path = '/api/v1/ai-profiles';
  const passwordValue = 'test-long-passphrase';
  const validBody = {'providerId': 'provider', 'model': 'main-model'};

  Future<HostResponse> call(
    String method,
    String endpoint, {
    Object? body,
    String? bearer,
  }) => pipeline.handle(
    HostRequest(
      method: method,
      path: endpoint,
      body: body,
      headers: {'authorization': 'Bearer ${bearer ?? token}'},
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('config-routes-');
    db = await SqliteDatabase.open(
      '${directory.path}/config.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...modelsMigrations,
        aiIdentityMigration,
        bindingMigration,
      ],
    );
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: const SystemClock(),
      hasher: _FastHasher(),
    );
    owner = (await accounts.bootstrapAdmin(
      displayName: 'Owner',
      password: passwordValue,
    )).value;
    token = (await accounts.login(
      owner,
      passwordValue,
      deviceName: 'owner',
    )).value.accessToken;
    final session = (await accounts.scope(token)).value;
    other = (await session.accounts.createHuman(
      displayName: 'Other',
      password: passwordValue,
    )).value;
    otherToken = (await accounts.login(
      other,
      passwordValue,
      deviceName: 'other',
    )).value.accessToken;
    aiAccount = (await session.accounts.createAi(
      operator: owner,
      displayName: 'AI',
    )).value;
    ai = (await AiIdentityResolver.forOwner(
      ownerId: owner.value,
      db: db,
    ).register(aiAccount)).value.profileId;
    final otherSession = (await accounts.scope(otherToken)).value;
    final foreignAccount = (await otherSession.accounts.createAi(
      operator: other,
      displayName: 'Other AI',
    )).value;
    otherAi = (await AiIdentityResolver.forOwner(
      ownerId: other.value,
      db: db,
    ).register(foreignAccount)).value.profileId;
    for (final entry in [
      (owner.value, 'provider'),
      (other.value, 'foreign-provider'),
    ]) {
      await db.execute(
        'INSERT INTO providers (owner_id,id,name,base_url,encrypted_key,key_mask,enabled,capabilities) '
        "VALUES (?, ?, 'fixture', 'https://models.example/v1', 'private-ciphertext', '****1234', 1, ?)",
        [entry.$1, entry.$2, '["chat","chatFast","tts"]'],
      );
    }
    audit = InMemoryAuditLog();
    router = Router();
    mountModelConfigRoutes(
      router,
      db: db,
      clock: const SystemClock(),
      accounts: accounts,
      audit: audit,
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
    'PUT and GET persist independent bindings and return safe fields',
    () async {
      expect((await call('GET', '$path/${ai.value}/bindings')).json, []);
      final response = await call(
        'PUT',
        '$path/${ai.value}/bindings/chat',
        body: validBody,
      );
      expect(response.status, 200);
      expect(response.json, {
        'owner_id': owner.value,
        'ai_profile_id': ai.value,
        'capability': 'chat',
        'provider_id': 'provider',
        'model': 'main-model',
      });
      expect(
        (await call(
          'PUT',
          '$path/${ai.value}/bindings/chatFast',
          body: {'providerId': 'provider', 'model': 'fast-model'},
        )).status,
        200,
      );
      final list = await call('GET', '$path/${ai.value}/bindings');
      expect(list.status, 200);
      expect((list.json as List).map((b) => (b as Map)['model']), [
        'main-model',
        'fast-model',
      ]);
      expect(jsonEncode(list.json), isNot(contains('key')));
      expect(jsonEncode(list.json), isNot(contains('private-ciphertext')));
      expect(
        (await db.query(
          'SELECT model FROM model_bindings ORDER BY capability',
        )).map((r) => r['model']),
        ['main-model', 'fast-model'],
      );
      expect(audit.entries.map((e) => e.action), [
        'binding.set',
        'binding.set',
      ]);
      for (final entry in audit.entries) {
        expect(entry.actorId, owner.value);
        expect(entry.targetKind, 'model_binding');
        expect(entry.targetId, startsWith('${ai.value}:'));
        expect(entry.meta, isEmpty);
      }
    },
  );

  test(
    'rejects unknown fields, malformed types, ids and capabilities',
    () async {
      for (final body in <Object?>[
        null,
        [],
        {},
        {'providerId': 'provider'},
        {'model': 'm'},
        {'providerId': 7, 'model': 'm'},
        {'providerId': 'provider', 'model': false},
        {'providerId': '', 'model': 'm'},
        {'providerId': 'bad/id', 'model': 'm'},
        {'providerId': ' provider', 'model': 'm'},
        {'providerId': 'x' * 65, 'model': 'm'},
        {'providerId': 'provider', 'model': ''},
        {'providerId': 'provider', 'model': '  '},
        {'providerId': 'provider', 'model': 'bad\nmodel'},
        {...validBody, 'ownerId': other.value},
        {...validBody, 'apiKey': 'forbidden'},
      ]) {
        expect(
          (await call(
            'PUT',
            '$path/${ai.value}/bindings/chat',
            body: body,
          )).status,
          400,
          reason: '$body',
        );
      }
      for (final endpoint in [
        '$path/%20/bindings',
        '$path/bad%2Fid/bindings',
      ]) {
        expect((await call('GET', endpoint)).status, 400);
      }
      for (final capability in ['unknown', 'Chat', 'chat.fast', '%20']) {
        expect(
          (await call(
            'PUT',
            '$path/${ai.value}/bindings/$capability',
            body: validBody,
          )).status,
          400,
        );
        expect(
          (await call(
            'DELETE',
            '$path/${ai.value}/bindings/$capability',
          )).status,
          400,
        );
      }
      expect(await db.query('SELECT * FROM model_bindings'), isEmpty);
      expect(audit.entries, isEmpty);
    },
  );

  test('foreign AI and provider return 404 even for admin', () async {
    expect(
      (await call(
        'PUT',
        '$path/${ai.value}/bindings/chat',
        body: {'providerId': 'foreign-provider', 'model': 'm'},
      )).status,
      404,
    );
    for (final endpoint in [otherAi.value, 'missing']) {
      expect((await call('GET', '$path/$endpoint/bindings')).status, 404);
      expect(
        (await call(
          'PUT',
          '$path/$endpoint/bindings/chat',
          body: validBody,
        )).status,
        404,
      );
      expect(
        (await call('DELETE', '$path/$endpoint/bindings/chat')).status,
        404,
      );
    }
    expect(
      (await call(
        'GET',
        '$path/${ai.value}/bindings',
        bearer: otherToken,
      )).status,
      404,
    );
    expect(
      (await call(
        'PUT',
        '$path/${ai.value}/bindings/chat',
        body: validBody,
        bearer: otherToken,
      )).status,
      404,
    );
    expect(
      (await call(
        'DELETE',
        '$path/${ai.value}/bindings/chat',
        bearer: otherToken,
      )).status,
      404,
    );
    expect(await db.query('SELECT * FROM model_bindings'), isEmpty);
    expect(audit.entries, isEmpty);
  });

  test(
    'disabled provider leaves configuration readable and clear removes only binding',
    () async {
      await call('PUT', '$path/${ai.value}/bindings/chat', body: validBody);
      await db.execute('UPDATE providers SET enabled = 0 WHERE owner_id = ?', [
        owner.value,
      ]);
      final matrix = BindingMatrix.forOwner(owner.value, db);
      expect(
        (await matrix.resolve(ai, ProviderCapability.chat)).failureOrNull?.code,
        FailureCode.modelUnavailable,
      );
      final list = await call('GET', '$path/${ai.value}/bindings');
      expect(list.status, 200);
      expect((list.json as List).single, containsPair('model', 'main-model'));
      expect(
        (await call(
          'PUT',
          '$path/${ai.value}/bindings/chat',
          body: {...validBody, 'model': 'replacement'},
        )).status,
        503,
      );
      expect(
        (await matrix.get(ai, ProviderCapability.chat)).value.model,
        'main-model',
      );
      final providersBefore = await db.query('SELECT * FROM providers');
      expect(
        (await call('DELETE', '$path/${ai.value}/bindings/chat')).status,
        200,
      );
      expect(
        (await call('DELETE', '$path/${ai.value}/bindings/chat')).status,
        200,
      );
      expect((await call('GET', '$path/${ai.value}/bindings')).json, []);
      expect(await db.query('SELECT * FROM providers'), providersBefore);
      expect(audit.entries.map((e) => e.action), [
        'binding.set',
        'binding.clear',
        'binding.clear',
      ]);
      expect(audit.entries.last.meta, isEmpty);
    },
  );

  test(
    'AI disable and operator changes are rechecked for each request',
    () async {
      await call('PUT', '$path/${ai.value}/bindings/chat', body: validBody);
      await db.execute('UPDATE account SET disabled = 1 WHERE id = ?', [
        aiAccount.value,
      ]);
      expect((await call('GET', '$path/${ai.value}/bindings')).status, 404);
      expect(
        (await call('DELETE', '$path/${ai.value}/bindings/chat')).status,
        404,
      );
      await db.execute('UPDATE account SET disabled = 0 WHERE id = ?', [
        aiAccount.value,
      ]);
      await db.execute(
        'UPDATE ai_operator SET operator_id = ? WHERE ai_id = ?',
        [other.value, aiAccount.value],
      );
      expect((await call('GET', '$path/${ai.value}/bindings')).status, 404);
      expect(
        (await call(
          'PUT',
          '$path/${ai.value}/bindings/chat',
          body: validBody,
        )).status,
        404,
      );
      expect(await db.query('SELECT model FROM model_bindings'), [
        {'model': 'main-model'},
      ]);
    },
  );

  test('valid bearer must match principal account and device', () async {
    final ownerPrincipal = (await accounts.authenticate(token))!;
    final secondToken = (await accounts.login(
      owner,
      passwordValue,
      deviceName: 'second owner device',
    )).value.accessToken;
    pipeline = Pipeline(
      router: router,
      authenticate: (_) async => ownerPrincipal,
    );
    // Both tokens are live: one belongs to a different account, the other to a
    // different device of the same account. Neither authorizes this principal.
    for (final bearer in [otherToken, secondToken]) {
      expect(
        (await call(
          'GET',
          '$path/${ai.value}/bindings',
          bearer: bearer,
        )).status,
        401,
      );
      expect(
        (await call(
          'PUT',
          '$path/${ai.value}/bindings/chat',
          body: validBody,
          bearer: bearer,
        )).status,
        401,
      );
      expect(
        (await call(
          'DELETE',
          '$path/${ai.value}/bindings/chat',
          bearer: bearer,
        )).status,
        401,
      );
    }
    expect(await db.query('SELECT * FROM model_bindings'), isEmpty);
    expect(audit.entries, isEmpty);
  });

  test(
    'scope rejects revoked bearer despite stale authenticated principal',
    () async {
      final principal = (await accounts.authenticate(token))!;
      final session = (await accounts.scope(token)).value;
      final devices = await session.devices.list(owner);
      await session.devices.revoke(owner, devices.single.id);
      pipeline = Pipeline(router: router, authenticate: (_) async => principal);
      expect((await call('GET', '$path/${ai.value}/bindings')).status, 401);
      expect(
        (await call(
          'PUT',
          '$path/${ai.value}/bindings/chat',
          body: validBody,
        )).status,
        401,
      );
      expect(
        (await call('DELETE', '$path/${ai.value}/bindings/chat')).status,
        401,
      );
      expect(
        (await call('GET', '$path/${ai.value}/bindings', bearer: '')).status,
        401,
      );
      expect(await db.query('SELECT * FROM model_bindings'), isEmpty);
      expect(audit.entries, isEmpty);
    },
  );
}
