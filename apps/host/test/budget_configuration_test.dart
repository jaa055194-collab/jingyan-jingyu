import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/audit/audit_log.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/budget_configuration.dart';
import 'package:jingyu_host/src/models/budget_routes.dart';
import 'package:jingyu_host/src/models/budget_timezone_migration.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/models/usage_meter.dart';
import 'package:jingyu_host/src/models/usage_migrations.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

class _FastHasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String password) async => 'test:$password';
  @override
  Future<bool> verifyAsync(String password, String encodedHash) async =>
      encodedHash == 'test:$password';
}

void main() {
  late Directory dir;
  late SqliteDatabase db;
  late FakeClock clock;
  late AccountsDomain accounts;
  late String token;
  late String otherToken;
  late AccountId owner;
  late AccountId other;
  late AccountId aiAccount;
  late AiId ai;
  late Pipeline pipeline;
  late Router router;
  late InMemoryAuditLog audit;
  const password = 'budget-fixture-password';
  final migrations = [
    ...allMigrations,
    ...accountsMigrations,
    aiIdentityMigration,
    ...usageMigrations,
    budgetTimezoneMigration,
  ];
  BudgetConfiguration service([String? ownerId]) =>
      BudgetConfiguration.forOwner(
        ownerId: ownerId ?? owner.value,
        db: db,
        clock: clock,
      );
  UsageBudget budget({int daily = 100}) => UsageBudget(
    dailyTokens: daily,
    layerLimits: {
      for (final l in BudgetLayer.values)
        l: l == BudgetLayer.b2DeepChat ? 100 : 0,
    },
    capabilityLimits: {
      for (final c in ProviderCapability.values)
        c: c == ProviderCapability.chat ? 100 : 0,
    },
  );
  Map<String, Object?> body() => {
    'dailyTokens': 100,
    'layerLimits': {
      for (final l in BudgetLayer.values)
        l.name: l == BudgetLayer.b2DeepChat ? 100 : 0,
    },
    'capabilityLimits': {
      for (final c in ProviderCapability.values)
        c.name: c == ProviderCapability.chat ? 100 : 0,
    },
    'offsetMinutes': 480,
  };
  Future<HostResponse> call(String method, {Object? input, String? bearer}) =>
      pipeline.handle(
        HostRequest(
          method: method,
          path: '/api/v1/ai-profiles/${ai.value}/budget',
          headers: {'authorization': 'Bearer ${bearer ?? token}'},
          body: input,
        ),
      );
  UsageMeter meter(int offset) => UsageMeter.forOwner(
    ownerId: owner.value,
    db: db,
    clock: clock,
    dayForClock: (c) => BudgetDay.fromClock(c, offsetMinutes: offset),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('budget-configuration-');
    db = await SqliteDatabase.open(
      '${dir.path}/db.sqlite',
      migrations: migrations,
    );
    clock = FakeClock(DateTime.utc(2026, 11, 13, 16));
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    owner = (await accounts.bootstrapAdmin(
      displayName: 'Owner',
      password: password,
    )).value;
    token = (await accounts.login(
      owner,
      password,
      deviceName: 'Owner',
    )).value.accessToken;
    final session = (await accounts.scope(token)).value;
    other = (await session.accounts.createHuman(
      displayName: 'Other',
      password: password,
    )).value;
    otherToken = (await accounts.login(
      other,
      password,
      deviceName: 'Other',
    )).value.accessToken;
    aiAccount = (await session.accounts.createAi(
      operator: owner,
      displayName: 'AI',
    )).value;
    ai = (await AiIdentityResolver.forOwner(
      ownerId: owner.value,
      db: db,
    ).register(aiAccount)).value.profileId;
    audit = InMemoryAuditLog(clock: clock);
    router = Router();
    mountBudgetRoutes(
      router,
      db: db,
      clock: clock,
      accounts: accounts,
      audit: audit,
    );
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(accounts).call,
    );
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('missing and legacy timezone require explicit configuration', () async {
    expect(
      (await service().get(ai)).failureOrNull?.details['configurationRequired'],
      true,
    );
    await meter(480).configure(ai, budget());
    expect(
      (await db.query(
        'SELECT offset_minutes FROM usage_budget',
      )).single['offset_minutes'],
      isNull,
    );
    expect(
      (await service().get(ai)).failureOrNull?.details['configurationRequired'],
      true,
    );
    expect(
      (await service().configure(ai, budget(), offsetMinutes: 0)).isOk,
      true,
    );
    expect((await service().get(ai)).value.offsetMinutes, 0);
  });

  test(
    'upgrade preserves old budgets with null timezone and enforces offset bounds',
    () async {
      final legacy = await SqliteDatabase.open(
        '${dir.path}/legacy.sqlite',
        migrations: migrations.where((m) => m.version < 504).toList(),
      );
      await legacy.execute(
        "INSERT INTO account VALUES ('human','Human','human',0,0,'hash',0,0)",
      );
      await legacy.execute(
        "INSERT INTO account VALUES ('ai','AI','ai',0,0,NULL,0,0)",
      );
      await legacy.execute("INSERT INTO ai_operator VALUES ('ai','human')");
      await legacy.execute("INSERT INTO ai_profile VALUES ('profile','ai')");
      await UsageMeter.forOwner(
        ownerId: 'human',
        db: legacy,
        clock: clock,
        dayForClock: (c) => BudgetDay.fromClock(c, offsetMinutes: 480),
      ).configure(AiId.parse('profile'), budget());
      await legacy.close();
      final upgraded = await SqliteDatabase.open(
        '${dir.path}/legacy.sqlite',
        migrations: migrations,
      );
      try {
        final rows = await upgraded.query('SELECT * FROM usage_budget');
        expect(rows.single['daily_tokens'], '100');
        expect(rows.single['offset_minutes'], isNull);
        for (final offset in [-841, 841, 0.5]) {
          await expectLater(
            upgraded.execute('UPDATE usage_budget SET offset_minutes=?', [
              offset,
            ]),
            throwsA(isA<Exception>()),
          );
        }
      } finally {
        await upgraded.close();
      }
    },
  );

  test(
    'configuration persists limits and explicit timezone across restart',
    () async {
      expect(
        (await service().configure(ai, budget(), offsetMinutes: -840)).isOk,
        true,
      );
      await db.close();
      db = await SqliteDatabase.open(
        '${dir.path}/db.sqlite',
        migrations: migrations,
      );
      final view = (await service().get(ai)).value;
      expect(view.offsetMinutes, -840);
      expect(view.budget.dailyTokens, 100);
      expect(view.budget.layerLimits[BudgetLayer.b2DeepChat], 100);
      expect(view.budget.capabilityLimits[ProviderCapability.chat], 100);
    },
  );

  test(
    'invalid limits and offsets leave all configuration columns unchanged',
    () async {
      await service().configure(ai, budget(), offsetMinutes: 480);
      final before = await db.query('SELECT * FROM usage_budget');
      for (final invalid in [
        budget(daily: -1),
        budget(daily: 99),
        UsageBudget(dailyTokens: 100, layerLimits: {}, capabilityLimits: {}),
      ]) {
        expect(
          (await service().configure(
            ai,
            invalid,
            offsetMinutes: 0,
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
      for (final offset in [-841, 841]) {
        expect(
          (await service().configure(
            ai,
            budget(daily: 200),
            offsetMinutes: offset,
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
      expect(await db.query('SELECT * FROM usage_budget'), before);
    },
  );

  test('a failed SQL upsert rolls back every budget field', () async {
    await service().configure(ai, budget(), offsetMinutes: 480);
    final before = await db.query('SELECT * FROM usage_budget');
    await db.execute('''
CREATE TRIGGER reject_budget_update BEFORE UPDATE ON usage_budget
WHEN NEW.offset_minutes=0 BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;
''');
    await expectLater(
      service().configure(ai, budget(daily: 200), offsetMinutes: 0),
      throwsA(isA<Exception>()),
    );
    expect(await db.query('SELECT * FROM usage_budget'), before);
  });

  test(
    'current active owner and AI are rechecked for read and write',
    () async {
      expect(
        (await service(
          other.value,
        ).configure(ai, budget(), offsetMinutes: 480)).failureOrNull?.code,
        FailureCode.notFound,
      );
      await service().configure(ai, budget(), offsetMinutes: 480);
      for (final id in [owner.value, aiAccount.value]) {
        await db.execute('UPDATE account SET disabled=1 WHERE id=?', [id]);
        expect(
          (await service().get(ai)).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await service().configure(
            ai,
            budget(),
            offsetMinutes: 0,
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        await db.execute('UPDATE account SET disabled=0 WHERE id=?', [id]);
      }
      await db.execute('UPDATE ai_operator SET operator_id=? WHERE ai_id=?', [
        other.value,
        aiAccount.value,
      ]);
      expect(
        (await service().get(ai)).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await service().configure(
          ai,
          budget(),
          offsetMinutes: 0,
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await service(
          other.value,
        ).get(ai)).failureOrNull?.details['configurationRequired'],
        true,
      );
    },
  );

  test(
    'timezone change keeps settled and pending usage and uses new civil day',
    () async {
      await service().configure(ai, budget(), offsetMinutes: 480);
      final oldMeter = meter(480);
      await oldMeter.beginRequest(
        ai,
        requestId: 'settled',
        layer: BudgetLayer.b2DeepChat,
        capability: ProviderCapability.chat,
      );
      await oldMeter.recordUsage(
        ai,
        requestId: 'settled',
        layer: BudgetLayer.b2DeepChat,
        capability: ProviderCapability.chat,
        input: 20,
        output: 10,
        total: 30,
      );
      await oldMeter.beginRequest(
        ai,
        requestId: 'pending',
        layer: BudgetLayer.b2DeepChat,
        capability: ProviderCapability.chat,
      );
      final before = await db.query(
        'SELECT * FROM usage_ledger ORDER BY request_id',
      );
      await service().configure(ai, budget(), offsetMinutes: 0);
      expect(
        await db.query('SELECT * FROM usage_ledger ORDER BY request_id'),
        before,
      );
      expect(
        (await meter(0).inspect(
          ai,
          layer: BudgetLayer.b2DeepChat,
          capability: ProviderCapability.chat,
        )).failureOrNull?.details['sourceUsageUnknown'],
        true,
      );
      await oldMeter.recordUsage(
        ai,
        requestId: 'pending',
        layer: BudgetLayer.b2DeepChat,
        capability: ProviderCapability.chat,
        input: 0,
        output: 0,
        total: 0,
      );
      final gate = (await meter(0).inspect(
        ai,
        layer: BudgetLayer.b2DeepChat,
        capability: ProviderCapability.chat,
      )).value;
      expect(gate.day.date, '2026-11-13');
      expect(gate.dailyUsed, BigInt.zero);
      expect(
        (await oldMeter.inspect(
          ai,
          layer: BudgetLayer.b2DeepChat,
          capability: ProviderCapability.chat,
        )).value.dailyUsed,
        BigInt.from(30),
      );
    },
  );

  test(
    'HTTP returns safe complete budget and audits only safe metadata',
    () async {
      final saved = await call('PUT', input: body());
      expect(saved.status, 200);
      final loaded = await call('GET');
      expect(loaded.status, 200);
      expect(loaded.json, body());
      expect(audit.entries, hasLength(1));
      expect(audit.entries.single.actorId, owner.value);
      expect(audit.entries.single.targetId, ai.value);
      expect(audit.entries.single.meta, {'offsetMinutes': 480});
      expect((await call('GET', bearer: otherToken)).status, 404);
      expect(
        (await call('PUT', input: body(), bearer: otherToken)).status,
        404,
      );
      expect(audit.entries, hasLength(1));
    },
  );

  test(
    'HTTP rejects incomplete maps, nonintegers, extras and invalid sums without writes',
    () async {
      final invalid = <Object?>[
        null,
        [],
        {},
        {...body(), 'offsetMinutes': null},
        {...body(), 'offsetMinutes': 841},
        {...body(), 'offsetMinutes': 0.0},
        {...body(), 'dailyTokens': '100'},
        {...body(), 'dailyTokens': -1},
        {...body(), 'dailyTokens': 99},
        {...body(), 'ownerId': owner.value},
        {...body(), 'layerLimits': {}},
        {...body(), 'capabilityLimits': {}},
        {
          ...body(),
          'layerLimits': {...(body()['layerLimits'] as Map), 'unknown': 0},
        },
        {
          ...body(),
          'capabilityLimits': {
            ...(body()['capabilityLimits'] as Map),
            'chat': 1.5,
          },
        },
        {
          ...body(),
          'capabilityLimits': {
            ...(body()['capabilityLimits'] as Map),
            'chat': -1,
          },
        },
      ];
      for (final input in invalid) {
        expect((await call('PUT', input: input)).status, 400, reason: '$input');
      }
      expect(await db.query('SELECT * FROM usage_budget'), isEmpty);
      expect(audit.entries, isEmpty);
    },
  );

  test(
    'HTTP revalidates bearer and binds it to middleware principal',
    () async {
      final principal = (await accounts.authenticate(token))!;
      pipeline = Pipeline(router: router, authenticate: (_) async => principal);
      expect(
        (await call('PUT', input: body(), bearer: otherToken)).status,
        401,
      );
      final session = (await accounts.scope(token)).value;
      final devices = await session.devices.list(owner);
      await session.devices.revoke(owner, devices.single.id);
      expect((await call('GET')).status, 401);
      expect((await call('PUT', input: body())).status, 401);
      expect(await db.query('SELECT * FROM usage_budget'), isEmpty);
    },
  );
}
