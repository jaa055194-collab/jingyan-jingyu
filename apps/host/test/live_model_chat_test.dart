// Opt-in live integration test for the real-model chat chain.
//
// This exercises the same composition the host uses for an owner private chat:
//   stored persona -> ContextAssembler -> ModelRuntime -> ModelGateway
//   -> ProviderRegistry (encrypted credential) -> UrlGuard
//   -> OpenAiCompatibleChatAdapter -> real HTTPS provider.
//
// Credentials are injected only through the environment at run time and are
// never stored in the repository. When JINGYU_LIVE_BASE_URL and
// JINGYU_LIVE_API_KEY are absent the group is skipped, so offline CI stays
// secret-free. JINGYU_LIVE_MODEL defaults to "auto".
//
// Local run (PowerShell), injecting the key only into this process:
//   $env:JINGYU_LIVE_BASE_URL = 'https://api.hcnsec.cn/v1'
//   $env:JINGYU_LIVE_API_KEY  = '<injected locally, never committed>'
//   $env:JINGYU_LIVE_MODEL    = 'auto'
//   dart test test/live_model_chat_test.dart -r expanded
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
  final liveBaseUrl =
      Platform.environment['JINGYU_LIVE_BASE_URL']?.trim() ?? '';
  final liveApiKey = Platform.environment['JINGYU_LIVE_API_KEY'] ?? '';
  final liveModel = Platform.environment['JINGYU_LIVE_MODEL']?.trim() ?? '';
  final hasCredentials = liveBaseUrl.isNotEmpty && liveApiKey.trim().isNotEmpty;
  final model = liveModel.isNotEmpty ? liveModel : 'auto';

  group(
    'live model chat',
    () {
      late Directory directory;
      late SqliteDatabase db;
      late AesGcmColumnCipher cipher;
      late String providerId;
      late ContextualChat chat;
      final ai = AiId.parse('profile');
      final clock = FakeClock(DateTime.utc(2026, 11, 16, 2));
      final guard = UrlGuard();
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

      setUp(() async {
        directory = await Directory.systemTemp.createTemp('live-model-chat-');
        db = await SqliteDatabase.open(
          '${directory.path}/chat.sqlite',
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
        providerId =
            (await ProviderRegistry.forOwner(
                  ownerId: 'alice',
                  db: db,
                  cipher: cipher,
                  urlGuard: guard,
                  clock: clock,
                ).create(
                  name: 'Live',
                  baseUrl: liveBaseUrl,
                  apiKey: liveApiKey,
                  capabilities: {ProviderCapability.chat},
                ))
                .value
                .id;
        expect(
          (await BindingMatrix.forOwner('alice', db).set(
            ai,
            ProviderCapability.chat,
            providerId: providerId,
            model: model,
          )).isOk,
          isTrue,
        );
        expect(
          (await SqlitePersonaService.forOwner(
            ownerId: 'alice',
            actorAccountId: 'alice',
            database: db,
            cipher: cipher,
            clock: clock,
          ).initialize(
            ai,
            initial: PersonaLayers(
              p0: {'identity': 'Nora'},
              p1: {'style': 'warm and concise'},
              p2: {'mood': 'calm'},
            ),
          )).isOk,
          isTrue,
        );
        chat = ContextualChat(
          db: db,
          cipher: cipher,
          clock: clock,
          urlGuard: guard,
          adapter: OpenAiCompatibleChatAdapter(GuardedHttpTransport()),
          profile: ContextualChatProfile(
            providerId: providerId,
            model: model,
            system: 'You are a concise assistant. Answer in one short sentence.',
            modelWindow: 8192,
            outputReserve: 256,
            safetyReserve: 256,
            tokenCounter: (messages) =>
                messages.fold(0, (sum, m) => sum + m.content.length ~/ 4 + 4),
          ),
        );
      });

      tearDown(() async {
        await db.close();
        cipher.dispose();
        await directory.delete(recursive: true);
      });

      test('returns a real assistant reply through the chat chain', () async {
        final result = await chat.chat(
          ownerId: 'alice',
          ai: ai,
          scope: const ContextScope(
            aiProfileId: 'profile',
            scopeKey: 'private:alice:profile',
          ),
          context: trusted,
          requestId: 'live-request-1',
          layer: BudgetLayer.b2DeepChat,
          currentTurn: const ChatTurn(role: 'user', content: '用一句话回答：1+1等于几？'),
          history: const [],
          maxHistoryTurns: 3,
          summaries: const [],
          maxSummaries: 2,
          memoryHits: const [],
          memoryTopK: 4,
          memoryScoreThreshold: 0,
        );

        if (result case Err<ContextualChatCompletion>(:final failure)) {
          fail('provider call failed: ${failure.code}');
        }
        final value = result.value;
        expect(value.text.trim().isNotEmpty, isTrue);
        expect(value.totalTokens, value.inputTokens + value.outputTokens);
        // Deliberately print only normalized, non-secret completion fields.
        print('LIVE_REPLY="${value.text}"');
        print('LIVE_USAGE input=${value.inputTokens} output=${value.outputTokens} total=${value.totalTokens}');
      });
    },
    skip: hasCredentials
        ? false
        : 'live model credentials not provided '
              '(set JINGYU_LIVE_BASE_URL and JINGYU_LIVE_API_KEY)',
  );
}
