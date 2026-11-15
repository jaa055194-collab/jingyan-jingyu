import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/device_service.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/models/admin_usage_reader.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
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

class _OnlyTx implements Database {
  _OnlyTx(this.inner, {this.revokeDevice});
  final Database inner;
  final String? revokeDevice;
  final queries = <String>[];
  @override
  Future<T> transaction<T>(Future<T> Function(Tx tx) body) =>
      inner.transaction((tx) async {
        if (revokeDevice != null) {
          await tx.execute('DELETE FROM refresh_token WHERE device_id=?', [
            revokeDevice,
          ]);
          await tx.execute('DELETE FROM device WHERE id=?', [revokeDevice]);
        }
        return body(_ReadTx(tx, queries));
      });
  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) => throw StateError('Outer query');
  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      throw StateError('Outer write');
  @override
  Future<int> schemaVersion() => throw StateError('Unexpected');
  @override
  Future<String> integrityCheck() => throw StateError('Unexpected');
}

class _ReadTx implements Tx {
  _ReadTx(this.inner, this.queries);
  final Tx inner;
  final List<String> queries;
  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) {
    queries.add(sql);
    return inner.query(sql, args);
  }

  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      throw StateError('Reader wrote');
}

void main() {
  late Directory directory;
  late Host host;
  late Database db;
  late AccountsDomain accounts;
  late FakeClock clock;
  late Map<String, AccountId> ids;
  late Map<String, DeviceTokens> tokens;
  late AiId profile;
  const password = 'admin-usage-test-password';
  Future<void> open() async {
    host = await buildHost(
      config: HostConfig(dataDir: directory.path),
      clock: clock,
    );
    db = host.registry.services.get<Database>();
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _Hasher(),
    );
  }

  Future<void> row(
    String id, {
    String? owner,
    String? ai,
    String layer = 'b2DeepChat',
    String capability = 'chat',
    String input = '3',
    String output = '2',
    String total = '5',
    bool unknown = false,
    String day = '2020-01-01',
    int offset = -480,
  }) => db.execute(
    'INSERT INTO usage_ledger(owner_id,ai_id,request_id,budget_day,offset_minutes,layer,capability,input_tokens,output_tokens,total_tokens,source_usage_unknown) VALUES(?,?,?,?,?,?,?,?,?,?,?)',
    [
      owner ?? ids['owner']!.value,
      ai ?? profile.value,
      id,
      day,
      offset,
      layer,
      capability,
      unknown ? null : input,
      unknown ? null : output,
      unknown ? null : total,
      unknown ? 1 : 0,
    ],
  );
  Future<HostResponse> read({
    String actor = 'admin',
    String? bearer,
    bool anonymous = false,
    Pipeline? through,
    Map<String, String> query = const {},
  }) => (through ?? host.pipeline).handle(
    HostRequest(
      method: 'GET',
      path: '/api/v1/admin/usage',
      query: query,
      headers: {
        if (!anonymous)
          'authorization': 'Bearer ${bearer ?? tokens[actor]!.accessToken}',
      },
    ),
  );
  Map<String, Object?> json(HostResponse response) {
    expect(response.status, 200, reason: response.encodeBody());
    return (response.json as Map).cast<String, Object?>();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('admin-usage-');
    clock = FakeClock(DateTime.utc(2026, 11, 15));
    await open();
    ids = {};
    tokens = {};
    ids['admin'] = (await accounts.bootstrapAdmin(
      displayName: 'Admin',
      password: password,
    )).value;
    tokens['admin'] = (await accounts.login(
      ids['admin']!,
      password,
      deviceName: 'admin',
    )).value;
    final session = (await accounts.scope(tokens['admin']!.accessToken)).value;
    for (final name in ['owner', 'other']) {
      ids[name] = (await session.accounts.createHuman(
        displayName: name,
        password: password,
      )).value;
      tokens[name] = (await accounts.login(
        ids[name]!,
        password,
        deviceName: name,
      )).value;
    }
    final owner = (await accounts.scope(tokens['owner']!.accessToken)).value;
    ids['ai'] = (await owner.accounts.createAi(
      operator: ids['owner']!,
      displayName: 'AI',
    )).value;
    profile = (await AiIdentityResolver.forOwner(
      ownerId: ids['owner']!.value,
      db: db,
    ).register(ids['ai']!)).value.profileId;
  });
  tearDown(() async {
    await host.shutdown();
    await directory.delete(recursive: true);
  });

  test(
    'empty global recorded summary has exact safe allowlist without budget timezone',
    () async {
      final result = json(await read());
      expect(result.keys.toSet(), {
        'basis',
        'recordedTokens',
        'byLayer',
        'byCapability',
        'sourceUsageUnknown',
      });
      expect(result['basis'], 'allRecordedLedgerRows');
      expect(result['recordedTokens'], '0');
      expect(result['sourceUsageUnknown'], false);
      expect(result['byLayer'], {
        'b0Life': '0',
        'b1FastBrain': '0',
        'b2DeepChat': '0',
        'b3Proactive': '0',
        'b4Maintenance': '0',
      });
      expect(
        (result['byCapability'] as Map).keys.toSet(),
        ProviderCapability.values.map((c) => c.name).toSet(),
      );
      expect((result['byCapability'] as Map).values.toSet(), {'0'});
      expect(await db.query('SELECT * FROM usage_budget'), isEmpty);
    },
  );
  test(
    'global rows include prior owners disabled accounts all dates offsets and unknown flags',
    () async {
      await row('old');
      await row(
        'other',
        owner: ids['other']!.value,
        total: '7',
        input: '4',
        output: '3',
        day: '2027-12-31',
        offset: 840,
      );
      await row('pending', unknown: true, day: '2010-01-01');
      await db.execute('UPDATE ai_operator SET operator_id=? WHERE ai_id=?', [
        ids['other']!.value,
        ids['ai']!.value,
      ]);
      await db.execute('UPDATE account SET disabled=1 WHERE id IN (?,?)', [
        ids['owner']!.value,
        ids['ai']!.value,
      ]);
      final result = json(await read());
      expect(result['recordedTokens'], '12');
      expect(result['sourceUsageUnknown'], true);
      expect((result['byLayer'] as Map)['b2DeepChat'], '12');
      expect(jsonEncode(result), isNot(contains(ids['owner']!.value)));
      expect(jsonEncode(result), isNot(contains('pending')));
    },
  );
  test(
    'every category and counters beyond int64 remain exact decimal strings',
    () async {
      for (final layer in BudgetLayer.values) {
        await row(layer.name, layer: layer.name);
      }
      for (final capability in ProviderCapability.values) {
        await row(capability.name, capability: capability.name);
      }
      await row(
        'big1',
        input: '9223372036854775807',
        output: '0',
        total: '9223372036854775807',
      );
      await row(
        'big2',
        input: '9223372036854775807',
        output: '0',
        total: '9223372036854775807',
      );
      final result = json(await read());
      expect(result['recordedTokens'], '18446744073709551674');
      expect((result['byLayer'] as Map)['b0Life'], '5');
      expect((result['byCapability'] as Map)['embedding'], '5');
    },
  );
  test(
    'unknown-only is not invented known usage and settlement is reflected without mutation',
    () async {
      await row('unknown', unknown: true);
      final pending = json(await read());
      expect(pending['recordedTokens'], '0');
      expect(pending['sourceUsageUnknown'], true);
      await db.execute(
        'UPDATE usage_ledger SET input_tokens=?,output_tokens=?,total_tokens=?,source_usage_unknown=0',
        ['0', '0', '0'],
      );
      final settled = json(await read());
      expect(settled['recordedTokens'], '0');
      expect(settled['sourceUsageUnknown'], false);
      final before = jsonEncode(await db.query('SELECT * FROM usage_ledger'));
      expect(json(await read()), settled);
      expect(jsonEncode(await db.query('SELECT * FROM usage_ledger')), before);
      await host.shutdown();
      await open();
      expect(json(await read()), settled);
    },
  );
  test(
    'malformed retained counter or category fails closed without partial aggregate',
    () async {
      await row('good');
      for (final total in ['bad', '-5', '05', '6']) {
        await row('bad', total: total);
        final result = await read();
        expect(result.status, 500);
        expect(result.json, {'error': 'internal'});
        await db.execute('DELETE FROM usage_ledger WHERE request_id=?', [
          'bad',
        ]);
      }
      await row('bad-kind', layer: 'bad');
      expect((await read()).status, 500);
    },
  );
  test(
    'anonymous nonadmin and mismatched account device cannot use global scope',
    () async {
      expect((await read(anonymous: true)).status, 401);
      expect((await read(actor: 'owner')).status, 403);
      final principal = (await accounts.authenticate(
        tokens['admin']!.accessToken,
      ))!;
      final cached = Pipeline(
        router: host.registry.router,
        authenticate: (_) async => principal,
      );
      expect((await read(actor: 'owner', through: cached)).status, 401);
      final wrong = Pipeline(
        router: host.registry.router,
        authenticate: (_) async => Principal(
          accountId: principal.accountId,
          deviceId: 'wrong',
          isAdmin: true,
        ),
      );
      expect((await read(through: wrong)).status, 401);
      final user = (await accounts.authenticate(tokens['owner']!.accessToken))!;
      final elevated = Pipeline(
        router: host.registry.router,
        authenticate: (_) async => Principal(
          accountId: user.accountId,
          deviceId: user.deviceId,
          isAdmin: true,
        ),
      );
      expect((await read(actor: 'owner', through: elevated)).status, 403);
      expect((await read(query: {'ownerId': ids['owner']!.value})).status, 400);
    },
  );
  test(
    'current canonical state denies rotated revoked disabled demoted and expired credentials',
    () async {
      final principal = (await accounts.authenticate(
        tokens['admin']!.accessToken,
      ))!;
      final cached = Pipeline(
        router: host.registry.router,
        authenticate: (_) async => principal,
      );
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', [
        ids['admin']!.value,
      ]);
      expect((await read(through: cached)).status, 401);
      await db.execute('UPDATE account SET disabled=0,is_admin=0 WHERE id=?', [
        ids['admin']!.value,
      ]);
      expect((await read(through: cached)).status, 403);
      await db.execute('UPDATE account SET is_admin=1 WHERE id=?', [
        ids['admin']!.value,
      ]);
      final fresh = (await accounts.refresh(
        tokens['admin']!.refreshToken,
      )).value;
      expect((await read(through: cached)).status, 401);
      final session = (await accounts.scope(fresh.accessToken)).value;
      await session.devices.revoke(ids['admin']!, fresh.deviceId);
      expect((await read(bearer: fresh.accessToken)).status, 401);
      final again = (await accounts.login(
        ids['admin']!,
        password,
        deviceName: 'again',
      )).value;
      clock.advance(const Duration(hours: 1));
      expect((await read(bearer: again.accessToken)).status, 401);
    },
  );
  test(
    'reader authenticates in same Tx before one projected scan with no write or forbidden data',
    () async {
      await row('secret-request');
      final wrapper = _OnlyTx(db);
      final reader = AdminUsageReader(database: wrapper, clock: clock);
      final args = tokens['admin']!;
      final result = await reader.summary(
        bearer: args.accessToken,
        accountId: ids['admin']!.value,
        deviceId: args.deviceId.value,
      );
      expect(result.isOk, true);
      expect(wrapper.queries, hasLength(2));
      final sql = wrapper.queries.last.toLowerCase();
      for (final forbidden in [
        'select *',
        'owner_id',
        'request_id',
        'body',
        'provider',
        'api_key',
      ]) {
        expect(sql, isNot(contains(forbidden)));
      }
      final revoked = _OnlyTx(db, revokeDevice: args.deviceId.value);
      expect(
        (await AdminUsageReader(database: revoked, clock: clock).summary(
          bearer: args.accessToken,
          accountId: ids['admin']!.value,
          deviceId: args.deviceId.value,
        )).failureOrNull?.code,
        FailureCode.unauthenticated,
      );
      expect(revoked.queries, hasLength(1));
    },
  );
}
