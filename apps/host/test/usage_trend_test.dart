import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/device_service.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/audit/audit_log.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/budget_configuration.dart';
import 'package:jingyu_host/src/models/budget_timezone_migration.dart';
import 'package:jingyu_host/src/models/models_migrations.dart';
import 'package:jingyu_host/src/models/models_module.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/models/usage_meter.dart';
import 'package:jingyu_host/src/models/usage_migrations.dart';
import 'package:jingyu_host/src/models/usage_trend.dart';
import 'package:jingyu_host/src/security/url_guard.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

class _Hasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String text) async => 'test:$text';
  @override
  Future<bool> verifyAsync(String text, String hash) async =>
      hash == 'test:$text';
}

class _SingleSampleClock extends Clock {
  _SingleSampleClock(this.instant);
  final DateTime instant;
  int samples = 0;
  @override
  DateTime now() {
    samples++;
    if (samples > 1) throw StateError('Summary sampled time twice');
    return instant;
  }
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late FakeClock clock;
  late AesGcmColumnCipher cipher;
  late AccountsDomain accounts;
  late Map<String, AccountId> ids;
  late Map<String, DeviceTokens> tokens;
  late AccountId aiAccount;
  late AiId ai;
  late Router router;
  late Pipeline pipeline;
  const password = 'recorded-rolling-trend-password';

  Future<void> configure({int offset = 480, String? owner}) async {
    expect(
      (await BudgetConfiguration.forOwner(
            ownerId: owner ?? ids['owner']!.value,
            db: db,
            clock: clock,
          ).configure(
            ai,
            UsageBudget(
              dailyTokens: 0,
              layerLimits: {for (final l in BudgetLayer.values) l: 0},
              capabilityLimits: {
                for (final c in ProviderCapability.values) c: 0,
              },
            ),
            offsetMinutes: offset,
          ))
          .isOk,
      true,
    );
  }

  Future<void> row(
    String id,
    String day, {
    String total = '5',
    String input = '3',
    String output = '2',
    String layer = 'b2DeepChat',
    String capability = 'chat',
    bool pending = false,
    int offset = 480,
    String? owner,
    String? profile,
  }) async {
    await db.execute(
      'INSERT INTO usage_ledger(owner_id,ai_id,request_id,budget_day,offset_minutes,layer,capability,input_tokens,output_tokens,total_tokens,source_usage_unknown) VALUES(?,?,?,?,?,?,?,?,?,?,?)',
      [
        owner ?? ids['owner']!.value,
        profile ?? ai.value,
        id,
        day,
        offset,
        layer,
        capability,
        pending ? null : input,
        pending ? null : output,
        pending ? null : total,
        pending ? 1 : 0,
      ],
    );
  }

  Future<HostResponse> read({
    String actor = 'owner',
    bool anonymous = false,
    String? bearer,
    String? profile,
    Map<String, String> query = const {},
    Pipeline? through,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: 'GET',
      path: '/api/v1/ai-profiles/${profile ?? ai.value}/usage/trend',
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

  List<Map<String, Object?>> days(Map<String, Object?> result) =>
      (result['days'] as List).cast<Map<String, Object?>>();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('usage-trend-');
    db = await SqliteDatabase.open(
      '${directory.path}/db.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...modelsMigrations,
        aiIdentityMigration,
        ...usageMigrations,
        budgetTimezoneMigration,
      ],
    );
    clock = FakeClock(DateTime.utc(2026, 11, 14, 16, 1));
    cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _Hasher(),
    );
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
    final admin = (await accounts.scope(tokens['admin']!.accessToken)).value;
    for (final name in ['owner', 'other']) {
      ids[name] = (await admin.accounts.createHuman(
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
    aiAccount = (await owner.accounts.createAi(
      operator: ids['owner']!,
      displayName: 'AI',
    )).value;
    ai = (await AiIdentityResolver.forOwner(
      ownerId: ids['owner']!.value,
      db: db,
    ).register(aiAccount)).value.profileId;
    final module = ModelsModule(
      db: db,
      cipher: cipher,
      urlGuard: UrlGuard(),
      clock: clock,
    );
    await module.configure(
      HostServices()
        ..provide<AccountsDomain>(accounts, owner: 'accounts')
        ..provide<AuditLog>(InMemoryAuditLog(), owner: 'system'),
    );
    router = Router();
    module.mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(accounts).call,
    );
  });
  tearDown(() async {
    cipher.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'mounted rolling7 returns seven ascending zero buckets for a configured exhausted budget',
    () async {
      await configure();
      final result = json(await read());
      expect(result.keys.toSet(), {
        'window',
        'basis',
        'offsetMinutes',
        'startDay',
        'endDay',
        'days',
        'sourceUsageUnknown',
      });
      expect(result['window'], 'rolling7');
      expect(result['basis'], 'recordedBudgetDay');
      expect(result['offsetMinutes'], 480);
      expect(result['startDay'], '2026-11-09');
      expect(result['endDay'], '2026-11-15');
      expect(days(result).map((d) => d['day']), [
        '2026-11-09',
        '2026-11-10',
        '2026-11-11',
        '2026-11-12',
        '2026-11-13',
        '2026-11-14',
        '2026-11-15',
      ]);
      for (final bucket in days(result)) {
        expect(bucket['recordedTokens'], '0');
        expect(bucket['sourceUsageUnknown'], false);
        expect(bucket['byLayer'], {
          'b0Life': '0',
          'b1FastBrain': '0',
          'b2DeepChat': '0',
          'b3Proactive': '0',
          'b4Maintenance': '0',
        });
      }
      expect(result['sourceUsageUnknown'], false);
    },
  );

  test(
    'known records count only seven inclusive recorded dates and retain historical offsets',
    () async {
      await configure();
      await row(
        'too-old',
        '2026-11-08',
        total: '100',
        input: '50',
        output: '50',
      );
      await row('start', '2026-11-09');
      await row(
        'today',
        '2026-11-15',
        total: '9',
        input: '4',
        output: '5',
        offset: 0,
      );
      await row(
        'future',
        '2026-11-16',
        total: '100',
        input: '50',
        output: '50',
      );
      final buckets = days(json(await read()));
      expect(buckets.first['recordedTokens'], '5');
      expect(buckets.last['recordedTokens'], '9');
      expect(buckets.where((d) => d['recordedTokens'] != '0'), hasLength(2));
    },
  );

  test(
    'all layers and totals beyond int64 remain exact decimal strings',
    () async {
      await configure();
      for (final layer in [
        'b0Life',
        'b1FastBrain',
        'b2DeepChat',
        'b3Proactive',
        'b4Maintenance',
      ]) {
        await row(layer, '2026-11-15', layer: layer);
      }
      await row(
        'huge1',
        '2026-11-14',
        total: '9223372036854775807',
        input: '9223372036854775807',
        output: '0',
      );
      await row(
        'huge2',
        '2026-11-14',
        total: '9223372036854775807',
        input: '9223372036854775807',
        output: '0',
      );
      final buckets = days(json(await read()));
      expect(buckets.last['recordedTokens'], '25');
      expect((buckets.last['byLayer'] as Map).values.toSet(), {'5'});
      expect(buckets[5]['recordedTokens'], '18446744073709551614');
    },
  );

  test(
    'pending flags include all history and distinguish unresolved from known zero',
    () async {
      await configure();
      await row('old-pending', '2026-01-01', pending: true);
      await row('window-pending', '2026-11-12', pending: true);
      final result = json(await read());
      expect(result['sourceUsageUnknown'], true);
      final buckets = days(result);
      expect(buckets[3]['sourceUsageUnknown'], true);
      expect(buckets[3]['recordedTokens'], '0');
      expect(buckets.first['sourceUsageUnknown'], false);
      await db.execute(
        'UPDATE usage_ledger SET source_usage_unknown=0,input_tokens=?,output_tokens=?,total_tokens=?',
        ['0', '0', '0'],
      );
      final settled = json(await read());
      expect(settled['sourceUsageUnknown'], false);
      expect(
        days(settled).every((d) => d['sourceUsageUnknown'] == false),
        true,
      );
    },
  );

  test('year leap and extreme-offset civil dates are server derived', () async {
    for (final fixture in [
      (
        at: DateTime.utc(2026, 12, 31, 10),
        offset: 840,
        start: '2026-12-26',
        end: '2027-01-01',
      ),
      (
        at: DateTime.utc(2027, 1, 1, 13, 59),
        offset: -840,
        start: '2026-12-25',
        end: '2026-12-31',
      ),
      (
        at: DateTime.utc(2028, 2, 29, 16),
        offset: 480,
        start: '2028-02-24',
        end: '2028-03-01',
      ),
    ]) {
      clock.set(fixture.at);
      tokens['owner'] = (await accounts.login(
        ids['owner']!,
        password,
        deviceName: 'time',
      )).value;
      await configure(offset: fixture.offset);
      final result = json(await read());
      expect(result['startDay'], fixture.start);
      expect(result['endDay'], fixture.end);
      expect(days(result), hasLength(7));
    }
  });

  test(
    'exact fixed-offset midnight moves range without rewriting ledger day',
    () async {
      clock.set(DateTime.utc(2026, 11, 14, 15, 59, 59));
      await configure();
      await row('start', '2026-11-08');
      expect(json(await read())['startDay'], '2026-11-08');
      clock.advance(const Duration(seconds: 1));
      final result = json(await read());
      expect(result['startDay'], '2026-11-09');
      expect(days(result).first['recordedTokens'], '0');
      expect(
        (await db.query(
          'SELECT budget_day FROM usage_ledger',
        )).single['budget_day'],
        '2026-11-08',
      );
    },
  );

  test(
    'trend computes the entire seven-day window from one clock sample',
    () async {
      await configure();
      final once = _SingleSampleClock(DateTime.utc(2026, 11, 14, 15, 59, 59));
      final result = await UsageTrend.forOwner(
        ownerId: ids['owner']!.value,
        db: db,
        clock: once,
      ).rolling7(ai);
      expect(result.isOk, isTrue);
      expect(result.value['endDay'], '2026-11-14');
      expect(once.samples, 1);
    },
  );

  test(
    'real settlement after midnight remains in the prior recorded-day bucket',
    () async {
      clock.set(DateTime.utc(2026, 11, 14, 15, 59, 59));
      final budget = UsageBudget(
        dailyTokens: 100,
        layerLimits: {
          for (final l in BudgetLayer.values)
            l: l == BudgetLayer.b2DeepChat ? 100 : 0,
        },
        capabilityLimits: {
          for (final c in ProviderCapability.values)
            c: c == ProviderCapability.chat ? 100 : 0,
        },
      );
      expect(
        (await BudgetConfiguration.forOwner(
          ownerId: ids['owner']!.value,
          db: db,
          clock: clock,
        ).configure(ai, budget, offsetMinutes: 480)).isOk,
        true,
      );
      final meter = UsageMeter.forOwner(
        ownerId: ids['owner']!.value,
        db: db,
        clock: clock,
        dayForClock: (c) => BudgetDay.fromClock(c, offsetMinutes: 480),
      );
      expect(
        (await meter.beginRequest(
          ai,
          requestId: 'cross-midnight',
          layer: BudgetLayer.b2DeepChat,
          capability: ProviderCapability.chat,
        )).isOk,
        true,
      );
      clock.advance(const Duration(seconds: 1));
      final pending = json(await read());
      expect(pending['sourceUsageUnknown'], true);
      expect(days(pending)[5]['sourceUsageUnknown'], true);
      expect(
        (await meter.recordUsage(
          ai,
          requestId: 'cross-midnight',
          layer: BudgetLayer.b2DeepChat,
          capability: ProviderCapability.chat,
          input: 3,
          output: 2,
          total: 5,
        )).isOk,
        true,
      );
      final result = json(await read());
      expect(result['sourceUsageUnknown'], false);
      expect(days(result)[5]['recordedTokens'], '5');
      expect(days(result).last['recordedTokens'], '0');
    },
  );

  test(
    'same-owner other profile cannot contribute totals or pending flags',
    () async {
      await configure();
      final owner = (await accounts.scope(tokens['owner']!.accessToken)).value;
      final account = (await owner.accounts.createAi(
        operator: ids['owner']!,
        displayName: 'second',
      )).value;
      final profile = (await AiIdentityResolver.forOwner(
        ownerId: ids['owner']!.value,
        db: db,
      ).register(account)).value.profileId;
      await row('mine', '2026-11-15');
      await row(
        'other',
        '2026-11-15',
        profile: profile.value,
        total: '100',
        input: '50',
        output: '50',
      );
      await row(
        'other-pending',
        '2026-01-01',
        profile: profile.value,
        pending: true,
      );
      final result = json(await read());
      expect(days(result).last['recordedTokens'], '5');
      expect(result['sourceUsageUnknown'], false);
    },
  );

  test(
    'operator transfer admin and profile identity boundaries hide prior data',
    () async {
      await configure();
      await row('private', '2026-11-15');
      expect((await read(actor: 'other')).status, 404);
      expect((await read(actor: 'admin')).status, 404);
      expect((await read(profile: aiAccount.value)).status, 404);
      expect((await read(profile: 'missing-profile')).status, 404);
      await db.execute('UPDATE ai_operator SET operator_id=? WHERE ai_id=?', [
        ids['other']!.value,
        aiAccount.value,
      ]);
      expect((await read()).status, 404);
      expect(json(await read(actor: 'other')), {'configurationRequired': true});
      await configure(owner: ids['other']!.value);
      expect(
        days(
          json(await read(actor: 'other')),
        ).every((d) => d['recordedTokens'] == '0'),
        true,
      );
    },
  );

  test(
    'missing timezone is explicit and caller date range owner controls are rejected',
    () async {
      expect(json(await read()), {'configurationRequired': true});
      await configure();
      await db.execute('UPDATE usage_budget SET offset_minutes=NULL');
      expect(json(await read()), {'configurationRequired': true});
      for (final query in [
        {'ownerId': ids['other']!.value},
        {'from': '2020-01-01'},
        {'offsetMinutes': '0'},
        {'days': '30'},
      ]) {
        expect((await read(query: query)).status, 400);
      }
      expect((await read(profile: 'bad id')).status, 400);
    },
  );

  test(
    'disabled active identities and stale or mismatched bearer cannot read trend',
    () async {
      await configure();
      expect((await read(anonymous: true)).status, 401);
      final principal = (await accounts.authenticate(
        tokens['owner']!.accessToken,
      ))!;
      final spoofed = Pipeline(
        router: router,
        authenticate: (_) async => principal,
      );
      expect((await read(actor: 'other', through: spoofed)).status, 401);
      final wrong = Pipeline(
        router: router,
        authenticate: (_) async =>
            Principal(accountId: principal.accountId, deviceId: 'wrong'),
      );
      expect((await read(through: wrong)).status, 401);
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', [
        aiAccount.value,
      ]);
      expect((await read()).status, 404);
      await db.execute('UPDATE account SET disabled=0 WHERE id=?', [
        aiAccount.value,
      ]);
      final fresh = (await accounts.refresh(
        tokens['owner']!.refreshToken,
      )).value;
      expect((await read()).status, 401);
      final session = (await accounts.scope(fresh.accessToken)).value;
      await session.devices.revoke(ids['owner']!, fresh.deviceId);
      expect((await read(bearer: fresh.accessToken)).status, 401);
    },
  );

  test(
    'corrupt selected counters or categories fail safely without partial trend',
    () async {
      await configure();
      await row('valid', '2026-11-15');
      for (final total in ['oops', '-5', '05', '6']) {
        await row('bad', '2026-11-14', total: total);
        final result = await read();
        expect(result.status, 500);
        expect(result.json, {'error': 'internal'});
        await db.execute('DELETE FROM usage_ledger WHERE request_id=?', [
          'bad',
        ]);
      }
      await row('bad-category', '2026-11-14', capability: 'unknown');
      expect((await read()).status, 500);
    },
  );

  test(
    'trend exposes only aggregates and performs no persisted ledger budget or audit writes',
    () async {
      await configure();
      await row('private-request', '2026-11-15');
      final before = {
        for (final table in [
          'usage_ledger',
          'usage_budget',
          'audit_log',
          'schema_migrations',
        ])
          table: await db.query('SELECT * FROM $table'),
      };
      final result = json(await read());
      expect(jsonEncode(result), isNot(contains('private-request')));
      expect(jsonEncode(result), isNot(contains(password)));
      final after = {
        for (final table in [
          'usage_ledger',
          'usage_budget',
          'audit_log',
          'schema_migrations',
        ])
          table: await db.query('SELECT * FROM $table'),
      };
      expect(jsonEncode(after), jsonEncode(before));
    },
  );
}
