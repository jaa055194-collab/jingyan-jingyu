import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/binding_matrix.dart';
import 'package:jingyu_host/src/models/binding_migrations.dart';
import 'package:jingyu_host/src/models/model_gateway.dart';
import 'package:jingyu_host/src/models/models_migrations.dart';
import 'package:jingyu_host/src/models/openai_chat_adapter.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/models/usage_meter.dart';
import 'package:jingyu_host/src/models/usage_migrations.dart';
import 'package:jingyu_host/src/security/guarded_http.dart';
import 'package:jingyu_host/src/security/url_guard.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late ProviderRegistry registry;
  late BindingMatrix bindings;
  late UsageMeter meter;
  late ModelGateway gateway;
  late String mainProvider;
  late String fastProvider;
  late Future<Result<GuardedResponse>> Function() reply;
  var calls = 0;
  final models = <String>[];
  final ai = AiId.parse('profile');
  final clock = FakeClock(DateTime.utc(2026, 11, 13));
  Future<void> Function()? beforeResolve;
  final guard = UrlGuard(
    resolver: (_) async {
      await beforeResolve?.call();
      return [InternetAddress('8.8.8.8')];
    },
  );
  final migrations = [
    ...allMigrations,
    ...accountsMigrations,
    ...modelsMigrations,
    aiIdentityMigration,
    bindingMigration,
    ...usageMigrations,
  ];
  final ownerPrivate = TrustedChatContext(
    initiator: AccountId.parse('alice'),
    conversationKind: ChatConversationKind.private,
  );
  BudgetDay day(Clock c) => BudgetDay.fromClock(c, offsetMinutes: 480);
  final adapter = OpenAiCompatibleChatAdapter.withRequest((
    method,
    uri, {
    headers = const {},
    body,
  }) async {
    calls++;
    expect(method, 'POST');
    expect(uri.toString(), 'https://models.example/v1/chat/completions');
    models.add((jsonDecode(utf8.decode(body!)) as Map)['model'] as String);
    return reply();
  });
  void compose() {
    registry = ProviderRegistry.forOwner(
      ownerId: 'alice',
      db: db,
      cipher: cipher,
      urlGuard: guard,
      clock: clock,
    );
    bindings = BindingMatrix.forOwner('alice', db);
    meter = UsageMeter.forOwner(
      ownerId: 'alice',
      db: db,
      clock: clock,
      dayForClock: day,
    );
    gateway = ModelGateway.forOwner(
      ownerId: 'alice',
      db: db,
      cipher: cipher,
      urlGuard: guard,
      clock: clock,
      dayForClock: day,
      adapter: adapter,
    );
  }

  GuardedResponse response({bool usage = true}) => GuardedResponse(
    statusCode: 200,
    headers: {},
    body: utf8.encode(
      jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'safe answer'},
          },
        ],
        if (usage)
          'usage': {
            'prompt_tokens': 3,
            'completion_tokens': 2,
            'total_tokens': 5,
          },
      }),
    ),
  );
  Future<void> configure({
    int b1 = 50,
    int b2 = 50,
    int daily = 200,
    int chat = 100,
  }) async {
    expect(
      (await meter.configure(
        ai,
        UsageBudget(
          dailyTokens: daily,
          layerLimits: {
            for (final l in BudgetLayer.values)
              l: l == BudgetLayer.b1FastBrain
                  ? b1
                  : l == BudgetLayer.b2DeepChat
                  ? b2
                  : 0,
          },
          capabilityLimits: {
            for (final c in ProviderCapability.values)
              c: c == ProviderCapability.chat
                  ? chat
                  : c == ProviderCapability.chatFast
                  ? daily - chat
                  : 0,
          },
        ),
      )).isOk,
      true,
    );
  }

  Future<Result<ChatCompletion>> chat(
    String id, {
    BudgetLayer layer = BudgetLayer.b2DeepChat,
    TrustedChatContext? context,
  }) => gateway.chat(
    ai,
    const [ChatTurn(role: 'user', content: 'hello')],
    requestId: id,
    layer: layer,
    context: context ?? ownerPrivate,
  );
  setUp(() async {
    calls = 0;
    beforeResolve = null;
    models.clear();
    reply = () async => Ok(response());
    dir = await Directory.systemTemp.createTemp('jingyu-gateway-');
    db = await SqliteDatabase.open(
      '${dir.path}/db.sqlite',
      migrations: migrations,
    );
    cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
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
    compose();
    Future<String> provider(String name, ProviderCapability cap) async =>
        (await registry.create(
          name: name,
          baseUrl: 'https://models.example/v1',
          apiKey: 'fixture-key-1234',
          capabilities: {cap},
        )).value.id;
    mainProvider = await provider('S2', ProviderCapability.chat);
    fastProvider = await provider('S1', ProviderCapability.chatFast);
    await bindings.set(
      ai,
      ProviderCapability.chat,
      providerId: mainProvider,
      model: 'S2',
    );
    await configure();
  });
  tearDown(() async {
    await db.close();
    cipher.dispose();
    await dir.delete(recursive: true);
  });

  test(
    'resolved chat settles real usage durably before returning completion',
    () async {
      final result = await chat('success');
      expect(result.value.text, 'safe answer');
      expect(calls, 1);
      expect(models, ['S2']);
      await db.close();
      db = await SqliteDatabase.open(
        '${dir.path}/db.sqlite',
        migrations: migrations,
      );
      compose();
      final row = (await db.query('SELECT * FROM usage_ledger')).single;
      expect(row['source_usage_unknown'], 0);
      expect(row['input_tokens'], '3');
      expect(row['output_tokens'], '2');
      expect(row['total_tokens'], '5');
      expect(
        (await meter.inspect(
          ai,
          layer: BudgetLayer.b2DeepChat,
          capability: ProviderCapability.chat,
        )).value.dailyUsed,
        BigInt.from(5),
      );
      expect((await chat('success')).failureOrNull?.code, FailureCode.conflict);
      expect(calls, 1);
    },
  );
  test('fast missing and disabled never fall back to S2', () async {
    expect(
      (await chat(
        'missing',
        layer: BudgetLayer.b1FastBrain,
      )).failureOrNull?.code,
      FailureCode.notFound,
    );
    await bindings.set(
      ai,
      ProviderCapability.chatFast,
      providerId: fastProvider,
      model: 'S1',
    );
    await registry.update(fastProvider, enabled: false);
    expect(
      (await chat(
        'disabled',
        layer: BudgetLayer.b1FastBrain,
      )).failureOrNull?.code,
      FailureCode.modelUnavailable,
    );
    expect(calls, 0);
    expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
  });
  test(
    'fast binding uses S1 and B1 degraded asks upstream for rule response',
    () async {
      await bindings.set(
        ai,
        ProviderCapability.chatFast,
        providerId: fastProvider,
        model: 'S1',
      );
      expect((await chat('fast', layer: BudgetLayer.b1FastBrain)).isOk, true);
      expect(models, ['S1']);
      await configure(b1: 5);
      expect(
        (await chat(
          'rule',
          layer: BudgetLayer.b1FastBrain,
        )).failureOrNull?.code,
        FailureCode.budgetExhausted,
      );
      expect(calls, 1);
    },
  );
  test('B2 degraded permits only trusted owner private context', () async {
    await configure(b2: 0);
    for (final context in [
      TrustedChatContext(
        initiator: AccountId.parse('alice'),
        conversationKind: ChatConversationKind.group,
      ),
      TrustedChatContext(
        initiator: AccountId.parse('bob'),
        conversationKind: ChatConversationKind.private,
      ),
      TrustedChatContext(
        initiator: AccountId.parse('bob'),
        conversationKind: ChatConversationKind.group,
      ),
    ]) {
      expect(
        (await chat(
          'denied-${context.initiator.value}-${context.conversationKind.name}',
          context: context,
        )).failureOrNull?.code,
        FailureCode.budgetExhausted,
      );
    }
    expect(calls, 0);
    expect((await chat('owner')).isOk, true);
    expect(calls, 1);
  });
  test('daily and capability hard stops also block owner private', () async {
    await configure(b1: 0, b2: 5, daily: 5, chat: 5);
    expect((await chat('last')).isOk, true);
    expect(
      (await chat('hard')).failureOrNull?.code,
      FailureCode.budgetExhausted,
    );
    await configure(b1: 0, b2: 5, daily: 100, chat: 5);
    expect(
      (await chat('cap')).failureOrNull?.code,
      FailureCode.budgetExhausted,
    );
    expect(calls, 1);
  });
  test(
    'budget configuration is mandatory and unsupported layers reject',
    () async {
      await db.execute('DELETE FROM usage_budget');
      expect(
        (await chat(
          'no-budget',
        )).failureOrNull?.details['configurationRequired'],
        true,
      );
      for (final layer in [
        BudgetLayer.b0Life,
        BudgetLayer.b3Proactive,
        BudgetLayer.b4Maintenance,
      ]) {
        expect(
          (await chat(
            'unsupported-${layer.name}',
            layer: layer,
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
      expect(calls, 0);
    },
  );
  test(
    'credential authentication failure occurs before pending begin',
    () async {
      await db.execute(
        "UPDATE providers SET encrypted_key='corrupt' WHERE id=?",
        [mainProvider],
      );
      expect((await chat('bad-key')).failureOrNull?.code, FailureCode.internal);
      expect(calls, 0);
      expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );
  test(
    'invalid turns are rejected without outbound or pending usage',
    () async {
      final result = await gateway.chat(
        ai,
        const [],
        requestId: 'invalid',
        layer: BudgetLayer.b2DeepChat,
        context: ownerPrivate,
      );
      expect(result.failureOrNull?.code, FailureCode.invalidArgument);
      expect(calls, 0);
      expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );
  test(
    'simultaneous duplicate starts never issue two provider calls',
    () async {
      final results = await Future.wait([
        chat('simultaneous'),
        chat('simultaneous'),
      ]);
      expect(results.where((r) => r.isOk).length, 1);
      expect(
        results
            .where((r) => r.failureOrNull?.code == FailureCode.conflict)
            .length,
        1,
      );
      expect(calls, 1);
    },
  );
  test('unknown storage errors propagate to host internal boundary', () async {
    await db.close();
    await expectLater(chat('closed-storage'), throwsStateError);
    expect(calls, 0);
  });
  for (final scenario in [
    'b1-owner-private',
    'b2-owner-group',
    'b2-other-private',
    'b2-owner-private',
  ]) {
    test(
      'begin rechecks layer changed during URL preflight: $scenario',
      () async {
        await bindings.set(
          ai,
          ProviderCapability.chatFast,
          providerId: fastProvider,
          model: 'S1',
        );
        final layer = scenario.startsWith('b1')
            ? BudgetLayer.b1FastBrain
            : BudgetLayer.b2DeepChat;
        final context = TrustedChatContext(
          initiator: AccountId.parse(
            scenario.contains('other') ? 'bob' : 'alice',
          ),
          conversationKind: scenario.endsWith('group')
              ? ChatConversationKind.group
              : ChatConversationKind.private,
        );
        final entered = Completer<void>();
        final release = Completer<void>();
        beforeResolve = () async {
          entered.complete();
          await release.future;
        };
        final pending = chat('layer-race', layer: layer, context: context);
        await entered.future;
        await configure(
          b1: layer == BudgetLayer.b1FastBrain ? 0 : 50,
          b2: layer == BudgetLayer.b2DeepChat ? 0 : 50,
        );
        release.complete();
        final result = await pending;
        if (scenario == 'b2-owner-private') {
          expect(result.isOk, true);
          expect(calls, 1);
        } else {
          expect(result.failureOrNull?.code, FailureCode.budgetExhausted);
          expect(calls, 0);
          expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
        }
      },
    );
  }
  test('legacy invalid model rejects before pending begin', () async {
    await db.execute(
      "UPDATE model_bindings SET model=' S2 ' WHERE capability='chat'",
    );
    final result = await chat('legacy-model');
    expect(result.failureOrNull?.code, FailureCode.invalidArgument);
    expect(calls, 0);
    expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
  });
  test('current operator change rejects an existing gateway', () async {
    await db.execute("UPDATE ai_operator SET operator_id='bob'");
    expect((await chat('moved')).failureOrNull?.code, FailureCode.notFound);
    expect(calls, 0);
  });
  for (final missingUsage in [false, true]) {
    test(
      '${missingUsage ? 'missing usage' : 'provider failure'} stays pending for reconciliation across restart',
      () async {
        reply = missingUsage
            ? () async => Ok(response(usage: false))
            : () async => err(FailureCode.unavailable, 'secret upstream body');
        final result = await chat('unknown');
        expect(result.isErr, true);
        expect(result.failureOrNull?.details['sourceUsageUnknown'], true);
        expect(result.failureOrNull?.details['reconciliationRequired'], true);
        expect(
          result.failureOrNull.toString(),
          isNot(contains('secret upstream body')),
        );
        await db.close();
        db = await SqliteDatabase.open(
          '${dir.path}/db.sqlite',
          migrations: migrations,
        );
        compose();
        final row = (await db.query('SELECT * FROM usage_ledger')).single;
        expect(row['source_usage_unknown'], 1);
        expect(row['total_tokens'], isNull);
        expect(
          (await chat('unknown')).failureOrNull?.code,
          FailureCode.conflict,
        );
        expect(
          (await chat('another')).failureOrNull?.code,
          FailureCode.unavailable,
        );
        expect(calls, 1);
      },
    );
  }
  test(
    'concurrent same request performs exactly one outbound request',
    () async {
      final entered = Completer<void>();
      final release = Completer<Result<GuardedResponse>>();
      reply = () {
        entered.complete();
        return release.future;
      };
      final first = chat('same');
      await entered.future;
      final second = await chat('same');
      expect(second.failureOrNull?.code, FailureCode.conflict);
      release.complete(Ok(response()));
      expect((await first).isOk, true);
      expect(calls, 1);
      expect((await db.query('SELECT * FROM usage_ledger')).length, 1);
    },
  );
}
