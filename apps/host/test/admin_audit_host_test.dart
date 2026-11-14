import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
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
    'default host exposes administrator audit envelopes only behind authentication',
    () async {
      final dir = await Directory.systemTemp.createTemp('admin-audit-host-');
      final host = await buildHost(config: HostConfig(dataDir: dir.path));
      try {
        expect(
          (await host.pipeline.handle(
            HostRequest(method: 'GET', path: '/api/v1/admin/audit'),
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
    'default host canonical administrator can read persisted envelope without metadata',
    () async {
      final dir = await Directory.systemTemp.createTemp('audit-real-host-');
      final clock = FakeClock(DateTime.utc(2026, 11, 15));
      final host = await buildHost(
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
        final admin = (await fixture.bootstrapAdmin(
          displayName: 'Admin',
          password: 'host-audit-password',
        )).value;
        final token = (await fixture.login(
          admin,
          'host-audit-password',
          deviceName: 'test',
        )).value.accessToken;
        await db.execute(
          'INSERT INTO audit_log(at,actor_id,action,target_kind,target_id,meta) VALUES(?,?,?,?,?,?)',
          [
            '2026-11-15T00:00:00Z',
            admin.value,
            'message.edit',
            'message',
            'm1',
            'private body must not hydrate',
          ],
        );
        final response = await host.pipeline.handle(
          HostRequest(
            method: 'GET',
            path: '/api/v1/admin/audit',
            headers: {'authorization': 'Bearer $token'},
          ),
        );
        expect(response.status, 200);
        final entry =
            (((response.json as Map)['entries'] as List).single as Map);
        expect(entry.keys.toSet(), {
          'id',
          'at',
          'actorId',
          'action',
          'targetKind',
          'targetId',
        });
        expect(entry['targetId'], 'm1');
        expect(response.encodeBody(), isNot(contains('private body')));
      } finally {
        await host.shutdown();
        await dir.delete(recursive: true);
      }
    },
  );
}
