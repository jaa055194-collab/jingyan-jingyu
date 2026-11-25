@Timeout(Duration(minutes: 10))
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_module.dart';
import 'package:jingyu_host/src/accounts/accounts_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _Storage extends HostModule {
  @override
  String get name => 'storage';
}

void main() {
  group('Accounts HTTP acceptance', () {
    late FakeClock clock;
    late AccountsDomain domain;
    late Registry registry;
    late Pipeline pipeline;
    late AccountSession admin;
    late String adminBearer;
    const password = 'http-acceptance-password';

    Future<HostResponse> request(
      String method,
      String path, {
      Object? body,
      String? bearer,
      String ip = '127.0.0.1',
    }) => pipeline.handle(
      HostRequest(
        method: method,
        path: path,
        body: body,
        remoteAddress: ip,
        headers: bearer == null ? {} : {'authorization': 'Bearer $bearer'},
      ),
    );
    Map<String, Object?> json(HostResponse response) {
      expect(response.status, 200, reason: response.encodeBody());
      return (response.json as Map).cast<String, Object?>();
    }

    Future<Map<String, Object?>> login(
      String account,
      String name, {
      String secret = password,
    }) async => json(
      await request(
        'POST',
        Routes.authLogin,
        body: {'accountId': account, 'password': secret, 'deviceName': name},
      ),
    );
    Future<String> invite({int uses = 1}) async =>
        json(
              await request(
                'POST',
                Routes.adminInvites,
                bearer: adminBearer,
                body: {
                  'expiresAt': clock
                      .now()
                      .add(const Duration(hours: 1))
                      .toIso8601String(),
                  'maxUses': uses,
                },
              ),
            )['code']!
            as String;
    Future<HostResponse> redeem(String code, {String ip = '127.0.0.1'}) =>
        request(
          'POST',
          Routes.authInviteRedeem,
          ip: ip,
          body: {
            'code': code,
            'displayName': 'HTTP user',
            'password': password,
          },
        );
    setUpAll(() async {
      clock = FakeClock(DateTime.utc(2026));
      domain = AccountsDomain(
        store: InMemoryAccountsStore(),
        clock: clock,
        hasher: PasswordHasher(),
      );
      final id = (await domain.bootstrapAdmin(
        displayName: 'admin',
        password: password,
      )).value;
      adminBearer = (await domain.login(
        id,
        password,
        deviceName: 'admin',
      )).value.accessToken;
      admin = (await domain.scope(adminBearer)).value;
      registry = Registry()
        ..register(_Storage())
        ..register(AccountsModule(domain: domain));
      await registry.boot();
      pipeline = Pipeline(
        router: registry.router,
        authenticate: DbAuthenticator(domain).call,
        onError: (error, stack, request) =>
            fail('Unhandled HTTP error: $error\n$stack'),
      );
    });
    tearDownAll(() => registry.shutdown());

    test(
      'AC-02a HTTP twenty concurrent redemptions consume exactly maxUses',
      () async {
        final code = await invite(uses: 2);
        final responses = await Future.wait(
          List.generate(20, (i) => redeem(code, ip: '192.0.2.${i + 1}')),
        );
        expect(responses.where((response) => response.status == 200).length, 2);
        expect(
          responses
              .where((response) => response.status != 200)
              .every((response) => response.status == 404),
          isTrue,
        );
        expect(
          json(
            responses.firstWhere((response) => response.status == 200),
          )['accountId'],
          isA<String>(),
        );
      },
    );

    test(
      'AC-02b HTTP expired revoked exhausted invites reject redemption',
      () async {
        final expired = (await admin.invites.issue(
          expiresAt: clock.now().add(const Duration(seconds: 1)),
        )).value;
        clock.advance(const Duration(seconds: 1));
        expect((await redeem(expired)).status, 404);
        final revoked = await invite();
        final id = (await admin.inviteMetadata()).value.last['id']! as String;
        expect((await admin.invites.revoke(id)).isOk, isTrue);
        expect((await redeem(revoked)).status, 404);
        final exhausted = await invite();
        expect((await redeem(exhausted)).status, 200);
        expect((await redeem(exhausted)).status, 404);
      },
    );

    test(
      'AC-02c HTTP fifth bad password locks all devices until fifteen minutes',
      () async {
        final account =
            json(await redeem(await invite()))['accountId']! as String;
        for (var i = 0; i < 5; i++) {
          expect(
            (await request(
              'POST',
              Routes.authLogin,
              ip: '198.51.100.${i + 1}',
              body: {
                'accountId': account,
                'password': 'wrong',
                'deviceName': 'device$i',
              },
            )).status,
            401,
          );
        }
        expect(
          (await request(
            'POST',
            Routes.authLogin,
            body: {
              'accountId': account,
              'password': password,
              'deviceName': 'correct',
            },
          )).status,
          401,
        );
        clock.advance(const Duration(minutes: 15));
        expect(
          (await login(account, 'unlocked'))['accessToken'],
          isA<String>(),
        );
      },
    );

    test(
      'AC-02d AC-02e HTTP eviction remote revoke and refresh replay immediately return 401',
      () async {
        final account =
            json(await redeem(await invite()))['accountId']! as String;
        final first = await login(account, 'first');
        clock.advance(const Duration(seconds: 1));
        final second = await login(account, 'second');
        clock.advance(const Duration(seconds: 1));
        expect(
          (await request(
            'GET',
            Routes.authDevices,
            bearer: first['accessToken'] as String,
          )).status,
          200,
        );
        clock.advance(const Duration(seconds: 1));
        final third = await login(account, 'third');
        expect(
          (await request(
            'GET',
            Routes.authDevices,
            bearer: second['accessToken'] as String,
          )).status,
          401,
        );
        expect(
          (await request(
            'POST',
            Routes.authRefresh,
            body: {'refreshToken': second['refreshToken']},
          )).status,
          401,
        );
        final devices = await request(
          'GET',
          Routes.authDevices,
          bearer: third['accessToken'] as String,
        );
        expect(devices.status, 200);
        expect((devices.json as List).length, 2);
        final revokePath = Routes.authDeviceRevoke.replaceAll(
          '{deviceId}',
          first['deviceId']! as String,
        );
        expect(
          (await request(
            'POST',
            revokePath,
            bearer: third['accessToken'] as String,
          )).status,
          200,
        );
        expect(
          (await request(
            'GET',
            Routes.authDevices,
            bearer: first['accessToken'] as String,
          )).status,
          401,
        );
        expect(
          (await request(
            'POST',
            Routes.authRefresh,
            body: {'refreshToken': first['refreshToken']},
          )).status,
          401,
        );
        final rotated = json(
          await request(
            'POST',
            Routes.authRefresh,
            body: {'refreshToken': third['refreshToken']},
          ),
        );
        expect(
          (await request(
            'POST',
            Routes.authRefresh,
            body: {'refreshToken': third['refreshToken']},
          )).status,
          401,
        );
        expect(
          (await request(
            'GET',
            Routes.authDevices,
            bearer: third['accessToken'] as String,
          )).status,
          401,
        );
        expect(
          (await request(
            'GET',
            Routes.authDevices,
            bearer: rotated['accessToken'] as String,
          )).status,
          200,
        );
        expect(
          (await request(
            'GET',
            Routes.adminAccounts,
            bearer: rotated['accessToken'] as String,
          )).status,
          403,
        );
      },
    );

    test('GET devices marks only the validated current bearer device', () async {
      const name = 'Same device name';
      final account =
          json(await redeem(await invite()))['accountId']! as String;
      final first = await login(account, name);
      final second = await login(account, name);
      final firstId = first['deviceId']! as String;
      final secondId = second['deviceId']! as String;
      final firstBearer = first['accessToken']! as String;
      final secondBearer = second['accessToken']! as String;
      expect(firstId, isNot(secondId));
      expect(firstBearer != secondBearer, isTrue);

      Future<void> expectDevices(
        String bearer,
        String current,
        Set<String> others,
      ) async {
        final response = await request(
          'GET',
          Routes.authDevices,
          bearer: bearer,
        );
        expect(response.status, 200);
        final rows = (response.json as List).cast<Map<String, Object?>>();
        expect(
          rows.map((row) => row['id']),
          unorderedEquals([current, ...others]),
        );
        expect(
          rows.where((row) => row['current'] == true).map((row) => row['id']),
          [current],
        );
        for (final row in rows) {
          // Assert the exact keys without logging response values or credentials.
          expect(
            row.keys,
            unorderedEquals([
              'id',
              'deviceName',
              'lastUsedAt',
              if (row['id'] == current) 'current',
            ]),
          );
          expect(row['deviceName'], name);
          expect(row['lastUsedAt'], clock.now().toIso8601String());
        }
      }

      // Names, timestamps and ordering do not identify the calling device.
      await expectDevices(firstBearer, firstId, {secondId});
      await expectDevices(secondBearer, secondId, {firstId});

      final foreignAccount =
          json(await redeem(await invite()))['accountId']! as String;
      final foreign = await login(foreignAccount, name);
      await expectDevices(
        foreign['accessToken']! as String,
        foreign['deviceId']! as String,
        {},
      );
      await expectDevices(secondBearer, secondId, {firstId});

      final revokePath = Routes.authDeviceRevoke.replaceFirst(
        '{deviceId}',
        secondId,
      );
      expect(
        (await request('POST', revokePath, bearer: firstBearer)).status,
        200,
      );
      for (final unusable in [null, '0000000000000000000000', secondBearer]) {
        final response = await request(
          'GET',
          Routes.authDevices,
          bearer: unusable,
        );
        expect(response.status, 401);
        expect((response.json as Map)['error'], 'unauthenticated');
      }
      await expectDevices(firstBearer, firstId, {});
    });

    test(
      'HTTP invite limiter shares code budget across distinct trusted peer IPs',
      () async {
        const invalidCode = 'AAAAAAAAAAAAAAAAAAAAAA';
        for (var i = 0; i < 30; i++) {
          expect(
            (await redeem(invalidCode, ip: '203.0.113.${i + 1}')).status,
            404,
          );
        }
        expect((await redeem(invalidCode, ip: '203.0.113.99')).status, 429);
      },
    );
  });
}
