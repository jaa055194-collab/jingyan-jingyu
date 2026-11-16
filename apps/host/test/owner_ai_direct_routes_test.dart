import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_routes.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_consent.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/storage/sqlite_audit_log.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

import 'owner_ai_direct_consent_test.dart' show consentMigrations;

class _FailingAudit implements AuditLog {
  @override
  Future<void> record(AuditEntry entry) async =>
      throw StateError('forced audit failure');
  @override
  Future<List<AuditEntry>> forTarget(
    String targetKind,
    String targetId,
  ) async => [];
}

class _FastHasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String value) async => 'test:$value';
  @override
  Future<bool> verifyAsync(String value, String encodedHash) async =>
      encodedHash == 'test:$value';
}

void main() {
  late Directory dir;
  late SqliteDatabase db;
  late AccountsDomain accounts;
  late Pipeline pipeline;
  late Router router;
  late AccountId owner;
  late AccountId other;
  late AccountId ai;
  late String token;
  late String otherToken;
  late Principal ownerPrincipal;
  final clock = FakeClock(DateTime.utc(2026, 11, 17));
  const secret = 'owner-consent-test-secret';
  String path([String profile = 'profile-distinct']) =>
      Routes.ownerAiDirectConsent.replaceFirst('{aiId}', profile);
  Future<HostResponse> request(
    String method, {
    String? bearer,
    Object? body,
    Pipeline? through,
    String? route,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: method,
      path: route ?? path(),
      headers: {if (bearer != null) 'authorization': 'Bearer $bearer'},
      body: body,
    ),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('owner-ai-direct-http-');
    db = await SqliteDatabase.open(
      '${dir.path}/host.sqlite',
      migrations: consentMigrations,
    );
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    owner = (await accounts.bootstrapAdmin(
      displayName: 'owner',
      password: secret,
    )).value;
    token = (await accounts.login(
      owner,
      secret,
      deviceName: 'owner-device',
    )).value.accessToken;
    final session = (await accounts.scope(token)).value;
    other = (await session.accounts.createHuman(
      displayName: 'other',
      password: secret,
    )).value;
    otherToken = (await accounts.login(
      other,
      secret,
      deviceName: 'other-device',
    )).value.accessToken;
    ai = (await session.accounts.createAi(
      operator: owner,
      displayName: 'own AI',
    )).value;
    await db.execute('INSERT INTO ai_profile(id,account_id) VALUES(?,?)', [
      'profile-distinct',
      ai.value,
    ]);
    ownerPrincipal = (await accounts.authenticate(token))!;
    router = Router();
    mountOwnerAiDirectRoutes(
      router,
      db: db,
      clock: clock,
      accounts: accounts,
      audit: SqliteAuditLog(db),
    );
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(accounts).call,
      onError: (error, stack, _) => Error.throwWithStackTrace(error, stack),
    );
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test(
    'GET is default-off metadata; explicit CAS open/revoke; profile/account are distinct',
    () async {
      final initial = await request('GET', bearer: token);
      expect(initial.status, 200);
      expect((initial.json as Map)['revision'], 0);
      expect(await db.query('SELECT * FROM owner_ai_direct_grants'), isEmpty);
      final opened = await request(
        'POST',
        bearer: token,
        body: {'expectedRevision': 0},
      );
      expect(opened.status, 200);
      final value = opened.json as Map;
      expect(value['scope'], 'ownerTextOnly');
      expect(value['aiAccountId'], ai.value);
      expect(value['aiProfileId'], 'profile-distinct');
      expect(value['enabled'], true);
      expect(
        (await request(
          'POST',
          bearer: token,
          body: {'expectedRevision': 0},
        )).status,
        409,
      );
      expect(
        (await request(
          'DELETE',
          bearer: token,
          body: {'expectedRevision': 1},
        )).status,
        200,
      );
      expect(
        (await request('GET', bearer: token)).json as Map,
        containsPair('enabled', false),
      );
      expect(await db.query('SELECT * FROM friendships'), isEmpty);
      expect(await db.query('SELECT * FROM friend_requests'), isEmpty);
      final audit = await db.query('SELECT action,meta FROM audit_log');
      expect(
        audit.map((r) => r['action']),
        containsAll(['owner_ai_direct.open', 'owner_ai_direct.revoke']),
      );
      expect(audit.every((r) => !(r['meta'] as String).contains('text')), true);
    },
  );

  test(
    'foreign/admin status and account instead of profile cannot grant; unknown fields rejected',
    () async {
      expect((await request('GET', bearer: otherToken)).status, 404);
      expect(
        (await request(
          'POST',
          bearer: otherToken,
          body: {'expectedRevision': 0},
        )).status,
        404,
      );
      expect(
        (await request(
          'POST',
          bearer: token,
          route: path(ai.value),
          body: {'expectedRevision': 0},
        )).status,
        404,
      );
      for (final body in [
        null,
        {},
        {'expectedRevision': -1},
        {'expectedRevision': 0.5},
        {'expectedRevision': 0, 'ownerId': other.value},
        {'expectedRevision': 0, 'aiAccountId': ai.value},
      ]) {
        expect((await request('POST', bearer: token, body: body)).status, 400);
      }
      expect((await request('GET', bearer: token, body: {})).status, 400);
      expect((await request('GET')).status, 401);
    },
  );

  test(
    'cached principal must match current bearer account AND device',
    () async {
      final cached = Pipeline(
        router: router,
        authenticate: (_) async => ownerPrincipal,
      );
      expect(
        (await request(
          'POST',
          bearer: otherToken,
          through: cached,
          body: {'expectedRevision': 0},
        )).status,
        401,
      );
      final second = (await accounts.login(
        owner,
        secret,
        deviceName: 'second-owner-device',
      )).value;
      expect(
        (await request(
          'POST',
          bearer: second.accessToken,
          through: cached,
          body: {'expectedRevision': 0},
        )).status,
        401,
      );
      await db.execute('DELETE FROM refresh_token WHERE device_id=?', [
        ownerPrincipal.deviceId,
      ]);
      await db.execute('DELETE FROM device WHERE id=?', [
        ownerPrincipal.deviceId,
      ]);
      expect(
        (await request(
          'POST',
          bearer: token,
          through: cached,
          body: {'expectedRevision': 0},
        )).status,
        401,
      );
      expect(await db.query('SELECT * FROM owner_ai_direct_grants'), isEmpty);
    },
  );

  test(
    'default assembly mounts consent and messages: revoke/transfer preserve only original human history',
    () async {
      final hostDir = await Directory.systemTemp.createTemp(
        'owner-consent-default-',
      );
      final host = await buildHost(
        config: HostConfig(dataDir: hostDir.path),
        clock: clock,
      );
      try {
        final realDb = host.registry.services.get<Database>();
        final realOwner = (await host.auth.bootstrapAdmin(
          displayName: 'Owner',
          password: secret,
        )).value;
        final realToken = (await host.auth.login(
          realOwner,
          secret,
          deviceName: 'real-device',
        )).value.accessToken;
        final admin = (await host.auth.scope(realToken)).value;
        final realAi = (await admin.accounts.createAi(
          operator: realOwner,
          displayName: 'AI',
        )).value;
        final newOwner = (await admin.accounts.createHuman(
          displayName: 'new-owner',
          password: secret,
        )).value;
        final newToken = (await host.auth.login(
          newOwner,
          secret,
          deviceName: 'new-device',
        )).value.accessToken;
        await realDb.execute(
          'INSERT INTO ai_profile(id,account_id) VALUES(?,?)',
          ['real-profile', realAi.value],
        );
        Future<HostResponse> call(
          String method,
          String route, {
          Object? body,
          String? bearer,
        }) => host.pipeline.handle(
          HostRequest(
            method: method,
            path: route,
            headers: {'authorization': 'Bearer ${bearer ?? realToken}'},
            body: body,
          ),
        );
        final route = Routes.ownerAiDirectConsent.replaceFirst(
          '{aiId}',
          'real-profile',
        );
        expect(
          (await call('GET', route)).json as Map,
          containsPair('revision', 0),
        );
        final granted = await call(
          'POST',
          route,
          body: {'expectedRevision': 0},
        );
        expect(granted.status, 200);
        final id = (granted.json as Map)['conversationId'] as String;
        final sendPath = Routes.messages.replaceFirst('{conversationId}', id);
        final syncPath = Routes.sync.replaceFirst('{conversationId}', id);
        final prefsPath = Routes.conversationPreferences.replaceFirst(
          '{conversationId}',
          id,
        );
        final sent = await call(
          'POST',
          sendPath,
          body: {
            'clientMsgId': 'owner-text-1',
            'kind': 'text',
            'body': {'text': 'synthetic owner message'},
          },
        );
        expect(sent.status, 200);
        // No dispatch: exactly the owner message, not an automatic AI reply.
        final synced = await call('GET', syncPath);
        expect(((synced.json as Map)['messages'] as List), hasLength(1));
        expect(
          (await call('PUT', prefsPath, body: {'pinned': true})).status,
          200,
        );
        expect(
          (await call('DELETE', route, body: {'expectedRevision': 1})).status,
          200,
        );
        expect(
          (await call(
            'POST',
            sendPath,
            body: {
              'clientMsgId': 'owner-text-2',
              'kind': 'text',
              'body': {'text': 'rejected'},
            },
          )).status,
          404,
        );
        expect((await call('GET', syncPath)).status, 200);
        await realDb.execute(
          'UPDATE ai_operator SET operator_id=? WHERE ai_id=?',
          [newOwner.value, realAi.value],
        );
        expect((await call('GET', syncPath, bearer: newToken)).status, 404);
        expect((await call('GET', prefsPath, bearer: newToken)).status, 404);
        expect((await call('GET', syncPath)).status, 200);
        final history = await call('GET', Routes.directConversations);
        expect(((history.json as Map)['conversations'] as List), hasLength(1));
      } finally {
        await host.shutdown();
        await hostDir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'forced post-commit audit failure preserves successful open/revoke response and revision',
    () async {
      final auditRouter = Router();
      mountOwnerAiDirectRoutes(
        auditRouter,
        db: db,
        clock: clock,
        accounts: accounts,
        audit: _FailingAudit(),
      );
      final through = Pipeline(
        router: auditRouter,
        authenticate: DbAuthenticator(accounts).call,
      );
      final opened = await request(
        'POST',
        bearer: token,
        through: through,
        body: {'expectedRevision': 0},
      );
      expect(opened.status, 200);
      expect(opened.json as Map, containsPair('revision', 1));
      final revoked = await request(
        'DELETE',
        bearer: token,
        through: through,
        body: {'expectedRevision': 1},
      );
      expect(revoked.status, 200);
      expect(revoked.json as Map, containsPair('revision', 2));
      final rows = await db.query(
        'SELECT enabled,revision FROM owner_ai_direct_grants',
      );
      expect(rows.single['enabled'], 0);
      expect(rows.single['revision'], 2);
      expect(await db.query('SELECT * FROM audit_log'), isEmpty);
    },
  );

  test(
    'canonical resolver is internal same-Tx capability and revoke invalidates revision',
    () async {
      final service = OwnerAiDirectConsent(database: db, clock: clock);
      final opened = (await service.open(
        ownerId: owner.value,
        aiProfileId: 'profile-distinct',
        expectedRevision: 0,
      )).value;
      final id = opened['conversationId'] as String;
      await db.transaction((tx) async {
        final grant = await OwnerAiDirectConsent.resolveInTx(
          tx,
          ownerAccountId: owner.value,
          conversationId: id,
        );
        expect(grant!.aiAccountId, ai.value);
        expect(grant.aiProfileId, 'profile-distinct');
        expect(grant.revision, 1);
        expect(
          await OwnerAiDirectConsent.resolveInTx(
            tx,
            ownerAccountId: other.value,
            conversationId: id,
          ),
          isNull,
        );
      });
      await service.revoke(
        ownerId: owner.value,
        aiProfileId: 'profile-distinct',
        expectedRevision: 1,
      );
      expect(
        await db.transaction(
          (tx) => OwnerAiDirectConsent.resolveInTx(
            tx,
            ownerAccountId: owner.value,
            conversationId: id,
          ),
        ),
        isNull,
      );
    },
  );
}
