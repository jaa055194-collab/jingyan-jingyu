import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/models/usage_meter.dart';
import 'package:jingyu_host/src/models/usage_migrations.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late SqliteDatabase db;
  late FakeClock clock;
  late UsageMeter meter;
  final ai = AiId.parse('profile');
  const layer = BudgetLayer.b2DeepChat;
  const cap = ProviderCapability.chat;
  final migrations = [
    ...allMigrations,
    ...accountsMigrations,
    aiIdentityMigration,
    ...usageMigrations,
  ];
  UsageMeter scoped(String owner) => UsageMeter.forOwner(
    ownerId: owner,
    db: db,
    clock: clock,
    dayForClock: (c) => BudgetDay.fromClock(c, offsetMinutes: 480),
  );
  UsageBudget budget({
    int daily = 100,
    int layerLimit = 50,
    int capLimit = 100,
  }) => UsageBudget(
    dailyTokens: daily,
    layerLimits: {
      for (final l in BudgetLayer.values) l: l == layer ? layerLimit : 0,
    },
    capabilityLimits: {
      for (final c in ProviderCapability.values) c: c == cap ? capLimit : 0,
    },
  );
  Future<Result<UsageGate>> inspect() =>
      meter.inspect(ai, layer: layer, capability: cap);
  Future<Result<UsageRequest>> begin(String id) =>
      meter.beginRequest(ai, requestId: id, layer: layer, capability: cap);
  Future<Result<void>> record(String id, int input, int output, int total) =>
      meter.recordUsage(
        ai,
        requestId: id,
        layer: layer,
        capability: cap,
        input: input,
        output: output,
        total: total,
      );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jingyu-usage-');
    db = await SqliteDatabase.open(
      '${dir.path}/db.sqlite',
      migrations: migrations,
    );
    clock = FakeClock(DateTime.utc(2026, 11, 13, 15, 59));
    for (final owner in ['alice', 'bob']) {
      await db.execute(
        "INSERT INTO account VALUES (?, ?, 'human', 0, 0, 'hash', 0, 0)",
        [owner, owner],
      );
    }
    await db.execute(
      "INSERT INTO account VALUES ('principal', 'AI', 'ai', 0, 0, NULL, 0, 0)",
    );
    await db.execute("INSERT INTO ai_operator VALUES ('principal', 'alice')");
    await db.execute("INSERT INTO ai_profile VALUES ('profile', 'principal')");
    meter = scoped('alice');
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('explicit day validates calendar, timezone and trusted midnight', () {
    expect(BudgetDay.fromClock(clock, offsetMinutes: 480).date, '2026-11-13');
    clock.advance(const Duration(minutes: 1));
    expect(BudgetDay.fromClock(clock, offsetMinutes: 480).date, '2026-11-14');
    for (final date in ['2026-02-30', '2026-1-01', '0000-01-01']) {
      expect(
        () => BudgetDay(date: date, offsetMinutes: 0),
        throwsArgumentError,
      );
    }
    expect(
      () => BudgetDay(date: '2026-01-01', offsetMinutes: 841),
      throwsArgumentError,
    );
    expect(
      () => BudgetDay(date: '2026-01-01', offsetMinutes: -841),
      throwsArgumentError,
    );
  });
  test(
    'unconfigured is explicit and owner/current operator is checked',
    () async {
      expect(
        (await inspect()).failureOrNull?.code,
        FailureCode.budgetExhausted,
      );
      expect(
        (await inspect()).failureOrNull?.details['configurationRequired'],
        true,
      );
      expect(
        (await scoped('bob').configure(ai, budget())).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect((await meter.configure(ai, budget())).isOk, true);
      await db.execute("UPDATE ai_operator SET operator_id = 'bob'");
      expect((await inspect()).failureOrNull?.code, FailureCode.notFound);
      expect((await begin('denied')).failureOrNull?.code, FailureCode.notFound);
      expect(
        (await record('denied', 1, 1, 2)).failureOrNull?.code,
        FailureCode.notFound,
      );
    },
  );
  test(
    'configuration rejects negative, missing and overflow-safe sums',
    () async {
      final bad = [
        budget(daily: -1),
        budget(layerLimit: -1),
        budget(capLimit: -1),
        budget(layerLimit: 101),
        UsageBudget(dailyTokens: 100, layerLimits: {}, capabilityLimits: {}),
        UsageBudget(
          dailyTokens: 9223372036854775807,
          layerLimits: {
            for (final l in BudgetLayer.values) l: 9223372036854775807,
          },
          capabilityLimits: {for (final c in ProviderCapability.values) c: 0},
        ),
      ];
      for (final b in bad) {
        expect(
          (await meter.configure(ai, b)).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
    },
  );
  test(
    'begin atomically rejects layer reduced after normal inspection',
    () async {
      await meter.configure(ai, budget());
      expect((await inspect()).value.degradeLevel, DegradeLevel.normal);
      await meter.configure(ai, budget(layerLimit: 0));
      expect(
        (await begin('stale-policy')).failureOrNull?.code,
        FailureCode.budgetExhausted,
      );
      expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );
  test(
    'B1 rejects when another settled request exhausts layer after inspect',
    () async {
      const fastLayer = BudgetLayer.b1FastBrain;
      await meter.configure(
        ai,
        UsageBudget(
          dailyTokens: 100,
          layerLimits: {
            for (final l in BudgetLayer.values) l: l == fastLayer ? 20 : 0,
          },
          capabilityLimits: {
            for (final c in ProviderCapability.values) c: c == cap ? 100 : 0,
          },
        ),
      );
      expect(
        (await meter.inspect(
          ai,
          layer: fastLayer,
          capability: cap,
        )).value.degradeLevel,
        DegradeLevel.normal,
      );
      await meter.beginRequest(
        ai,
        requestId: 'other',
        layer: fastLayer,
        capability: cap,
      );
      await meter.recordUsage(
        ai,
        requestId: 'other',
        layer: fastLayer,
        capability: cap,
        input: 10,
        output: 10,
        total: 20,
      );
      expect(
        (await meter.beginRequest(
          ai,
          requestId: 'stale-fast',
          layer: fastLayer,
          capability: cap,
        )).failureOrNull?.code,
        FailureCode.budgetExhausted,
      );
      expect((await db.query('SELECT * FROM usage_ledger')).length, 1);
    },
  );
  test(
    '80 percent warns and layer 100 returns degradation for gateway policy',
    () async {
      await meter.configure(ai, budget());
      await begin('a');
      await record('a', 10, 30, 40);
      expect((await inspect()).value.degradeLevel, DegradeLevel.warn);
      await begin('b');
      await record('b', 5, 5, 10);
      expect((await inspect()).value.degradeLevel, DegradeLevel.degraded);
      expect(
        (await begin('public-degraded')).failureOrNull?.code,
        FailureCode.budgetExhausted,
      );
      expect(
        (await meter.beginRequest(
          ai,
          requestId: 'owner-private',
          layer: layer,
          capability: cap,
          allowDegradedLayer: true,
        )).isOk,
        true,
      );
      await record('owner-private', 25, 25, 50);
      expect(
        (await meter.beginRequest(
          ai,
          requestId: 'hard-stopped',
          layer: layer,
          capability: cap,
          allowDegradedLayer: true,
        )).failureOrNull?.code,
        FailureCode.budgetExhausted,
      );
    },
  );
  test('capability and daily 100 hard stop only subsequent calls', () async {
    await meter.configure(ai, budget(layerLimit: 100, capLimit: 60));
    await begin('a');
    await record('a', 30, 30, 60);
    expect((await begin('c')).failureOrNull?.code, FailureCode.budgetExhausted);
    expect((await record('a', 30, 30, 60)).isOk, true);
    await meter.configure(ai, budget(daily: 60, layerLimit: 60, capLimit: 60));
    expect((await inspect()).failureOrNull?.code, FailureCode.budgetExhausted);
  });
  test(
    'missing provider usage remains unknown, never free or invented',
    () async {
      await meter.configure(ai, budget());
      await begin('pending');
      expect((await inspect()).failureOrNull?.code, FailureCode.unavailable);
      expect(
        (await inspect()).failureOrNull?.details['sourceUsageUnknown'],
        true,
      );
      expect(
        (await begin('more')).failureOrNull?.code,
        FailureCode.unavailable,
      );
      final row = (await db.query('SELECT * FROM usage_ledger')).single;
      expect(row['total_tokens'], isNull);
      expect(row['source_usage_unknown'], 1);
      expect(
        (await record('never-started', 1, 1, 2)).failureOrNull?.code,
        FailureCode.notFound,
      );
    },
  );
  test(
    'provider usage validates nonnegative exact sums without int overflow',
    () async {
      await meter.configure(ai, budget());
      await begin('x');
      for (final amounts in [
        [-1, 1, 0],
        [1, -1, 0],
        [1, 1, -1],
        [1, 1, 3],
        [9223372036854775807, 1, -9223372036854775808],
      ]) {
        expect(
          (await record(
            'x',
            amounts[0],
            amounts[1],
            amounts[2],
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
      expect((await record('x', 0, 0, 0)).isOk, true);
      expect((await inspect()).value.sourceUsageUnknown, false);
    },
  );
  test(
    'durable unique request fixes start day across midnight and restart',
    () async {
      await meter.configure(ai, budget());
      await begin('x');
      clock.advance(const Duration(minutes: 2));
      expect((await record('x', 10, 10, 20)).isOk, true);
      expect((await inspect()).value.dailyUsed, BigInt.zero);
      await db.close();
      db = await SqliteDatabase.open(
        '${dir.path}/db.sqlite',
        migrations: migrations,
      );
      meter = scoped('alice');
      expect((await record('x', 10, 10, 20)).isOk, true);
      expect(
        (await record('x', 11, 9, 20)).failureOrNull?.code,
        FailureCode.conflict,
      );
      final retried = await begin('x');
      expect(retried.value.day.date, '2026-11-13');
      expect(retried.value.sourceUsageUnknown, false);
      expect((await db.query('SELECT * FROM usage_ledger')).length, 1);
    },
  );
  test(
    'concurrent starts fail closed and concurrent first settlement is unique',
    () async {
      await meter.configure(ai, budget());
      final starts = await Future.wait([begin('one'), begin('two')]);
      expect(starts.where((r) => r.isOk).length, 1);
      expect(
        starts
            .where((r) => r.failureOrNull?.code == FailureCode.unavailable)
            .length,
        1,
      );
      final id = starts.firstWhere((r) => r.isOk).value.requestId;
      final settled = await Future.wait(
        List.generate(20, (_) => record(id, 2, 3, 5)),
      );
      expect(settled.every((r) => r.isOk), true);
      expect((await inspect()).value.dailyUsed, BigInt.from(5));
      expect(
        (await meter.beginRequest(
          ai,
          requestId: id,
          layer: BudgetLayer.b0Life,
          capability: cap,
        )).failureOrNull?.code,
        FailureCode.conflict,
      );
      expect(
        (await meter.recordUsage(
          ai,
          requestId: id,
          layer: layer,
          capability: ProviderCapability.vision,
          input: 2,
          output: 3,
          total: 5,
        )).failureOrNull?.code,
        FailureCode.conflict,
      );
    },
  );
  test(
    'in flight overage is recorded and aggregate never wraps int64',
    () async {
      await meter.configure(
        ai,
        budget(
          daily: 9223372036854775807,
          layerLimit: 9223372036854775807,
          capLimit: 9223372036854775807,
        ),
      );
      await begin('first');
      await record('first', 9223372036854775805, 0, 9223372036854775805);
      await begin('over');
      expect((await record('over', 10, 0, 10)).isOk, true);
      expect(
        (await inspect()).failureOrNull?.code,
        FailureCode.budgetExhausted,
      );
      final rows = await db.query('SELECT total_tokens FROM usage_ledger');
      expect(
        rows.fold<BigInt>(
          BigInt.zero,
          (s, r) => s + BigInt.parse(r['total_tokens'] as String),
        ),
        BigInt.parse('9223372036854775815'),
      );
    },
  );
  test(
    'concurrent accounting is exact and duplicate settlement does not add',
    () async {
      await meter.configure(
        ai,
        budget(daily: 1000, layerLimit: 1000, capLimit: 1000),
      );
      for (var i = 0; i < 30; i++) {
        await begin('r$i');
        await record('r$i', 2, 3, 5);
      }
      final results = await Future.wait(
        List.generate(60, (i) => record('r${i % 30}', 2, 3, 5)),
      );
      expect(results.every((r) => r.isOk), true);
      expect((await inspect()).value.dailyUsed, BigInt.from(150));
      expect((await inspect()).value.layerUsed, BigInt.from(150));
      expect((await inspect()).value.capabilityUsed, BigInt.from(150));
    },
  );
}
