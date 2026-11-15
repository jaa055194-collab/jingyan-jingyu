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
  Future<String> hashAsync(String value) async => 'fixture:$value';
  @override
  Future<bool> verifyAsync(String value, String hash) async =>
      hash == 'fixture:$value';
}

void main() {
  late Directory directory;
  late Host host;
  late Database db;
  late AccountsDomain accounts;
  late AccountId owner, other;
  late String ownerToken, otherToken;
  late AiId profile;
  late FakeClock clock;
  const passwordValue = 'synthetic-long-passphrase';

  String path([String? id]) =>
      '/api/v1/ai-profiles/${id ?? profile.value}/social-level';
  Future<HostResponse> call(
    String method, {
    Object? body,
    String? token,
    String? id,
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    Pipeline? through,
  }) => (through ?? host.pipeline).handle(
    HostRequest(
      method: method,
      path: path(id),
      body: body,
      query: query,
      headers: {'authorization': 'Bearer ${token ?? ownerToken}', ...headers},
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('social-level-http-');
    clock = FakeClock(DateTime.utc(2026, 11, 16));
    host = await buildHost(
      config: HostConfig(dataDir: directory.path),
      clock: clock,
    );
    db = host.registry.services.get<Database>();
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    owner = (await accounts.bootstrapAdmin(
      displayName: 'Owner',
      password: passwordValue,
    )).value;
    ownerToken = (await accounts.login(
      owner,
      passwordValue,
      deviceName: 'owner',
    )).value.accessToken;
    final session = (await accounts.scope(ownerToken)).value;
    other = (await session.accounts.createHuman(
      displayName: 'Other',
      password: passwordValue,
    )).value;
    otherToken = (await accounts.login(
      other,
      passwordValue,
      deviceName: 'other',
    )).value.accessToken;
    final ai = (await session.accounts.createAi(
      operator: owner,
      displayName: 'AI',
    )).value;
    profile = (await AiIdentityResolver.forOwner(
      ownerId: owner.value,
      db: db,
    ).register(ai)).value.profileId;
  });
  tearDown(() async {
    await host.shutdown();
    await directory.delete(recursive: true);
  });

  test(
    'FR43 default host returns explicit unconfigured then saves all levels',
    () async {
      final missing = await call('GET');
      expect(missing.status, 200);
      expect(missing.json, {
        'configurationRequired': true,
        'level': null,
        'updatedAt': null,
      });
      for (final level in ['L0', 'L1', 'L2', 'L3', 'L4']) {
        final saved = await call('PUT', body: {'level': level});
        expect(saved.status, 200);
        expect(saved.json, {
          'configurationRequired': false,
          'level': level,
          'updatedAt': clock.now().toIso8601String(),
        });
        expect((await call('GET')).json, saved.json);
      }
      expect(await db.query('SELECT * FROM ai_social_levels'), hasLength(1));
      final audit = await db.query(
        "SELECT * FROM audit_log WHERE action='ai.social_level.configure'",
      );
      expect(audit, hasLength(5));
      expect(audit.last['meta'], '{"level":"L4"}');
      for (final entry in audit) {
        expect(entry['actor_id'], owner.value);
        expect(entry['target_kind'], 'ai_profile');
        expect(entry['target_id'], profile.value);
        expect(entry['at'], clock.now().toIso8601String());
      }
      expect(await db.query('SELECT * FROM persona_cards'), isEmpty);
      expect(await db.query('SELECT * FROM messages'), isEmpty);
    },
  );

  test(
    'FR43 strict settings body, query and GET entity failures never configure',
    () async {
      for (final body in <Object?>[
        null,
        {},
        [],
        {'level': 0},
        {'level': null},
        {'level': 'l1'},
        {'level': 'L5'},
        {'level': 'L1', 'ownerId': 'other'},
      ]) {
        expect((await call('PUT', body: body)).status, 400);
      }
      expect((await call('GET', query: {'owner': 'other'})).status, 400);
      expect((await call('GET', body: {})).status, 400);
      expect(
        (await call('GET', headers: {'transfer-encoding': 'chunked'})).status,
        400,
      );
      expect((await call('GET', id: 'bad%2Fid')).status, 400);
      expect(await db.query('SELECT * FROM ai_social_levels'), isEmpty);
      expect(
        await db.query(
          "SELECT * FROM audit_log WHERE action='ai.social_level.configure'",
        ),
        isEmpty,
      );
    },
  );

  test(
    'FR43 administrator cannot read other operator settings and revoked bearer fails',
    () async {
      final otherSession = (await accounts.scope(otherToken)).value;
      final account = (await otherSession.accounts.createAi(
        operator: other,
        displayName: 'Other AI',
      )).value;
      final foreign = (await AiIdentityResolver.forOwner(
        ownerId: other.value,
        db: db,
      ).register(account)).value.profileId;
      expect(
        (await call(
          'PUT',
          id: foreign.value,
          token: otherToken,
          body: {'level': 'L1'},
        )).status,
        200,
      );
      expect((await call('GET', id: foreign.value)).status, 404);
      expect(
        (await host.pipeline.handle(
          HostRequest(method: 'GET', path: path()),
        )).status,
        401,
      );
      final devices = await otherSession.devices.list(other);
      await otherSession.devices.revoke(other, devices.single.id);
      expect(
        (await call('GET', id: foreign.value, token: otherToken)).status,
        401,
      );
    },
  );

  test(
    'FR43 live bearer, principal and owner checks hide private settings',
    () async {
      expect((await call('PUT', body: {'level': 'L1'})).status, 200);
      expect((await call('GET', token: otherToken)).status, 404);
      expect((await call('GET', id: 'missing')).status, 404);
      final cached = Pipeline(
        router: host.registry.router,
        authenticate: (_) async =>
            Principal(accountId: owner.value, deviceId: 'wrong'),
      );
      expect((await call('GET', through: cached)).status, 401);
      expect((await call('GET', token: 'invalid')).status, 401);
      clock.advance(const Duration(hours: 2));
      expect((await call('GET')).status, 401);
    },
  );
}
