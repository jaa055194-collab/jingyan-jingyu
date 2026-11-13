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
  test(
    'M02 routes reject anonymous admin access and validate public input',
    () async {
      final domain = AccountsDomain(
        store: InMemoryAccountsStore(),
        clock: FakeClock(DateTime.utc(2026)),
        hasher: PasswordHasher(),
      );
      final registry = Registry()
        ..register(_Storage())
        ..register(
          AccountsModule(
            domain: domain,
            adminAccountsPath: '${Routes.prefix}/admin/accounts',
            adminInvitesPath: '${Routes.prefix}/admin/invites',
          ),
        );
      await registry.boot();
      final pipeline = Pipeline(
        router: registry.router,
        authenticate: DbAuthenticator(domain).call,
      );
      expect(
        (await pipeline.handle(
          HostRequest(method: 'GET', path: '${Routes.prefix}/admin/accounts'),
        )).status,
        401,
      );
      expect(
        (await pipeline.handle(
          HostRequest(
            method: 'POST',
            path: Routes.authLogin,
            body: {
              'accountId': 'broken id',
              'password': 'somepassword12',
              'deviceName': 'pc',
            },
          ),
        )).status,
        400,
      );
      expect(
        (await pipeline.handle(
          HostRequest(
            method: 'POST',
            path: Routes.authRefresh,
            body: {'refreshToken': 42},
          ),
        )).status,
        400,
      );
      expect(
        (await pipeline.handle(
          HostRequest(
            method: 'POST',
            path: Routes.authInviteRedeem,
            remoteAddress: '127.0.0.1',
            body: {'code': 42},
          ),
        )).status,
        400,
      );
      await registry.shutdown();
    },
  );
}
