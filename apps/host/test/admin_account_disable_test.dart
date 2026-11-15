import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_module.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/device_service.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/http_server.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

class _FastHasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String password) async =>
      'fixture:${sha256.convert(utf8.encode(password))}';

  @override
  Future<bool> verifyAsync(String password, String hash) async =>
      hash == 'fixture:${sha256.convert(utf8.encode(password))}';
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AccountsDomain domain;
  late FakeClock clock;
  late Router router;
  late Pipeline pipeline;
  late Map<String, AccountId> ids;
  late Map<String, DeviceTokens> tokens;
  const password = 'disable-route-password';

  Future<void> open() async {
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...accountsMigrations],
    );
    domain = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    router = Router();
    AccountsModule(domain: domain).mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(domain).call,
    );
  }

  Future<HostResponse> disable({
    String? actor = 'admin',
    String? target,
    Object? body,
    String? bearer,
    Pipeline? through,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: 'POST',
      path: '/api/v1/admin/accounts/${target ?? ids['victim']!.value}/disable',
      headers: {
        if (actor != null || bearer != null)
          'authorization': 'Bearer ${bearer ?? tokens[actor]!.accessToken}',
      },
      body: body,
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('admin-disable-http-');
    clock = FakeClock(DateTime.utc(2026, 11, 15));
    await open();
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
    final admin = (await domain.scope(tokens['admin']!.accessToken)).value;
    for (final name in ['victim', 'other']) {
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
    final victim = (await domain.scope(tokens['victim']!.accessToken)).value;
    ids['ai'] = (await victim.accounts.createAi(
      operator: ids['victim']!,
      displayName: 'Owned AI',
    )).value;
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'HTTP disable invalidates all target sessions and persists without touching other accounts',
    () async {
      final second = (await domain.login(
        ids['victim']!,
        password,
        deviceName: 'victim second',
      )).value;
      final held = (await domain.scope(tokens['victim']!.accessToken)).value;
      final response = await disable();
      expect(response.status, 200);
      expect(response.json, {'disabled': true});
      expect(
        (await db.query('SELECT disabled FROM account WHERE id = ?', [
          ids['victim']!.value,
        ])).single['disabled'],
        1,
      );
      for (final device in [tokens['victim']!, second]) {
        expect(await domain.authenticate(device.accessToken), isNull);
        expect((await domain.refresh(device.refreshToken)).isErr, isTrue);
      }
      expect((await held.ownAiMetadata()).isErr, isTrue);
      expect(
        (await domain.login(
          ids['victim']!,
          password,
          deviceName: 'disabled',
        )).isErr,
        isTrue,
      );
      expect(
        await domain.authenticate(tokens['admin']!.accessToken),
        isNotNull,
      );
      expect(
        await domain.authenticate(tokens['other']!.accessToken),
        isNotNull,
      );
      expect(response.encodeBody(), isNot(contains(password)));
      await db.close();
      await open();
      expect(
        (await domain.login(
          ids['victim']!,
          password,
          deviceName: 'restart',
        )).isErr,
        isTrue,
      );
      expect(await domain.authenticate(tokens['victim']!.accessToken), isNull);
      expect((await domain.refresh(second.refreshToken)).isErr, isTrue);
    },
  );

  test('admin can disable AI without changing its human operator', () async {
    final before = (await db.query(
      'SELECT operator_id FROM ai_operator WHERE ai_id = ?',
      [ids['ai']!.value],
    )).single['operator_id'];
    expect((await disable(target: ids['ai']!.value)).status, 200);
    expect(
      (await db.query('SELECT disabled FROM account WHERE id = ?', [
        ids['ai']!.value,
      ])).single['disabled'],
      1,
    );
    expect(
      (await db.query('SELECT operator_id FROM ai_operator WHERE ai_id = ?', [
        ids['ai']!.value,
      ])).single['operator_id'],
      before,
    );
    expect(await domain.authenticate(tokens['victim']!.accessToken), isNotNull);
  });

  test(
    'anonymous and ordinary users cannot disable through admin HTTP',
    () async {
      final before = jsonEncode((await domain.store.snapshot()).toJson());
      expect((await disable(actor: null)).status, 401);
      expect((await disable(actor: 'victim')).status, 403);
      expect(
        (await disable(actor: 'victim', target: ids['ai']!.value)).status,
        403,
      );
      expect(jsonEncode((await domain.store.snapshot()).toJson()), before);
    },
  );

  test('bodies and malformed IDs are rejected without writes', () async {
    final before = jsonEncode((await domain.store.snapshot()).toJson());
    for (final body in <Object?>[
      {},
      [],
      'yes',
      1,
      {'disabled': true},
      {'actorId': ids['admin']!.value},
    ]) {
      expect((await disable(body: body)).status, 400);
    }
    expect((await disable(target: 'bad id')).status, 400);
    expect(jsonEncode((await domain.store.snapshot()).toJson()), before);
  });

  test(
    'unknown target is hidden and sole administrator is protected',
    () async {
      expect((await disable(target: 'missing-account')).status, 404);
      expect((await disable(target: ids['admin']!.value)).status, 409);
      expect(
        await domain.authenticate(tokens['admin']!.accessToken),
        isNotNull,
      );
    },
  );

  test(
    'real HTTP rejects JSON null entities before mutating the target',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serving = serve(server, pipeline);
      final client = HttpClient();
      final path = '/api/v1/admin/accounts/${ids['victim']!.value}/disable';
      try {
        for (final chunked in [false, true]) {
          final request = await client.post('127.0.0.1', server.port, path);
          request.headers.set(
            'authorization',
            'Bearer ${tokens['admin']!.accessToken}',
          );
          request.headers.contentType = ContentType.json;
          if (!chunked) request.contentLength = 4;
          request.write('null');
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, 400);
          expect(
            (await db.query('SELECT disabled FROM account WHERE id = ?', [
              ids['victim']!.value,
            ])).single['disabled'],
            0,
          );
        }
        final empty = await client.post('127.0.0.1', server.port, path);
        empty.contentLength = 0;
        empty.headers.set(
          'authorization',
          'Bearer ${tokens['admin']!.accessToken}',
        );
        final response = await empty.close();
        await response.drain<void>();
        expect(response.statusCode, 200);
      } finally {
        client.close(force: true);
        await server.close(force: true);
        await serving;
      }
    },
  );

  test('repeated disable is idempotent', () async {
    expect((await disable()).status, 200);
    expect((await disable()).status, 200);
    expect(
      (await db.query('SELECT disabled FROM account WHERE id = ?', [
        ids['victim']!.value,
      ])).single['disabled'],
      1,
    );
  });

  test('revoked rotated and expired admin bearers cannot disable', () async {
    final fresh = (await domain.refresh(tokens['admin']!.refreshToken)).value;
    expect((await disable()).status, 401);
    final session = (await domain.scope(fresh.accessToken)).value;
    await session.devices.revoke(ids['admin']!, fresh.deviceId);
    expect((await disable(bearer: fresh.accessToken)).status, 401);
    final login = (await domain.login(
      ids['admin']!,
      password,
      deviceName: 'new-admin',
    )).value;
    clock.advance(const Duration(days: 366));
    expect((await disable(bearer: login.accessToken)).status, 401);
    expect(
      (await db.query('SELECT disabled FROM account WHERE id = ?', [
        ids['victim']!.value,
      ])).single['disabled'],
      0,
    );
  });

  test(
    'cached admin identity cannot authorize another bearer or device',
    () async {
      final admin = (await domain.authenticate(tokens['admin']!.accessToken))!;
      final spoofed = Pipeline(
        router: router,
        authenticate: (_) async => admin,
      );
      expect((await disable(actor: 'victim', through: spoofed)).status, 401);
      final wrongDevice = Pipeline(
        router: router,
        authenticate: (_) async => Principal(
          accountId: admin.accountId,
          deviceId: 'other-device',
          isAdmin: true,
        ),
      );
      expect((await disable(through: wrongDevice)).status, 401);
      expect(
        (await db.query('SELECT disabled FROM account WHERE id = ?', [
          ids['victim']!.value,
        ])).single['disabled'],
        0,
      );
    },
  );
}
