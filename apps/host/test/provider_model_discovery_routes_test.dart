import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/audit/audit_log.dart';
import 'package:jingyu_host/src/models/models_migrations.dart';
import 'package:jingyu_host/src/models/models_module.dart';
import 'package:jingyu_host/src/models/openai_chat_adapter.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/security/guarded_http.dart';
import 'package:jingyu_host/src/security/url_guard.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_audit_log.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

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
  late AesGcmColumnCipher cipher;
  late AccountsDomain accounts;
  late Pipeline pipeline;
  late AccountId owner;
  late AccountId other;
  late String token;
  late String otherToken;
  late AuditLog audit;
  late List<Map<String, Object?>> calls;
  const passwordValue = 'test-long-passphrase';
  const secret = 'sk-route-fixture-secret';

  GuardedChatRequest respond(Object? payload, {int statusCode = 200}) =>
      (
        String method,
        Uri uri, {
        Map<String, String> headers = const {},
        List<int>? body,
      }) async {
        calls.add({'method': method, 'uri': uri, 'headers': headers});
        return Ok(
          GuardedResponse(
            statusCode: statusCode,
            headers: const {},
            body: utf8.encode(
              payload is String ? payload : jsonEncode(payload),
            ),
          ),
        );
      };

  Future<String> saveProvider({String? ownerId, bool enabled = true}) async {
    final view =
        (await ProviderRegistry.forOwner(
              ownerId: ownerId ?? owner.value,
              db: db,
              cipher: cipher,
              urlGuard: UrlGuard(
                resolver: (_) async => [InternetAddress('8.8.8.8')],
              ),
              clock: const SystemClock(),
            ).create(
              name: 'Fixture',
              baseUrl: 'https://models.example/v1',
              apiKey: secret,
              enabled: enabled,
              capabilities: const {ProviderCapability.chat},
            ))
            .value;
    return view.id;
  }

  String path(String providerId) =>
      Routes.modelProviderModels.replaceFirst('{providerId}', providerId);

  Future<HostResponse> call(
    String method,
    String endpoint, {
    Object? body,
    String? bearer,
    Map<String, String>? headers,
    Map<String, String> query = const {},
  }) => pipeline.handle(
    HostRequest(
      method: method,
      path: endpoint,
      query: query,
      body: body,
      headers: {
        if (bearer != null) 'authorization': 'Bearer $bearer',
        ...?headers,
      },
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'provider-discovery-routes-',
    );
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...modelsMigrations,
      ],
    );
    cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
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
    audit = SqliteAuditLog(db);
    calls = [];
  });

  tearDown(() async {
    cipher.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<void> build({
    GuardedChatRequest? request,
    bool withAccounts = true,
  }) async {
    final module = ModelsModule(
      db: db,
      cipher: cipher,
      urlGuard: UrlGuard(resolver: (_) async => [InternetAddress('8.8.8.8')]),
      clock: const SystemClock(),
      providerDiscoveryRequest: request,
    );
    final services = HostServices()..provide<AuditLog>(audit, owner: 'system');
    if (withAccounts) {
      services.provide<AccountsDomain>(accounts, owner: 'accounts');
    }
    await module.configure(services);
    final router = Router();
    module.mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: withAccounts
          ? DbAuthenticator(accounts).call
          : (_) async => null,
    );
  }

  test('returns normalized safe ids and records metadata-only audit', () async {
    final providerId = await saveProvider();
    await build(
      request: respond({
        'data': [
          {'id': 'model-a', 'private_metadata': 'do-not-forward'},
          {'id': 'model-b'},
        ],
        'private_owner': 'do-not-forward',
      }),
    );

    final response = await call('GET', path(providerId), bearer: token);
    expect(response.status, 200);
    expect(response.json, {
      'models': [
        {'id': 'model-a'},
        {'id': 'model-b'},
      ],
    });
    expect(jsonEncode(response.json), isNot(contains('do-not-forward')));
    expect(jsonEncode(response.json), isNot(contains(secret)));
    expect(calls.single['uri'].toString(), 'https://models.example/v1/models');
    final entries = await db.query('SELECT * FROM audit_log ORDER BY id');
    expect(entries, hasLength(1));
    expect(entries.single['action'], 'provider.models');
    expect(entries.single['target_id'], providerId);
    expect(jsonEncode(entries.single), isNot(contains(secret)));
    expect(jsonEncode(entries.single), isNot(contains('model-a')));
  });

  test('requires live authentication and owner for saved provider', () async {
    final providerId = await saveProvider();
    await build(request: respond({'data': []}));

    expect((await call('GET', path(providerId))).status, 401);
    expect(
      (await call('GET', path(providerId), bearer: otherToken)).status,
      404,
    );
    expect(
      (await call(
        'GET',
        path(providerId),
        bearer: token,
        headers: {'transfer-encoding': 'chunked'},
      )).status,
      400,
    );
    expect(
      (await call('GET', path(providerId), bearer: token, body: {})).status,
      400,
    );
    expect(
      (await call(
        'GET',
        path(providerId),
        bearer: token,
        query: {'ownerId': other.value},
      )).status,
      400,
    );
    expect(calls, isEmpty);
  });

  test(
    'rejects malformed provider ids and denies cross owner without request',
    () async {
      await build(request: respond({'data': []}));
      for (final id in ['bad%2Fid', '%20', 'x' * 65]) {
        expect((await call('GET', path(id), bearer: token)).status, 400);
      }
      expect(calls, isEmpty);
    },
  );

  test(
    'revoked token, disabled provider, and missing transport are safe',
    () async {
      final providerId = await saveProvider();
      final disabledId = await saveProvider(enabled: false);
      final login = (await accounts.login(
        owner,
        passwordValue,
        deviceName: 'owner-2',
      )).value;
      final session = (await accounts.scope(login.accessToken)).value;
      await session.devices.revoke(owner, login.deviceId);

      await build(request: respond({'data': []}));
      expect(
        (await call('GET', path(providerId), bearer: login.accessToken)).status,
        401,
      );
      expect((await call('GET', path(disabledId), bearer: token)).status, 503);
      expect(calls, isEmpty);
    },
  );

  test(
    'fails safely before request when discovery transport is not configured',
    () async {
      final providerId = await saveProvider();
      await build(request: null);
      final response = await call('GET', path(providerId), bearer: token);
      expect(response.status, 503);
      expect(response.json, {'error': 'model_unavailable'});
      expect(calls, isEmpty);
      expect(await db.query('SELECT * FROM audit_log'), isEmpty);
    },
  );

  test(
    'admin has no foreign-owner bypass and missing providers reveal nothing',
    () async {
      final foreignId = await saveProvider(ownerId: other.value);
      await build(request: respond({'data': []}));
      expect((await call('GET', path(foreignId), bearer: token)).status, 404);
      expect((await call('GET', path('missing'), bearer: token)).status, 404);
      expect(calls, isEmpty);
      expect(await db.query('SELECT * FROM audit_log'), isEmpty);
    },
  );

  test(
    'cached principal device mismatch and disabled bearer deny before request',
    () async {
      final providerId = await saveProvider(ownerId: other.value);
      await build(request: respond({'data': []}));
      final current = await accounts.authenticate(otherToken);
      final cached = Pipeline(
        router: pipeline.router,
        authenticate: (_) async =>
            Principal(accountId: other.value, deviceId: 'wrong-device'),
      );
      final mismatch = await cached.handle(
        HostRequest(
          method: 'GET',
          path: path(providerId),
          headers: {'authorization': 'Bearer $otherToken'},
        ),
      );
      expect(current, isNotNull);
      expect(mismatch.status, 401);
      final admin = (await accounts.scope(token)).value;
      expect((await admin.accounts.disable(other)).isOk, isTrue);
      expect(
        (await call('GET', path(providerId), bearer: otherToken)).status,
        401,
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'normalizes upstream failure status with no raw body or credential leak',
    () async {
      final providerId = await saveProvider();
      await build(
        request: respond('private upstream echo $secret', statusCode: 500),
      );
      final response = await call('GET', path(providerId), bearer: token);
      expect(response.status, 503);
      final encoded = jsonEncode(response.json);
      expect(encoded, isNot(contains(secret)));
      expect(encoded, isNot(contains('private upstream echo')));
      expect(await db.query('SELECT * FROM audit_log'), isEmpty);
    },
  );
}
