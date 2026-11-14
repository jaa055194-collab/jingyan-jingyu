import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/storage/database.dart';
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
  test(
    'default host registers persona migration and authenticated owner routes',
    () async {
      final dir = await Directory.systemTemp.createTemp('persona-host-');
      final host = await buildHost(config: HostConfig(dataDir: dir.path));
      try {
        for (final path in [
          '/api/v1/ai-profiles/profile/persona',
          '/api/v1/ai-profiles/profile/persona/initialize',
          '/api/v1/ai-profiles/profile/persona/lock',
        ]) {
          final method = path.endsWith('initialize')
              ? 'POST'
              : path.endsWith('lock')
              ? 'PUT'
              : 'GET';
          expect(
            (await host.pipeline.handle(
              HostRequest(method: method, path: path),
            )).status,
            401,
          );
        }
        expect(
          (await host.pipeline.handle(
            HostRequest(
              method: 'PATCH',
              path: '/api/v1/ai-profiles/profile/persona',
            ),
          )).status,
          401,
        );
        final db = host.registry.services.get<Database>();
        expect(
          await db.query('SELECT 1 FROM schema_migrations WHERE version = 601'),
          hasLength(1),
        );
        expect(await db.query('SELECT * FROM persona_cards'), isEmpty);
        expect(
          await db.query('SELECT 1 FROM schema_migrations WHERE version = 600'),
          isEmpty,
        );
      } finally {
        await host.shutdown();
        await dir.delete(recursive: true);
      }
    },
  );

  test('default production module serves an authenticated owner card', () async {
    final dir = await Directory.systemTemp.createTemp('persona-host-owner-');
    final clock = FakeClock(DateTime.utc(2026, 11, 15));
    final host = await buildHost(
      config: HostConfig(dataDir: dir.path),
      clock: clock,
    );
    try {
      final db = host.registry.services.get<Database>();
      // Seed via a second real account facade with a deterministic test hasher;
      // production Pipeline/PersonaModule still use the host's live DB authenticator.
      final fixture = AccountsDomain(
        store: SqlAccountsStore(db),
        clock: clock,
        hasher: _FastHasher(),
      );
      const password = 'persona-host-fixture-password';
      final owner = (await fixture.bootstrapAdmin(
        displayName: 'Owner',
        password: password,
      )).value;
      final token = (await fixture.login(
        owner,
        password,
        deviceName: 'fixture',
      )).value.accessToken;
      final session = (await fixture.scope(token)).value;
      final account = (await session.accounts.createAi(
        operator: owner,
        displayName: 'AI',
      )).value;
      final profile = (await AiIdentityResolver.forOwner(
        ownerId: owner.value,
        db: db,
      ).register(account)).value.profileId;
      final path = '/api/v1/ai-profiles/${profile.value}/persona';
      final response = await host.pipeline.handle(
        HostRequest(
          method: 'POST',
          path: '$path/initialize',
          headers: {'authorization': 'Bearer $token'},
          body: {
            'p0': {'name': 'Nora'},
            'p1': {'style': 'warm'},
            'p2': {'mood': 'calm'},
          },
        ),
      );
      expect(response.status, 200);
      final read = await host.pipeline.handle(
        HostRequest(
          method: 'GET',
          path: path,
          headers: {'authorization': 'Bearer $token'},
        ),
      );
      expect(read.status, 200);
      expect((read.json as Map)['version'], 1);
      expect(
        (((read.json as Map)['layers'] as Map)['p0'] as Map)['name'],
        'Nora',
      );
      expect(await db.query('SELECT * FROM persona_cards'), hasLength(1));
      expect(await db.query('SELECT * FROM persona_history'), hasLength(1));
    } finally {
      await host.shutdown();
      await dir.delete(recursive: true);
    }
  });
}
