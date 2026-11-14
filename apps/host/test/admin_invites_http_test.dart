import 'dart:async';
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
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _GateHasher extends PasswordHasher {
  bool block = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<String> hashAsync(String value) async {
    if (block) {
      entered.complete();
      await release.future;
    }
    return 'fixture:${sha256.convert(utf8.encode(value))}';
  }

  @override
  Future<bool> verifyAsync(String value, String hash) async =>
      hash == 'fixture:${sha256.convert(utf8.encode(value))}';
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AccountsDomain domain;
  late FakeClock clock;
  late _GateHasher hasher;
  late Router router;
  late Pipeline pipeline;
  late AccountId adminId;
  late DeviceTokens admin;
  late DeviceTokens human;
  const password = 'invite-management-password';

  void mount({String path = Routes.adminInvites}) {
    router = Router();
    AccountsModule(domain: domain, adminInvitesPath: path).mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(domain).call,
    );
  }

  Future<void> open() async {
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...accountsMigrations],
    );
    domain = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: hasher,
    );
    mount();
  }

  Future<HostResponse> request(
    String method,
    String path, {
    String? bearer,
    bool anonymous = false,
    Object? body,
    Pipeline? through,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: method,
      path: path,
      body: body,
      headers: {
        if (!anonymous)
          'authorization': 'Bearer ${bearer ?? admin.accessToken}',
      },
      remoteAddress: '127.0.0.1',
    ),
  );

  Future<List<Map<String, Object?>>> list() async {
    final response = await request('GET', Routes.adminInvites);
    expect(response.status, 200);
    return (response.json as List).cast<Map<String, Object?>>();
  }

  Future<({String id, String code})> issue({
    int maxUses = 1,
    Duration lifetime = const Duration(hours: 1),
  }) async {
    // Setup uses existing domain metadata so tests of missing GET can fail with
    // a normal HTTP status rather than dereferencing an absent HTTP response.
    final session = (await domain.scope(admin.accessToken)).value;
    final before = (await session.inviteMetadata()).value
        .map((v) => v['id'])
        .toSet();
    final response = await request(
      'POST',
      Routes.adminInvites,
      body: {
        'expiresAt': clock.now().add(lifetime).toIso8601String(),
        'maxUses': maxUses,
      },
    );
    expect(response.status, 200);
    final code = (response.json as Map)['code'] as String;
    final id =
        (await session.inviteMetadata()).value.singleWhere(
              (v) => !before.contains(v['id']),
            )['id']
            as String;
    return (id: id, code: code);
  }

  String revokePath(String id) => '/api/v1/admin/invites/$id/revoke';

  Future<HostResponse> redeem(String code) => request(
    'POST',
    Routes.authInviteRedeem,
    anonymous: true,
    body: {'code': code, 'displayName': 'New human', 'password': password},
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('admin-invites-http-');
    clock = FakeClock(DateTime.utc(2026, 11, 15));
    hasher = _GateHasher();
    await open();
    adminId = (await domain.bootstrapAdmin(
      displayName: 'Admin',
      password: password,
    )).value;
    admin = (await domain.login(adminId, password, deviceName: 'admin')).value;
    final scoped = (await domain.scope(admin.accessToken)).value;
    final id = (await scoped.accounts.createHuman(
      displayName: 'Human',
      password: password,
    )).value;
    human = (await domain.login(id, password, deviceName: 'human')).value;
  });

  tearDown(() async {
    if (hasher.block && !hasher.release.isCompleted) hasher.release.complete();
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'GET exposes exactly safe metadata and never re-exposes invite code or digest',
    () async {
      expect(await list(), isEmpty);
      final invite = await issue(maxUses: 3);
      final rows = await list();
      expect(rows, hasLength(1));
      final entry = rows.single;
      expect(entry.keys.toSet(), {
        'id',
        'expiresAt',
        'maxUses',
        'usedCount',
        'revokedAt',
      });
      expect(entry['id'], invite.id);
      expect(
        entry['expiresAt'],
        clock.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
      expect(entry['maxUses'], 3);
      expect(entry['usedCount'], 0);
      expect(entry['revokedAt'], isNull);
      final digest =
          (await db.query('SELECT code_hash FROM invite WHERE id = ?', [
                invite.id,
              ])).single['code_hash']
              as String;
      expect(jsonEncode(rows), isNot(contains(invite.code)));
      expect(jsonEncode(rows), isNot(contains(digest)));
      expect(jsonEncode(rows), isNot(contains(admin.accessToken)));
    },
  );

  test(
    'HTTP revoke persists and prevents redemption without changing other invites',
    () async {
      final revoked = await issue(maxUses: 2);
      final unrelated = await issue();
      final accountsBefore = (await domain.store.snapshot()).accounts.length;
      final response = await request('POST', revokePath(revoked.id));
      expect(response.status, 200);
      expect(response.json, {'revoked': true});
      final metadata = (await list()).singleWhere((v) => v['id'] == revoked.id);
      expect(metadata['revokedAt'], clock.now().millisecondsSinceEpoch);
      expect(metadata['usedCount'], 0);
      expect((await redeem(revoked.code)).status, 404);
      expect((await domain.store.snapshot()).accounts.length, accountsBefore);
      await db.close();
      await open();
      expect((await redeem(revoked.code)).status, 404);
      expect(
        (await list()).singleWhere((v) => v['id'] == revoked.id)['revokedAt'],
        clock.now().millisecondsSinceEpoch,
      );
      expect((await redeem(unrelated.code)).status, 200);
    },
  );

  test(
    'list retains expired exhausted and revoked states with existing repeated revoke semantics',
    () async {
      final expired = await issue(lifetime: const Duration(seconds: 1));
      final exhausted = await issue();
      expect((await redeem(exhausted.code)).status, 200);
      clock.advance(const Duration(seconds: 2));
      expect((await request('POST', revokePath(expired.id))).status, 200);
      expect((await request('POST', revokePath(exhausted.id))).status, 200);
      final firstAt = clock.now().millisecondsSinceEpoch;
      clock.advance(const Duration(seconds: 3));
      expect((await request('POST', revokePath(expired.id))).status, 200);
      final rows = await list();
      expect(rows, hasLength(2));
      final expiredRow = rows.singleWhere((v) => v['id'] == expired.id);
      expect(expiredRow['revokedAt'], clock.now().millisecondsSinceEpoch);
      expect(expiredRow['revokedAt'], isNot(firstAt));
      final exhaustedRow = rows.singleWhere((v) => v['id'] == exhausted.id);
      expect(exhaustedRow['usedCount'], 1);
      expect(exhaustedRow['maxUses'], 1);
      expect(exhaustedRow['revokedAt'], firstAt);
    },
  );

  test(
    'anonymous and nonadmins cannot list or revoke; invalid input writes nothing',
    () async {
      final invite = await issue();
      for (final method in ['GET', 'POST']) {
        final path = method == 'GET'
            ? Routes.adminInvites
            : revokePath(invite.id);
        expect((await request(method, path, anonymous: true)).status, 401);
        expect(
          (await request(method, path, bearer: human.accessToken)).status,
          403,
        );
      }
      final before = jsonEncode((await domain.store.snapshot()).toJson());
      for (final body in <Object?>[
        {},
        [],
        'x',
        1,
        {'actorId': adminId.value},
      ]) {
        expect(
          (await request('POST', revokePath(invite.id), body: body)).status,
          400,
        );
      }
      for (final id in ['bad id', 'x' * 65]) {
        expect((await request('POST', revokePath(id))).status, 400);
      }
      expect((await request('POST', revokePath('missing-invite'))).status, 404);
      expect(jsonEncode((await domain.store.snapshot()).toJson()), before);
    },
  );

  test(
    'revoked rotated and expired credentials fail both boundaries',
    () async {
      final invite = await issue();
      Future<void> denied(String token) async {
        expect(
          (await request('GET', Routes.adminInvites, bearer: token)).status,
          401,
        );
        expect(
          (await request('POST', revokePath(invite.id), bearer: token)).status,
          401,
        );
      }

      final fresh = (await domain.refresh(admin.refreshToken)).value;
      await denied(admin.accessToken);
      final session = (await domain.scope(fresh.accessToken)).value;
      await session.devices.revoke(adminId, fresh.deviceId);
      await denied(fresh.accessToken);
      final relogged = (await domain.login(
        adminId,
        password,
        deviceName: 'new-admin',
      )).value;
      clock.advance(const Duration(days: 366));
      await denied(relogged.accessToken);
      expect(
        (await db.query('SELECT revoked_at FROM invite WHERE id = ?', [
          invite.id,
        ])).single['revoked_at'],
        isNull,
      );
    },
  );

  test(
    'cached principal cannot substitute another bearer or device on either endpoint',
    () async {
      final invite = await issue();
      final principal = (await domain.authenticate(admin.accessToken))!;
      final spoofed = Pipeline(
        router: router,
        authenticate: (_) async => principal,
      );
      final wrongDevice = Pipeline(
        router: router,
        authenticate: (_) async => Principal(
          accountId: principal.accountId,
          deviceId: 'wrong-device',
          isAdmin: true,
        ),
      );
      for (final method in ['GET', 'POST']) {
        final path = method == 'GET'
            ? Routes.adminInvites
            : revokePath(invite.id);
        expect(
          (await request(
            method,
            path,
            bearer: human.accessToken,
            through: spoofed,
          )).status,
          401,
        );
        expect((await request(method, path, through: wrongDevice)).status, 401);
      }
      expect(
        (await db.query('SELECT revoked_at FROM invite WHERE id = ?', [
          invite.id,
        ])).single['revoked_at'],
        isNull,
      );
    },
  );

  test(
    'revoke during password hashing prevents account creation and invite consumption',
    () async {
      final invite = await issue(maxUses: 2);
      final count = (await domain.store.snapshot()).accounts.length;
      hasher.block = true;
      final pending = redeem(invite.code);
      await hasher.entered.future;
      final revoked = await request('POST', revokePath(invite.id));
      hasher.release.complete();
      expect(revoked.status, 200);
      expect((await pending).status, 404);
      expect((await domain.store.snapshot()).accounts.length, count);
      final row = (await db.query(
        'SELECT used_count, revoked_at FROM invite WHERE id = ?',
        [invite.id],
      )).single;
      expect(row['used_count'], 0);
      expect(row['revoked_at'], clock.now().millisecondsSinceEpoch);
    },
  );

  test(
    'real HTTP revoke rejects fixed-length and chunked JSON null entities',
    () async {
      final invite = await issue();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serving = serve(server, pipeline);
      final client = HttpClient();
      try {
        for (final chunked in [false, true]) {
          final req = await client.post(
            '127.0.0.1',
            server.port,
            revokePath(invite.id),
          );
          req.headers.set('authorization', 'Bearer ${admin.accessToken}');
          req.headers.contentType = ContentType.json;
          if (!chunked) req.contentLength = 4;
          req.write('null');
          final response = await req.close();
          await response.drain<void>();
          expect(response.statusCode, 400);
          expect(
            (await db.query('SELECT revoked_at FROM invite WHERE id = ?', [
              invite.id,
            ])).single['revoked_at'],
            isNull,
          );
        }
        final req = await client.post(
          '127.0.0.1',
          server.port,
          revokePath(invite.id),
        );
        req.contentLength = 0;
        req.headers.set('authorization', 'Bearer ${admin.accessToken}');
        final response = await req.close();
        await response.drain<void>();
        expect(response.statusCode, 200);
      } finally {
        client.close(force: true);
        await server.close(force: true);
        await serving;
      }
    },
  );

  test('GET metadata respects configured invite collection path', () async {
    mount(path: '/custom/admin/invites');
    expect((await request('GET', '/custom/admin/invites')).status, 200);
    expect((await request('GET', Routes.adminInvites)).status, 404);
  });
}
