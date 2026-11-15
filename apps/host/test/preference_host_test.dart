import 'dart:io';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

class _Hasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String value) async => 'fixture:$value';
  @override
  Future<bool> verifyAsync(String value, String hash) async =>
      hash == 'fixture:$value';
}

void main() {
  test(
    'default host mounts conversation preferences behind authentication',
    () async {
      final dir = await Directory.systemTemp.createTemp('pin-host-');
      final host = await buildHost(config: HostConfig(dataDir: dir.path));
      try {
        expect(
          (await host.pipeline.handle(
            HostRequest(
              method: 'GET',
              path: '/api/v1/conversations/group/preferences',
            ),
          )).status,
          401,
        );
      } finally {
        await host.shutdown();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'default authenticated host persists own pin across restart without changing group list',
    () async {
      final dir = await Directory.systemTemp.createTemp('pin-real-host-');
      final clock = FakeClock(DateTime.utc(2026, 11, 15));
      var host = await buildHost(
        config: HostConfig(dataDir: dir.path),
        clock: clock,
      );
      try {
        final db = host.registry.services.get<Database>();
        final fixture = AccountsDomain(
          store: SqlAccountsStore(db),
          clock: clock,
          hasher: _Hasher(),
        );
        final owner = (await fixture.bootstrapAdmin(
          displayName: 'Owner',
          password: 'pin-host-password',
        )).value;
        final token = (await fixture.login(
          owner,
          'pin-host-password',
          deviceName: 'test',
        )).value.accessToken;
        final groups = host.registry.services.get<ConversationService>();
        final group = (await groups.createGroup(
          ownerAccountId: owner.value,
          name: 'Group',
        )).value;
        final before = (await groups.list(
          owner.value,
        )).value.map((c) => c.toJson()).toList();
        final path = '/api/v1/conversations/${group.id}/preferences';
        final put = await host.pipeline.handle(
          HostRequest(
            method: 'PUT',
            path: path,
            headers: {'authorization': 'Bearer $token'},
            body: {'pinned': true},
          ),
        );
        expect(put.status, 200);
        expect(put.json, {'pinned': true});
        expect(
          (await groups.list(
            owner.value,
          )).value.map((c) => c.toJson()).toList(),
          before,
        );
        await host.shutdown();
        host = await buildHost(
          config: HostConfig(dataDir: dir.path),
          clock: clock,
        );
        final get = await host.pipeline.handle(
          HostRequest(
            method: 'GET',
            path: path,
            headers: {'authorization': 'Bearer $token'},
          ),
        );
        expect(get.status, 200);
        expect(get.json, {'pinned': true});
      } finally {
        await host.shutdown();
        await dir.delete(recursive: true);
      }
    },
  );
}
