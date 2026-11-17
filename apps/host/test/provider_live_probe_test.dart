// Env-gated live probe for the trusted model runtime.
//
// This is a single bounded, real OpenAI-compatible chat completion through the
// same trusted composition the host uses:
//   ProviderRegistry (encrypted credential) -> BindingMatrix
//   -> ModelRuntime -> ModelGateway -> UrlGuard
//   -> OpenAiCompatibleChatAdapter -> real HTTPS provider.
//
// It only runs when a chat-capable provider is supplied via the environment:
//   JINGYU_LIVE_BASE_URL  (OpenAI-compatible base, e.g. https://host/v1)
//   JINGYU_LIVE_API_KEY   (injected locally; never committed or logged)
//   JINGYU_LIVE_MODEL     (optional, defaults to "auto")
// When the variables are absent the test is SKIPPED, never faked. The key is
// never written to the repository, printed, or placed in an assertion message.
//
// Local run (key only in this process):
//   $env:JINGYU_LIVE_BASE_URL = 'https://<host>/v1'
//   $env:JINGYU_LIVE_API_KEY  = '<local only>'
//   $env:JINGYU_LIVE_MODEL    = 'auto'
//   dart test test/provider_live_probe_test.dart -r expanded
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
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

void main() {
  final liveBaseUrl =
      Platform.environment['JINGYU_LIVE_BASE_URL']?.trim() ?? '';
  final liveApiKey = Platform.environment['JINGYU_LIVE_API_KEY'] ?? '';
  final liveModelRaw = Platform.environment['JINGYU_LIVE_MODEL']?.trim() ?? '';
  final model = liveModelRaw.isEmpty ? 'auto' : liveModelRaw;
  // Presence only; values are never printed. This probe only needs a chat-capable
  // provider (a TTS-only key/endpoint will fail the call honestly, not fabricate).
  final hasCredentials = liveBaseUrl.isNotEmpty && liveApiKey.trim().isNotEmpty;

  group(
    'provider live probe',
    () {
      late Directory directory;
      late SqliteDatabase db;
      late AesGcmColumnCipher cipher;
      final ai = AiId.parse('profile');
      final clock = FakeClock(DateTime.utc(2026, 11, 17, 1));
      final guard = UrlGuard();
      final migrations = [
        ...allMigrations,
        ...accountsMigrations,
        ...modelsMigrations,
        aiIdentityMigration,
        bindingMigration,
        ...usageMigrations,
        budgetTimezoneMigration,
      ];

      setUp(() async {
        directory = await Directory.systemTemp.createTemp(
          'provider-live-probe-',
        );
        db = await SqliteDatabase.open(
          '${directory.path}/probe.sqlite',
          migrations: migrations,
        );
        cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
        await db.execute(
          "INSERT INTO account VALUES ('alice', 'alice', 'human', 0, 0, 'hash', 0, 0)",
        );
        await db.execute(
          "INSERT INTO account VALUES ('principal', 'AI', 'ai', 0, 0, NULL, 0, 0)",
        );
        await db.execute(
          "INSERT INTO ai_operator VALUES ('principal', 'alice')",
        );
        await db.execute(
          "INSERT INTO ai_profile VALUES ('profile', 'principal')",
        );
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
                  name: 'Live probe',
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
      });

      tearDown(() async {
        await db.close();
        cipher.dispose();
        await directory.delete(recursive: true);
      });

      test(
        'one bounded real chat completion through trusted ModelRuntime',
        () async {
          final runtime = ModelRuntime(
            db: db,
            cipher: cipher,
            urlGuard: guard,
            clock: clock,
            // Same guarded-HTTP implementation the production worker runs.
            adapter: OpenAiCompatibleChatAdapter(GuardedHttpTransport()),
          );
          final result = await runtime.chat(
            ownerId: 'alice',
            ai: ai,
            turns: const [
              ChatTurn(role: 'user', content: 'Reply with the word OK only.'),
            ],
            requestId: 'provider-live-probe-1',
            layer: BudgetLayer.b2DeepChat,
            context: TrustedChatContext(
              initiator: AccountId.parse('alice'),
              conversationKind: ChatConversationKind.private,
              scopeKey: 'private:alice:profile',
            ),
            maxTokens: 8,
          );
          if (result case Err<ChatCompletion>(:final failure)) {
            // Only the failure code is surfaced; never upstream text or key.
            fail('provider call failed: ${failure.code.name}');
          }
          final value = result.value;
          expect(value.text.trim(), isNotEmpty);
          expect(value.totalTokens, value.inputTokens + value.outputTokens);
          // Deliberately print only normalized, non-secret completion fields.
          print(
            'LIVE_PROBE_OK replyChars=${value.text.trim().length} '
            'usage=${value.inputTokens}/${value.outputTokens}/${value.totalTokens}',
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    },
    skip: hasCredentials
        ? false
        : 'live chat provider credentials absent '
              '(set JINGYU_LIVE_BASE_URL + JINGYU_LIVE_API_KEY, optional '
              'JINGYU_LIVE_MODEL); a TTS-only key cannot run this chat probe',
  );
}
