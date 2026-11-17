// Regression for the trusted provider chat chain wiring.
//
// Proves ProviderRegistry -> BindingMatrix -> ModelRuntime -> ModelGateway ->
// UrlGuard -> OpenAiCompatibleChatAdapter is wired correctly WITHOUT any network:
// a valid OpenAI-compatible 200 payload yields Ok; non-200 / malformed payloads
// map to the documented failures. This isolates "provider returned bad status or
// shape" from "the host trusted chain cannot reach the adapter", and never reads,
// prints or commits a real provider key.
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
import 'package:jingyu_host/src/models/model_gateway.dart';
import 'package:jingyu_host/src/models/model_runtime.dart';
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

/// Public IP literal avoids any DNS lookup; the fake transport never dials it.
const _baseUrl = 'https://93.184.216.34/v1';
const _syntheticKey = 'sk-probe-synthetic-not-a-real-key';
const _replyText = 'OK';

Map<String, Object?> _body() => {
  'choices': [
    {
      'message': {'role': 'assistant', 'content': _replyText},
    },
  ],
  'usage': {'prompt_tokens': 5, 'completion_tokens': 2, 'total_tokens': 7},
};

class _Captured {
  _Captured(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int>? body;
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late ModelRuntime runtime;
  late List<_Captured> captured;
  final ai = AiId.parse('profile');
  final clock = FakeClock(DateTime.utc(2026, 11, 17, 2));
  final guard = UrlGuard();
  late GuardedChatRequest transport;

  Future<Result<GuardedResponse>> respond(int status, Object? jsonBody) async =>
      Ok<GuardedResponse>(
        GuardedResponse(
          statusCode: status,
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: utf8.encode(jsonEncode(jsonBody)),
        ),
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('provider-chain-');
    db = await SqliteDatabase.open(
      '${directory.path}/chain.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...modelsMigrations,
        aiIdentityMigration,
        bindingMigration,
        ...usageMigrations,
        budgetTimezoneMigration,
        ...personaMigrations,
      ],
    );
    cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
    await db.execute(
      "INSERT INTO account VALUES ('alice', 'alice', 'human', 0, 0, 'hash', 0, 0)",
    );
    await db.execute(
      "INSERT INTO account VALUES ('principal', 'AI', 'ai', 0, 0, NULL, 0, 0)",
    );
    await db.execute("INSERT INTO ai_operator VALUES ('principal', 'alice')");
    await db.execute("INSERT INTO ai_profile VALUES ('profile', 'principal')");
    await BudgetConfiguration.forOwner(
      ownerId: 'alice',
      db: db,
      clock: clock,
    ).configure(
      ai,
      UsageBudget(
        dailyTokens: 1000000,
        layerLimits: {
          for (final layer in BudgetLayer.values)
            layer: layer == BudgetLayer.b2DeepChat ? 1000000 : 0,
        },
        capabilityLimits: {
          for (final cap in ProviderCapability.values)
            cap: cap == ProviderCapability.chat ? 1000000 : 0,
        },
      ),
      offsetMinutes: 480,
    );
    final providerId =
        (await ProviderRegistry.forOwner(
              ownerId: 'alice',
              db: db,
              cipher: cipher,
              urlGuard: guard,
              clock: clock,
            ).create(
              name: 'Chain',
              baseUrl: _baseUrl,
              apiKey: _syntheticKey,
              capabilities: {ProviderCapability.chat},
            ))
            .value
            .id;
    await BindingMatrix.forOwner(
      'alice',
      db,
    ).set(ai, ProviderCapability.chat, providerId: providerId, model: 'auto');
    captured = <_Captured>[];
    transport =
        (method, uri, {headers = const <String, String>{}, body}) async {
          captured.add(_Captured(method, uri, headers, body));
          return switch (transportBehavior) {
            'ok' => respond(200, _body()),
            'missing_usage' => respond(200, {'choices': []}),
            '404' => respond(404, {'error': 'not found'}),
            '401' => respond(401, {'error': 'unauthorized'}),
            _ => respond(500, {'error': 'boom'}),
          };
        };
    runtime = ModelRuntime(
      db: db,
      cipher: cipher,
      urlGuard: guard,
      clock: clock,
      adapter: OpenAiCompatibleChatAdapter.withRequest(transport),
    );
  });

  tearDown(() async {
    await db.close();
    cipher.dispose();
    await directory.delete(recursive: true);
  });

  Future<Result<ChatCompletion>> call(String requestId) => runtime.chat(
    ownerId: 'alice',
    ai: ai,
    turns: const [
      ChatTurn(role: 'user', content: 'Reply with the word OK only.'),
    ],
    requestId: requestId,
    layer: BudgetLayer.b2DeepChat,
    context: TrustedChatContext(
      initiator: AccountId.parse('alice'),
      conversationKind: ChatConversationKind.private,
      scopeKey: 'private:alice:profile',
    ),
    maxTokens: 8,
  );

  test(
    'trusted chain reaches a valid 200 completion and sends one POST',
    () async {
      transportBehavior = 'ok';
      final result = await call('chain-ok-1');
      expect(result.isOk, isTrue, reason: result.failureOrNull?.code.name);
      final value = result.value;
      expect(value.text, _replyText);
      expect(value.totalTokens, 7);

      final call_ = captured.single;
      expect(call_.method, 'POST');
      expect(call_.uri.path, '/v1/chat/completions');
      // Synthetic test key only; a real key is never used in this test.
      expect(call_.headers['authorization'], 'Bearer $_syntheticKey');
      final payload =
          jsonDecode(utf8.decode(call_.body!)) as Map<String, Object?>;
      expect(payload['model'], 'auto');
      expect(payload['stream'], false);
      expect(payload['max_tokens'], 8);
    },
  );

  test(
    'persona + budget + provider + binding assembly composes before chat',
    () async {
      transportBehavior = 'ok';
      // Persona is part of the PR#92 client write contract set; a chain that
      // carries a persona must still reach the provider and record usage.
      final persona =
          await SqlitePersonaService.forOwner(
            ownerId: 'alice',
            actorAccountId: 'alice',
            database: db,
            cipher: cipher,
            clock: clock,
          ).initialize(
            ai,
            initial: PersonaLayers(
              p0: const {'name': 'Nora'},
              p1: const {'style': 'warm and concise'},
              p2: const {'mood': 'calm'},
            ),
          );
      expect(persona.isOk, isTrue);
      final loaded = await SqlitePersonaService.forOwner(
        ownerId: 'alice',
        actorAccountId: 'alice',
        database: db,
        cipher: cipher,
        clock: clock,
      ).current(ai);
      expect(loaded.isOk, isTrue);
      expect(loaded.value.layers.p0, {'name': 'Nora'});

      final result = await call('chain-persona-1');
      expect(result.isOk, isTrue, reason: result.failureOrNull?.code.name);
      expect(result.value.text, _replyText);
      expect((await db.query('SELECT * FROM usage_ledger')), hasLength(1));
    },
  );

  test('404 provider response maps to modelUnavailable', () async {
    transportBehavior = '404';
    final result = await call('chain-404-1');
    expect(result.failureOrNull?.code, FailureCode.modelUnavailable);
  });

  test('401 provider response maps to forbidden', () async {
    transportBehavior = '401';
    final result = await call('chain-401-1');
    expect(result.failureOrNull?.code, FailureCode.forbidden);
  });

  test('malformed 200 payload maps to modelUnavailable', () async {
    transportBehavior = 'missing_usage';
    final result = await call('chain-bad-1');
    expect(result.failureOrNull?.code, FailureCode.modelUnavailable);
  });
}

// Simple per-test switch read inside the fake transport closure.
String transportBehavior = 'ok';
