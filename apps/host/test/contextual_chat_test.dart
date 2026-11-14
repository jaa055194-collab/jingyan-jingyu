import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/ai/context/context_assembler.dart';
import 'package:jingyu_host/src/ai/context/contextual_chat.dart';
import 'package:jingyu_host/src/ai/persona/persona_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_service.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/binding_matrix.dart';
import 'package:jingyu_host/src/models/binding_migrations.dart';
import 'package:jingyu_host/src/models/budget_configuration.dart';
import 'package:jingyu_host/src/models/budget_timezone_migration.dart';
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
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late String providerId;
  late int providerCalls;
  late List<Map<String, Object?>> receivedMessages;
  final ai = AiId.parse('profile');
  final clock = FakeClock(DateTime.utc(2026, 11, 13, 20));
  final guard = UrlGuard(resolver: (_) async => [InternetAddress('8.8.8.8')]);
  final migrations = [
    ...allMigrations,
    ...accountsMigrations,
    ...modelsMigrations,
    aiIdentityMigration,
    bindingMigration,
    ...usageMigrations,
    budgetTimezoneMigration,
    ...personaMigrations,
  ];
  final trusted = TrustedChatContext(
    initiator: AccountId.parse('alice'),
    conversationKind: ChatConversationKind.private,
    scopeKey: 'private:alice:profile',
  );
  late ContextualChat chat;

  OpenAiCompatibleChatAdapter adapter() =>
      OpenAiCompatibleChatAdapter.withRequest((
        method,
        uri, {
        headers = const {},
        body,
      }) async {
        providerCalls++;
        final payload = jsonDecode(utf8.decode(body!)) as Map<String, dynamic>;
        receivedMessages = (payload['messages'] as List)
            .cast<Map<String, Object?>>();
        expect(payload['max_tokens'], 9);
        return Ok(
          GuardedResponse(
            statusCode: 200,
            headers: const {},
            body: utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': 'safe completion',
                    },
                  },
                ],
                'usage': {
                  'prompt_tokens': 17,
                  'completion_tokens': 3,
                  'total_tokens': 20,
                },
              }),
            ),
          ),
        );
      });

  ContextualChat compose({
    int modelWindow = 40,
    int outputReserve = 9,
    int safetyReserve = 4,
    TokenCounter? tokenCounter,
    String? profileProviderId,
    String? profileModel,
  }) => ContextualChat(
    db: db,
    cipher: cipher,
    clock: clock,
    urlGuard: guard,
    adapter: adapter(),
    profile: ContextualChatProfile(
      providerId: profileProviderId ?? providerId,
      model: profileModel ?? 'chat-model',
      system: 'Answer helpfully.',
      modelWindow: modelWindow,
      outputReserve: outputReserve,
      safetyReserve: safetyReserve,
      tokenCounter: tokenCounter ?? (messages) => messages.length,
    ),
  );

  Future<void> configureModel() async {
    await BudgetConfiguration.forOwner(
      ownerId: 'alice',
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
    providerId =
        (await ProviderRegistry.forOwner(
              ownerId: 'alice',
              db: db,
              cipher: cipher,
              urlGuard: guard,
              clock: clock,
            ).create(
              name: 'Chat',
              baseUrl: 'https://models.example/v1',
              apiKey: 'context-test-key',
              capabilities: {ProviderCapability.chat},
            ))
            .value
            .id;
    expect(
      (await BindingMatrix.forOwner('alice', db).set(
        ai,
        ProviderCapability.chat,
        providerId: providerId,
        model: 'chat-model',
      )).isOk,
      isTrue,
    );
  }

  Future<void> initializePersona() async {
    final persona = SqlitePersonaService.forOwner(
      ownerId: 'alice',
      actorAccountId: 'alice',
      database: db,
      cipher: cipher,
      clock: clock,
    );
    final result = await persona.initialize(
      ai,
      initial: PersonaLayers(
        p0: {'identity': 'Nora'},
        p1: {'style': 'warm'},
        p2: {'mood': 'calm'},
      ),
    );
    expect(result.isOk, isTrue);
  }

  Future<Result<ContextualChatCompletion>> ask({
    String owner = 'alice',
    ContextScope? scope,
    String requestId = 'request-1',
    int outputReserve = 9,
    int safetyReserve = 4,
  }) => chat.chat(
    ownerId: owner,
    ai: ai,
    scope:
        scope ??
        const ContextScope(
          aiProfileId: 'profile',
          scopeKey: 'private:alice:profile',
        ),
    context: trusted,
    requestId: requestId,
    layer: BudgetLayer.b2DeepChat,
    currentTurn: const ChatTurn(role: 'user', content: 'Hello'),
    history: const [],
    maxHistoryTurns: 3,
    summaries: const [],
    maxSummaries: 2,
    memoryHits: const [],
    memoryTopK: 4,
    memoryScoreThreshold: 0,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('contextual-chat-');
    db = await SqliteDatabase.open(
      '${directory.path}/chat.sqlite',
      migrations: migrations,
    );
    cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
    providerCalls = 0;
    receivedMessages = [];
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
    await configureModel();
    chat = compose();
  });

  tearDown(() async {
    await db.close();
    cipher.dispose();
    await directory.delete(recursive: true);
  });

  test('sends active saved P0/P1/P2 persona as fixed system context', () async {
    await initializePersona();
    final result = await ask();

    expect(result.isOk, isTrue);
    expect(result.value.completion.text, 'safe completion');
    expect(result.value.totalTokens, 20);
    expect(result.value.inputTokens, 17);
    expect(result.value.outputTokens, 3);
    expect(result.value.assembled.totalTokens, 3);
    expect(receivedMessages.take(2).toList(), [
      {'role': 'system', 'content': 'Answer helpfully.'},
      {
        'role': 'system',
        'content':
            '{"p0":{"identity":"Nora"},"p1":{"style":"warm"},"p2":{"mood":"calm"}}',
      },
    ]);
    final saved = await SqlitePersonaService.forOwner(
      ownerId: 'alice',
      actorAccountId: 'alice',
      database: db,
      cipher: cipher,
      clock: clock,
    ).current(ai);
    expect(saved.value.version, 1);
    expect(saved.value.layers.p0['identity'], 'Nora');
  });

  test('profile identifiers accept ordinary token characters', () async {
    await initializePersona();
    chat = compose(
      profileProviderId: 'provider_v2-123',
      profileModel: 'model.v1',
    );

    final result = await ask(requestId: 'ordinary-profile-ids');

    expect(result.failureOrNull?.code, FailureCode.conflict);
    expect(providerCalls, 0);
    expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
  });

  test(
    'profile identifiers with controls fail before model invocation',
    () async {
      await initializePersona();
      chat = compose(profileProviderId: 'provider\nother');

      final result = await ask(requestId: 'control-profile-id');

      expect(result.failureOrNull?.code, FailureCode.invalidArgument);
      expect(providerCalls, 0);
      expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );

  test('missing persona fails before provider call or pending usage', () async {
    final result = await ask();

    expect(result.failureOrNull?.code, FailureCode.notFound);
    expect(providerCalls, 0);
    expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
  });

  test(
    'foreign owner persona access fails before provider call or usage',
    () async {
      await initializePersona();
      final result = await ask(owner: 'bob', requestId: 'foreign-owner');

      expect(result.failureOrNull?.code, FailureCode.notFound);
      expect(providerCalls, 0);
      expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );

  test('foreign scope is rejected before model invocation', () async {
    await initializePersona();
    final result = await ask(
      scope: const ContextScope(
        aiProfileId: 'profile',
        scopeKey: 'private:someone-else',
      ),
    );

    expect(result.failureOrNull?.code, FailureCode.invalidArgument);
    expect(providerCalls, 0);
    expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
  });

  test(
    'fixed context overflow fails before provider call or usage creation',
    () async {
      await initializePersona();
      chat = compose(
        modelWindow: 13,
        outputReserve: 9,
        safetyReserve: 4,
        tokenCounter: (messages) => messages.length,
      );
      final result = await ask(requestId: 'overflow');

      expect(result.failureOrNull?.code, FailureCode.budgetExhausted);
      expect(providerCalls, 0);
      expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );

  test(
    'invalid reserves and token windows fail closed without provider calls',
    () async {
      await initializePersona();
      chat = compose(modelWindow: 10, outputReserve: 0, safetyReserve: 0);
      final result = await ask(requestId: 'invalid-profile');

      expect(result.failureOrNull?.code, FailureCode.invalidArgument);
      expect(providerCalls, 0);
      expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );

  test(
    'changed model binding rejects stale tokenizer profile before provider call',
    () async {
      await initializePersona();
      expect(
        (await BindingMatrix.forOwner('alice', db).set(
          ai,
          ProviderCapability.chat,
          providerId: providerId,
          model: 'replacement-model',
        )).isOk,
        isTrue,
      );

      final result = await ask(requestId: 'stale-model-profile');

      expect(result.failureOrNull?.code, FailureCode.conflict);
      expect(providerCalls, 0);
      expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );

  test(
    'caller authorization flags remain external and unauthorized recall is omitted',
    () async {
      await initializePersona();
      final result = await chat.chat(
        ownerId: 'alice',
        ai: ai,
        scope: const ContextScope(
          aiProfileId: 'profile',
          scopeKey: 'private:alice:profile',
        ),
        context: trusted,
        requestId: 'unauthorized-recall',
        layer: BudgetLayer.b2DeepChat,
        currentTurn: const ChatTurn(role: 'user', content: 'Hello'),
        history: const [],
        maxHistoryTurns: 3,
        summaries: [
          ContextSummary(
            id: 'pending-summary',
            text: 'must not be included',
            provenance: ContextProvenance(
              scope: const ContextScope(
                aiProfileId: 'profile',
                scopeKey: 'private:alice:profile',
              ),
              sourceAccountId: 'alice',
              sourceMessageIds: const ['message-1'],
            ),
            authorized: false,
          ),
        ],
        maxSummaries: 2,
        memoryHits: const [],
        memoryTopK: 4,
        memoryScoreThreshold: 0,
      );

      expect(result.isOk, isTrue);
      expect(result.value.assembled.omittedSummaryIds, ['pending-summary']);
      expect(
        jsonEncode(receivedMessages),
        isNot(contains('must not be included')),
      );
    },
  );
}
