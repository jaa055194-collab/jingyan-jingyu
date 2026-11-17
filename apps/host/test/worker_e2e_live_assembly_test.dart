// Milestone E2E: trusted worker owner-AI direct reply chain against a REAL
// OpenAI-compatible provider (env-gated; never logs or commits the key).
//
// Real SQLite + real host services compose:
//   ProviderRegistry (encrypted credential) + BindingMatrix(chat)
//   + BudgetConfiguration + PersonaService
//   -> OwnerAiDirectIncoming (one inbound owner text)
//   -> OwnerAiDirectReplyObserver (trusted worker, maxTokens 256)
//   -> StatelessOwnerChat -> ModelRuntime -> ModelGateway -> UrlGuard
//   -> OpenAiCompatibleChatAdapter -> real HTTPS provider
//   -> canonical assistant message persisted + owner read-back + budget used.
//
// Runs only when JINGYU_LIVE_BASE_URL + JINGYU_LIVE_API_KEY are set
// (JINGYU_LIVE_MODEL defaults to "auto"); otherwise the group SKIPS honestly.
// The API key is read only from the environment and never printed or committed.
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_service.dart';
import 'package:jingyu_host/src/brain/owner_ai_direct_incoming.dart';
import 'package:jingyu_host/src/brain/owner_ai_direct_reply_observer.dart';
import 'package:jingyu_host/src/brain/owner_ai_direct_source_migration.dart';
import 'package:jingyu_host/src/brain/owner_reply_attempts.dart';
import 'package:jingyu_host/src/brain/owner_reply_attempts_migration.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
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
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_consent.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_migration.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

const _migrations = [
  ...allMigrations,
  ...accountsMigrations,
  ...messagesMigrations,
  ownerReplyAttemptsMigration,
  ownerAiDirectSourceMigration,
  ...socialMigrations,
  friendshipMigration,
  privateConversationMigration,
  ownerAiDirectMigration,
  ...modelsMigrations,
  aiIdentityMigration,
  bindingMigration,
  ownerAiProfileInvalidationMigration,
  ...usageMigrations,
  budgetTimezoneMigration,
  ...personaMigrations,
];

// Complex prompt so the trusted worker takes the S2 model path (not S1 rules).
const _question = '为什么这样？请解释原因。';
const _dailyTokens = 1000000;
const _maxTokens = 256;

void main() {
  final liveBaseUrl =
      Platform.environment['JINGYU_LIVE_BASE_URL']?.trim() ?? '';
  final liveApiKey = Platform.environment['JINGYU_LIVE_API_KEY'] ?? '';
  final modelRaw = Platform.environment['JINGYU_LIVE_MODEL']?.trim() ?? '';
  final model = modelRaw.isEmpty ? 'auto' : modelRaw;
  final hasCredentials = liveBaseUrl.isNotEmpty && liveApiKey.trim().isNotEmpty;

  group(
    'trusted worker E2E (live provider)',
    () {
      late Directory directory;
      late SqliteDatabase db;
      late AesGcmColumnCipher cipher;
      late SqliteMessageStore messages;
      late OwnerAiDirectIncoming incoming;
      late OwnerAiDirectConsent consent;
      late OwnerAiDirectReplyObserver observer;
      late String direct;
      final ai = AiId.parse('profile');
      final clock = FakeClock(DateTime.utc(2026, 11, 17, 3));
      final guard = UrlGuard();

      Future<UsageGate> inspect() =>
          UsageMeter.forOwner(
                ownerId: 'owner',
                db: db,
                clock: clock,
                dayForClock: (c) => BudgetDay.fromClock(c, offsetMinutes: 480),
              )
              .inspect(
                ai,
                layer: BudgetLayer.b2DeepChat,
                capability: ProviderCapability.chat,
              )
              .then((r) => r.value);

      Future<void> open() async {
        db = await SqliteDatabase.open(
          '${directory.path}/e2e.sqlite',
          migrations: _migrations,
        );
        messages = SqliteMessageStore(
          database: db,
          cipher: cipher,
          clock: clock,
        );
        incoming = OwnerAiDirectIncoming(database: db, messages: messages);
        consent = OwnerAiDirectConsent(database: db, clock: clock);
        final runtime = ModelRuntime(
          db: db,
          cipher: cipher,
          clock: clock,
          urlGuard: guard,
          // Same guarded in-process transport the production worker runs.
          adapter: OpenAiCompatibleChatAdapter(GuardedHttpTransport()),
        );
        observer = OwnerAiDirectReplyObserver(
          database: db,
          cipher: cipher,
          messages: messages,
          system: '你是 Nora，用一句简洁中文回应。',
          maxTokens: _maxTokens,
          admitS1: (_) async => true,
          resolveBinding: (grant) => BindingMatrix.forOwner(
            grant.ownerAccountId,
            db,
          ).resolve(AiId.parse(grant.aiProfileId), ProviderCapability.chat),
          chat: StatelessOwnerChat.fromRuntime(
            db: db,
            cipher: cipher,
            clock: clock,
            runtime: runtime,
          ),
        );
      }

      setUp(() async {
        directory = await Directory.systemTemp.createTemp('worker-e2e-live-');
        cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i + 1));
        await open();
        await db.execute(
          "INSERT INTO account VALUES('owner','Owner','human',0,0,'synthetic',0,0)",
        );
        await db.execute(
          "INSERT INTO account VALUES('ai','AI','ai',0,0,NULL,0,0)",
        );
        await db.execute("INSERT INTO ai_operator VALUES('ai','owner')");
        await db.execute("INSERT INTO ai_profile VALUES('profile','ai')");
        final providerId =
            (await ProviderRegistry.forOwner(
                  ownerId: 'owner',
                  db: db,
                  cipher: cipher,
                  urlGuard: guard,
                  clock: clock,
                ).create(
                  name: 'Live E2E',
                  baseUrl: liveBaseUrl,
                  apiKey: liveApiKey,
                  capabilities: {ProviderCapability.chat},
                ))
                .value
                .id;
        expect(
          (await BindingMatrix.forOwner('owner', db).set(
            ai,
            ProviderCapability.chat,
            providerId: providerId,
            model: model,
          )).isOk,
          isTrue,
        );
        expect(
          (await BudgetConfiguration.forOwner(
                ownerId: 'owner',
                db: db,
                clock: clock,
              ).configure(
                ai,
                UsageBudget(
                  dailyTokens: _dailyTokens,
                  layerLimits: {
                    for (final layer in BudgetLayer.values)
                      layer: layer == BudgetLayer.b2DeepChat ? _dailyTokens : 0,
                  },
                  capabilityLimits: {
                    for (final cap in ProviderCapability.values)
                      cap: cap == ProviderCapability.chat ? _dailyTokens : 0,
                  },
                ),
                offsetMinutes: 480,
              ))
              .isOk,
          isTrue,
        );
        expect(
          (await SqlitePersonaService.forOwner(
                ownerId: 'owner',
                actorAccountId: 'owner',
                database: db,
                cipher: cipher,
                clock: clock,
              ).initialize(
                ai,
                initial: PersonaLayers(
                  p0: {'name': 'Nora'},
                  p1: {'style': 'warm and concise'},
                  p2: {'mood': 'calm'},
                ),
              ))
              .isOk,
          isTrue,
        );
        final opened = await consent.open(
          ownerId: 'owner',
          aiProfileId: 'profile',
          expectedRevision: 0,
        );
        expect(opened.isOk, isTrue);
        direct = opened.value['conversationId']! as String;
      });

      tearDown(() async {
        await db.close();
        cipher.dispose();
        await directory.delete(recursive: true);
      });

      test(
        'one inbound message produces a real reply, canonical persist, read-back and budget use',
        () async {
          final before = await inspect();
          expect(before.dailyUsed, BigInt.zero);

          final appended = await incoming.append(
            conversationId: direct,
            senderId: 'owner',
            clientMsgId: 'live-e2e-inbound-1',
            kind: MessageKind.text,
            body: const {'text': _question},
          );
          expect(appended.isOk, isTrue);
          final source = appended.value.message;

          await observer.onAccepted(source);

          // Canonical persisted assistant message + owner read-back.
          final synced = await messages.since(
            conversationId: direct,
            afterSeq: 0,
          );
          expect(synced.isOk, isTrue);
          final rows = synced.value.messages.map((m) => m.toPayload()).toList();
          expect(rows.map((r) => r['seq']).toList(), [1, 2]);
          final assistant = rows.last;
          expect(assistant['senderId'], 'ai');
          final body = (assistant['body'] as Map).cast<String, Object?>();
          expect(body['source'], 's2');
          final reply = (body['text'] as String).trim();
          expect(reply, isNotEmpty);

          // Reply attempt terminal state points at the canonical message.
          final attempt = await db.transaction(
            (tx) => const OwnerReplyAttempts().getForOwnerInTx(
              tx,
              ownerAccountId: 'owner',
              sourceMessageId: source.messageId,
              aiProfileId: 'profile',
            ),
          );
          expect(attempt!.status, OwnerReplyAttemptStatus.completed);
          expect(attempt.replyId, assistant['messageId']);

          // Usage ledger recorded real usage (not unknown).
          final ledger = (await db.query('SELECT * FROM usage_ledger')).single;
          expect(ledger['source_usage_unknown'], 0);
          final input = BigInt.parse(ledger['input_tokens'] as String);
          final output = BigInt.parse(ledger['output_tokens'] as String);
          final total = BigInt.parse(ledger['total_tokens'] as String);
          expect(total, input + output);

          // Budget decremented by exactly the recorded usage.
          final after = await inspect();
          expect(after.dailyUsed - before.dailyUsed, total);
          expect(after.sourceUsageUnknown, isFalse);

          // Persisted and readable after a real reopen.
          await db.close();
          await open();
          final reopened = await messages.since(
            conversationId: direct,
            afterSeq: 0,
          );
          expect(
            reopened.value.messages.map((m) => m.toPayload()).toList(),
            rows,
          );
          expect(await db.query('SELECT * FROM usage_ledger'), hasLength(1));

          // Deliberately print only normalized, non-secret evidence.
          print(
            'E2E_OK replyChars=${reply.length} '
            'usage=${ledger['input_tokens']}/${ledger['output_tokens']}/${ledger['total_tokens']} '
            'assistantMessageId=${assistant['messageId']} '
            'attemptReplyId=${attempt.replyId} '
            'budgetDelta=${after.dailyUsed - before.dailyUsed}',
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    },
    skip: hasCredentials
        ? false
        : 'live provider credentials absent (set JINGYU_LIVE_BASE_URL + '
              'JINGYU_LIVE_API_KEY, optional JINGYU_LIVE_MODEL); a TTS-only key '
              'cannot run this chat E2E',
  );
}
