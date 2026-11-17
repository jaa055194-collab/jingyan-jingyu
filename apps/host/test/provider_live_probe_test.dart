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
// The env gate, migration set and owner chain fixtures are shared with
// `worker_e2e_live_assembly_test.dart` via `live_provider_support.dart`.
//
// Local run (key only in this process):
//   $env:JINGYU_LIVE_BASE_URL = 'https://<host>/v1'
//   $env:JINGYU_LIVE_API_KEY  = '<local only>'
//   $env:JINGYU_LIVE_MODEL    = 'auto'
//   dart test test/provider_live_probe_test.dart -r expanded
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/models/model_gateway.dart';
import 'package:jingyu_host/src/models/model_runtime.dart';
import 'package:jingyu_host/src/models/openai_chat_adapter.dart';
import 'package:jingyu_host/src/security/guarded_http.dart';
import 'package:jingyu_host/src/security/url_guard.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

import 'live_provider_support.dart';

void main() {
  final env = LiveProviderEnv.fromEnvironment();
  // Presence only; values are never printed. This probe only needs a chat-capable
  // provider (a TTS-only key/endpoint will fail the call honestly, not fabricate).
  final hasCredentials = env.hasCredentials;

  group(
    'provider live probe',
    () {
      late Directory directory;
      late SqliteDatabase db;
      late AesGcmColumnCipher cipher;
      final ai = AiId.parse('profile');
      final clock = FakeClock(DateTime.utc(2026, 11, 17, 1));
      final guard = UrlGuard();

      setUp(() async {
        directory = await Directory.systemTemp.createTemp(
          'provider-live-probe-',
        );
        db = await SqliteDatabase.open(
          '${directory.path}/probe.sqlite',
          migrations: liveProviderMigrations,
        );
        cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
        await seedOwnerAndAi(db, ownerId: 'alice', aiAccountId: 'principal');
        await configureOwnerChain(
          db: db,
          cipher: cipher,
          clock: clock,
          urlGuard: guard,
          ai: ai,
          env: env,
          ownerId: 'alice',
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
            clock: clock,
            urlGuard: guard,
            // Same guarded-HTTP implementation the production worker runs.
            // autoUncompress is opted in for providers that always gzip
            // (PR#93 diagnosis); the inflated body stays bounded.
            adapter: OpenAiCompatibleChatAdapter(
              GuardedHttpTransport(autoUncompress: true),
            ),
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
          expect(value.text.trim().isNotEmpty, isTrue);
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
              '(set JINGYU_LIVE_BASE_URL + JINGYU_LIVE_API_KEY); a TTS-only key '
              'cannot run this chat probe',
  );
}
