import 'dart:convert';
import 'dart:io';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_service.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/binding_matrix.dart';
import 'package:jingyu_host/src/models/binding_migrations.dart';
import 'package:jingyu_host/src/models/budget_configuration.dart';
import 'package:jingyu_host/src/models/budget_timezone_migration.dart';
import 'package:jingyu_host/src/models/model_runtime.dart';
import 'package:jingyu_host/src/models/models_migrations.dart';
import 'package:jingyu_host/src/models/openai_chat_adapter.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/models/stateless_owner_chat.dart';
import 'package:jingyu_host/src/models/usage_meter.dart';
import 'package:jingyu_host/src/models/usage_migrations.dart';
import 'package:jingyu_host/src/security/guarded_http.dart';
import 'package:jingyu_host/src/security/url_guard.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late StatelessOwnerChat facade;
  late String provider;
  var calls = 0, status = 200;
  var text = '你😀';
  final ai = AiId.parse('profile');
  final clock = FakeClock(DateTime.utc(2026, 11, 17));
  final guard = UrlGuard(resolver: (_) async => [InternetAddress('8.8.8.8')]);

  Future<Result<ChatCompletion>> ask({
    String model = 'chat-model',
    String? expectedProvider,
    String requestId = 'request',
  }) => facade.chat(
    ownerId: 'owner',
    ai: ai,
    conversationId: 'direct',
    requestId: requestId,
    system: 'System',
    input: 'Hello',
    expectedProviderId: expectedProvider ?? provider,
    expectedModel: model,
    maxTokens: 32,
  );

  setUp(() async {
    db = await SqliteDatabase.open(
      ':memory:',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...modelsMigrations,
        aiIdentityMigration,
        bindingMigration,
        ...usageMigrations,
        budgetTimezoneMigration,
        ...personaMigrations,
        privateConversationMigration,
      ],
    );
    cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
    await db.execute(
      "INSERT INTO account VALUES('owner','Owner','human',0,0,'synthetic',0,0)",
    );
    await db.execute("INSERT INTO account VALUES('ai','AI','ai',0,0,NULL,0,0)");
    await db.execute("INSERT INTO ai_operator VALUES('ai','owner')");
    await db.execute("INSERT INTO ai_profile VALUES('profile','ai')");
    await db.execute(
      "INSERT INTO direct_conversations VALUES('direct','ai','owner',0)",
    );
    await SqlitePersonaService.forOwner(
      ownerId: 'owner',
      actorAccountId: 'owner',
      database: db,
      cipher: cipher,
      clock: clock,
    ).initialize(
      ai,
      initial: PersonaLayers(
        p0: {'name': 'Nora'},
        p1: {'style': 'warm'},
        p2: {'mood': 'calm'},
      ),
    );
    await BudgetConfiguration.forOwner(
      ownerId: 'owner',
      db: db,
      clock: clock,
    ).configure(
      ai,
      UsageBudget(
        dailyTokens: 100,
        layerLimits: {
          for (final layer in BudgetLayer.values)
            layer: layer == BudgetLayer.b2DeepChat ? 100 : 0,
        },
        capabilityLimits: {
          for (final cap in ProviderCapability.values)
            cap: cap == ProviderCapability.chat ? 100 : 0,
        },
      ),
      offsetMinutes: 480,
    );
    // Only a synthetic credential in this in-memory fixture. No existing config/key reads.
    provider =
        (await ProviderRegistry.forOwner(
              ownerId: 'owner',
              db: db,
              cipher: cipher,
              urlGuard: guard,
              clock: clock,
            ).create(
              name: 'Synthetic',
              baseUrl: 'https://models.example/v1',
              apiKey: 'synthetic-test-only',
              capabilities: {ProviderCapability.chat},
            ))
            .value
            .id;
    await BindingMatrix.forOwner('owner', db).set(
      ai,
      ProviderCapability.chat,
      providerId: provider,
      model: 'chat-model',
    );
    calls = 0;
    status = 200;
    text = '你😀';
    final runtime = ModelRuntime(
      db: db,
      cipher: cipher,
      urlGuard: guard,
      clock: clock,
      adapter: OpenAiCompatibleChatAdapter.withRequest((
        method,
        uri, {
        headers = const {},
        body,
      }) async {
        calls++;
        final payload = jsonDecode(utf8.decode(body!)) as Map;
        expect(payload['model'], 'chat-model');
        expect(payload['max_tokens'], 32);
        expect((payload['messages'] as List).length, 2);
        return Ok(
          GuardedResponse(
            statusCode: status,
            headers: const {},
            body: utf8.encode(
              jsonEncode(
                status == 200
                    ? {
                        'choices': [
                          {
                            'message': {'role': 'assistant', 'content': text},
                          },
                        ],
                        'usage': {
                          'prompt_tokens': 2,
                          'completion_tokens': 3,
                          'total_tokens': 5,
                        },
                      }
                    : {
                        'error': {
                          'message': 'synthetic provider detail not exposed',
                        },
                      },
              ),
            ),
          ),
        );
      }),
    );
    facade = StatelessOwnerChat.fromRuntime(
      db: db,
      cipher: cipher,
      clock: clock,
      runtime: runtime,
      maxOutputBytes: 7,
    );
  });
  tearDown(() async {
    await db.close();
    cipher.dispose();
  });

  test(
    'runtime pin mismatch prevents provider call and ledger creation',
    () async {
      expect(
        (await ask(model: 'changed')).failureOrNull?.code,
        FailureCode.conflict,
      );
      expect(calls, 0);
      expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );

  test(
    'expected provider mismatch makes no provider call or usage entry',
    () async {
      expect(
        (await ask(expectedProvider: 'different-provider')).failureOrNull?.code,
        FailureCode.conflict,
      );
      expect(calls, 0);
      expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );

  test(
    'output overflow is rejected only after real runtime settled usage',
    () async {
      text = '你😀a';
      expect((await ask()).failureOrNull?.code, FailureCode.modelUnavailable);
      expect(calls, 1);
      final ledger = (await db.query('SELECT * FROM usage_ledger')).single;
      expect(ledger['source_usage_unknown'], 0);
      expect(ledger['total_tokens'], '5');
      expect((await ask()).failureOrNull?.code, FailureCode.conflict);
      expect(calls, 1);
    },
  );

  test(
    'non200 is generic safe unavailable and pending usage is not retried',
    () async {
      status = 400;
      final result = await ask();
      expect(result.failureOrNull?.code, FailureCode.modelUnavailable);
      expect(
        result.failureOrNull!.message.contains('synthetic provider detail'),
        isFalse,
      );
      expect(result.failureOrNull!.details['sourceUsageUnknown'], isTrue);
      expect(
        (await db.query(
          'SELECT * FROM usage_ledger',
        )).single['source_usage_unknown'],
        1,
      );
      expect((await ask()).failureOrNull?.code, FailureCode.conflict);
      expect(calls, 1);
    },
  );

  test(
    'budget hard stop remains enforced by runtime with no provider call',
    () async {
      await db.execute("UPDATE usage_budget SET daily_tokens='0'");
      expect((await ask()).failureOrNull?.code, FailureCode.budgetExhausted);
      expect(calls, 0);
    },
  );
}
