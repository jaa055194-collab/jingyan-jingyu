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
import 'package:jingyu_host/src/security/url_guard.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
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
  const password = 'usage-summary-test-password';

  Future<void> configure({int offset = 480}) async {
    final result =
        await BudgetConfiguration.forOwner(
          ownerId: ids['owner']!.value,
          db: db,
          clock: clock,
        ).configure(
          ai,
          UsageBudget(
            dailyTokens: 100,
            layerLimits: {
              for (final l in BudgetLayer.values)
                l: l == BudgetLayer.b2DeepChat ? 100 : 0,
            },
            capabilityLimits: {
              for (final c in ProviderCapability.values)
                c: c == ProviderCapability.chat ? 100 : 0,
            },
          ),
          offsetMinutes: offset,
        );
    expect(result.isOk, isTrue);
  }

  Future<void> ledger(
    String id, {
    String day = '2026-11-15',
    String? owner,
    String? profile,
    String layer = 'b2DeepChat',
    String capability = 'chat',
    String? input = '3',
    String? output = '2',
    String? total = '5',
    bool unknown = false,
    int offset = 480,
  }) => db.execute(
    'INSERT INTO usage_ledger(owner_id,ai_id,request_id,budget_day,offset_minutes,layer,capability,input_tokens,output_tokens,total_tokens,source_usage_unknown) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
    [
      owner ?? ids['owner']!.value,
      profile ?? ai.value,
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
    String actor = 'owner',
    bool anonymous = false,
    String? bearer,
    String? profile,
    Map<String, String> query = const {},
    Pipeline? through,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: 'GET',
      path: '/api/v1/ai-profiles/${profile ?? ai.value}/usage',
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
    directory = await Directory.systemTemp.createTemp('usage-summary-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
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
      hasher: _FastHasher(),
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
    final services = HostServices()
      ..provide<AccountsDomain>(accounts, owner: 'accounts')
      ..provide<AuditLog>(InMemoryAuditLog(), owner: 'system');
    final module = ModelsModule(
      db: db,
      cipher: cipher,
      urlGuard: UrlGuard(),
      clock: clock,
    );
    await module.configure(services);
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
    'today summary is mounted and returns exact zero maps for configured owner',
    () async {
      await configure();
      final result = json(await read());
      expect(result.keys.toSet(), {
        'budgetDay',
        'offsetMinutes',
        'recordedTokens',
        'byLayer',
        'byCapability',
        'sourceUsageUnknown',
      });
      expect(result['budgetDay'], '2026-11-15');
      expect(result['offsetMinutes'], 480);
      expect(result['recordedTokens'], '0');
      expect(result['byLayer'], {
        'b0Life': '0',
        'b1FastBrain': '0',
        'b2DeepChat': '0',
        'b3Proactive': '0',
        'b4Maintenance': '0',
      });
      expect(result['byCapability'], {
        'chat': '0',
        'chatFast': '0',
        'vision': '0',
        'imageGen': '0',
        'tts': '0',
        'asr': '0',
        'embedding': '0',
      });
      expect(
        (result['sourceUsageUnknown'] as Map).values.every((v) => v == false),
        isTrue,
      );
    },
  );

  test(
    'missing and legacy timezone require configuration without fabricated zero',
    () async {
      expect(json(await read()), {'configurationRequired': true});
      await configure();
      await db.execute('UPDATE usage_budget SET offset_minutes = NULL');
      expect(json(await read()), {'configurationRequired': true});
    },
  );

  test(
    'settled usage aggregates across layers capabilities and overage without admission gating',
    () async {
      await configure();
      await ledger('a', input: '70', output: '50', total: '120');
      await ledger(
        'b',
        layer: 'b1FastBrain',
        capability: 'chatFast',
        input: '3',
        output: '4',
        total: '7',
      );
      await ledger(
        'yesterday',
        day: '2026-11-14',
        input: '100',
        output: '100',
        total: '200',
      );
      await ledger(
        'zero',
        layer: 'b0Life',
        capability: 'vision',
        input: '0',
        output: '0',
        total: '0',
      );
      final result = json(await read());
      expect(result['recordedTokens'], '127');
      expect((result['byLayer'] as Map)['b2DeepChat'], '120');
      expect((result['byLayer'] as Map)['b1FastBrain'], '7');
      expect((result['byCapability'] as Map)['chat'], '120');
      expect((result['byCapability'] as Map)['vision'], '0');
    },
  );

  test(
    'pending usage from older days is flagged without pretending it is settled zero',
    () async {
      await configure();
      await ledger(
        'old-pending',
        day: '2026-11-14',
        capability: 'chatFast',
        unknown: true,
      );
      await ledger('new-pending', capability: 'chat', unknown: true);
      await ledger('known');
      final result = json(await read());
      expect(result['recordedTokens'], '5');
      final unknown = result['sourceUsageUnknown'] as Map;
      expect(unknown['chat'], isTrue);
      expect(unknown['chatFast'], isTrue);
      expect(unknown['vision'], isFalse);
    },
  );

  test(
    'BigInt counters remain exact beyond int64 and JavaScript precision',
    () async {
      await configure();
      await ledger(
        'one',
        input: '9223372036854775807',
        output: '0',
        total: '9223372036854775807',
      );
      await ledger(
        'two',
        input: '9223372036854775807',
        output: '0',
        total: '9223372036854775807',
      );
      final result = json(await read());
      expect(result['recordedTokens'], '18446744073709551614');
      expect((result['byCapability'] as Map)['chat'], '18446744073709551614');
      expect(jsonEncode(result), contains('"18446744073709551614"'));
    },
  );

  test(
    'ownership isolation has no admin bypass and uses profile not account IDs',
    () async {
      await configure();
      await ledger('visible');
      expect((await read(actor: 'other')).status, 404);
      expect((await read(actor: 'admin')).status, 404);
      expect((await read(profile: aiAccount.value)).status, 404);
      expect((await read(profile: 'missing-profile')).status, 404);
      await db.execute(
        'UPDATE ai_operator SET operator_id = ? WHERE ai_id = ?',
        [ids['other']!.value, aiAccount.value],
      );
      expect((await read()).status, 404);
      expect(json(await read(actor: 'other')), {'configurationRequired': true});
      await BudgetConfiguration.forOwner(
        ownerId: ids['other']!.value,
        db: db,
        clock: clock,
      ).configure(
        ai,
        UsageBudget(
          dailyTokens: 100,
          layerLimits: {for (final l in BudgetLayer.values) l: 0},
          capabilityLimits: {for (final c in ProviderCapability.values) c: 0},
        ),
        offsetMinutes: 480,
      );
      expect(json(await read(actor: 'other'))['recordedTokens'], '0');
    },
  );

  test('disabled AI or operator cannot read its old usage', () async {
    await configure();
    await db.execute('UPDATE account SET disabled = 1 WHERE id = ?', [
      aiAccount.value,
    ]);
    expect((await read()).status, 404);
    await db.execute('UPDATE account SET disabled = 0 WHERE id = ?', [
      aiAccount.value,
    ]);
    await db.execute('UPDATE account SET disabled = 1 WHERE id = ?', [
      ids['owner']!.value,
    ]);
    expect((await read()).status, 401);
  });

  test(
    'clock and persisted timezone choose day without rewriting historical rows',
    () async {
      await configure(offset: 0);
      await ledger('old', day: '2026-11-14', offset: 0);
      await ledger(
        'new',
        day: '2026-11-15',
        offset: 0,
        input: '6',
        output: '4',
        total: '10',
      );
      expect(json(await read())['budgetDay'], '2026-11-14');
      expect(json(await read())['recordedTokens'], '5');
      await configure(offset: 480);
      expect(json(await read())['budgetDay'], '2026-11-15');
      // Offset in the row is not an extra filter: existing gate uses the day key.
      expect(json(await read())['recordedTokens'], '10');
      clock.advance(const Duration(minutes: 1));
      expect(json(await read())['recordedTokens'], '10');
    },
  );

  test(
    'fixed-offset midnight changes the displayed day exactly once',
    () async {
      clock.set(DateTime.utc(2026, 11, 14, 15, 59, 59));
      await configure();
      await ledger('before', day: '2026-11-14');
      await ledger('after', input: '4', output: '4', total: '8');
      expect(json(await read())['budgetDay'], '2026-11-14');
      expect(json(await read())['recordedTokens'], '5');
      clock.advance(const Duration(seconds: 1));
      expect(json(await read())['budgetDay'], '2026-11-15');
      expect(json(await read())['recordedTokens'], '8');
    },
  );

  test('settlement after midnight stays on the request start day', () async {
    clock.set(DateTime.utc(2026, 11, 14, 15, 59, 59));
    await configure();
    final meter = UsageMeter.forOwner(
      ownerId: ids['owner']!.value,
      db: db,
      clock: clock,
      dayForClock: (c) => BudgetDay.fromClock(c, offsetMinutes: 480),
    );
    final begun = await meter.beginRequest(
      ai,
      requestId: 'cross-midnight',
      layer: BudgetLayer.b2DeepChat,
      capability: ProviderCapability.chat,
    );
    expect(begun.isOk, isTrue);
    clock.advance(const Duration(seconds: 1));
    expect((json(await read())['sourceUsageUnknown'] as Map)['chat'], isTrue);
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
      isTrue,
    );
    final result = json(await read());
    expect(result['recordedTokens'], '0');
    expect((result['sourceUsageUnknown'] as Map)['chat'], isFalse);
    expect(
      (await db.query(
        'SELECT budget_day FROM usage_ledger WHERE request_id=?',
        ['cross-midnight'],
      )).single['budget_day'],
      '2026-11-14',
    );
  });

  test(
    'another profile of the same operator cannot contribute totals or unknown flags',
    () async {
      await configure();
      final owner = (await accounts.scope(tokens['owner']!.accessToken)).value;
      final secondAccount = (await owner.accounts.createAi(
        operator: ids['owner']!,
        displayName: 'Second AI',
      )).value;
      final secondProfile = (await AiIdentityResolver.forOwner(
        ownerId: ids['owner']!.value,
        db: db,
      ).register(secondAccount)).value.profileId;
      await ledger('mine');
      await ledger(
        'other-settled',
        profile: secondProfile.value,
        input: '50',
        output: '50',
        total: '100',
      );
      await ledger(
        'other-pending',
        profile: secondProfile.value,
        capability: 'chatFast',
        unknown: true,
      );
      final result = json(await read());
      expect(result['recordedTokens'], '5');
      expect((result['sourceUsageUnknown'] as Map)['chatFast'], isFalse);
    },
  );

  test(
    'requests cannot supply another owner day or offset; malformed profile rejected',
    () async {
      await configure();
      for (final query in [
        {'ownerId': ids['other']!.value},
        {'day': '2026-11-14'},
        {'offsetMinutes': '0'},
      ]) {
        expect((await read(query: query)).status, 400);
      }
      expect((await read(profile: 'bad id')).status, 400);
    },
  );

  test(
    'anonymous stale and mismatched principal credentials are rejected',
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
        authenticate: (_) async => Principal(
          accountId: principal.accountId,
          deviceId: 'wrong',
          isAdmin: true,
        ),
      );
      expect((await read(through: wrong)).status, 401);
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
    'summary is read-only and excludes request IDs and private payload',
    () async {
      await configure();
      await ledger('private-request-id');
      final before = jsonEncode(
        await db.query('SELECT * FROM usage_ledger ORDER BY request_id'),
      );
      final result = json(await read());
      expect(jsonEncode(result), isNot(contains('private-request-id')));
      expect(jsonEncode(result), isNot(contains(password)));
      expect(
        jsonEncode(
          await db.query('SELECT * FROM usage_ledger ORDER BY request_id'),
        ),
        before,
      );
    },
  );

  test(
    'corrupt stored counters and enum values fail closed without partial output',
    () async {
      await configure();
      await ledger('valid');
      for (final total in ['bad', '-5', '+5', '05', '6']) {
        await ledger('corrupt', input: '3', output: '2', total: total);
        final broken = await read();
        expect(broken.status, 500, reason: 'counter=$total');
        expect(broken.json, {'error': 'internal'});
        await db.execute('DELETE FROM usage_ledger WHERE request_id = ?', [
          'corrupt',
        ]);
      }
      await ledger('bad-layer', layer: 'not-a-layer');
      expect((await read()).status, 500);
      await db.execute('DELETE FROM usage_ledger WHERE request_id = ?', [
        'bad-layer',
      ]);
      await ledger('bad-capability', capability: 'not-a-capability');
      expect((await read()).status, 500);
    },
  );
}
