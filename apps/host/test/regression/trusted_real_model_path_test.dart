/// Regression: the trusted real-model path structure under default composition.
///
/// Pins the composition proven by the env-gated live runs (PR#90 probe, PR#94
/// E2E) with FAKE/loopback transports only — no env key, no real provider:
///   (a) `GuardedHttpTransport` keeps gzip default-deny and exposes the opt-in
///       capability flag, and `OpenAiCompatibleChatAdapter` handles gzip
///       responses through that opt-in transport (loopback pinned connector);
///   (b) an auto-routed model binding with adequate maxTokens yields non-empty
///       content through the guarded chain;
///   (c) `OwnerAiDirectReplyObserver` persists the canonical `s2` assistant
///       message, settles `usage_ledger` (unknown=0, total=in+out) and the
///       budget delta equals the recorded usage.
///
/// If any product change silently breaks the trusted chain — transport policy,
/// adapter contract, observer publication or budget metering — one of these
/// assertions fails. Env-gated live variants remain PR#90/#94; this file is the
/// always-on structural net.
library;

import 'dart:convert';
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
import 'package:jingyu_host/src/models/model_gateway.dart';
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

/// Valid OpenAI-compatible 200 payload with settled usage.
Map<String, Object?> _body() => {
  'choices': [
    {
      'message': {'role': 'assistant', 'content': 'OK'},
    },
  ],
  'usage': {'prompt_tokens': 5, 'completion_tokens': 2, 'total_tokens': 7},
};

const _syntheticKey = 'sk-regression-synthetic-not-a-real-key';
const _question = '为什么这样？请解释原因。';

Future<List<int>> _gzipOf(List<int> bytes) => gzip.encoder
    .bind(Stream<List<int>>.value(bytes))
    .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));

/// Pins the socket destination to a loopback server while the guarded transport
/// validates a public IP literal — the same substitution boundary used by
/// guarded_http_test. No real network is touched.
class _LoopbackConnector implements PinnedConnector {
  _LoopbackConnector(this.port);
  final int port;

  @override
  Future<ConnectionTask<Socket>> startConnect(
    InternetAddress address,
    int port, {
    String? secureHost,
    SecurityContext? context,
  }) => const SocketPinnedConnector().startConnect(
    InternetAddress.loopbackIPv4,
    this.port,
    secureHost: secureHost,
    context: context,
  );
}

Future<void> _seedOwnerChain(
  SqliteDatabase db,
  AesGcmColumnCipher cipher,
  Clock clock,
  UrlGuard guard,
  AiId ai, {
  required String baseUrl,
}) async {
  await db.execute(
    "INSERT INTO account VALUES ('owner','Owner','human',0,0,'synthetic',0,0)",
  );
  await db.execute("INSERT INTO account VALUES ('ai','AI','ai',0,0,NULL,0,0)");
  await db.execute("INSERT INTO ai_operator VALUES ('ai','owner')");
  await db.execute("INSERT INTO ai_profile VALUES ('profile','ai')");
  await BudgetConfiguration.forOwner(
    ownerId: 'owner',
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
            ownerId: 'owner',
            db: db,
            cipher: cipher,
            urlGuard: guard,
            clock: clock,
          ).create(
            name: 'Regression',
            baseUrl: baseUrl,
            apiKey: _syntheticKey,
            capabilities: const {ProviderCapability.chat},
          ))
          .value
          .id;
  await BindingMatrix.forOwner(
    'owner',
    db,
  ).set(ai, ProviderCapability.chat, providerId: providerId, model: 'auto');
}

void main() {
  group('trusted real-model path structure (default composition)', () {
    test(
      'guarded transport keeps gzip default-deny and exposes opt-in flag',
      () {
        expect(GuardedHttpTransport().autoUncompress, isFalse);
        expect(
          GuardedHttpTransport(autoUncompress: true).autoUncompress,
          isTrue,
        );
      },
    );

    test(
      'adapter handles gzip responses through the opt-in transport',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final subscription = server.listen((request) async {
          final wire = await _gzipOf(utf8.encode(jsonEncode(_body())));
          request.response.headers.contentType = ContentType.binary;
          request.response.headers.set('content-encoding', 'gzip');
          request.response.add(wire);
          await request.response.close();
        });
        Directory? directory;
        SqliteDatabase? db;
        AesGcmColumnCipher? cipher;
        try {
          directory = await Directory.systemTemp.createTemp('chain-gzip-');
          cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i + 1));
          db = await SqliteDatabase.open(
            '${directory.path}/gzip.sqlite',
            migrations: _migrations,
          );
          final ai = AiId.parse('profile');
          final clock = FakeClock(DateTime.utc(2026, 11, 17, 5));
          // Offline guard: api.example resolves to a public literal that the
          // loopback connector pins to the local gzip server. No real DNS.
          final guard = UrlGuard(
            resolver: (_) async => [InternetAddress('93.184.216.34')],
          );
          // Plain http with the loopback server's port: the connector pins the
          // guarded socket to the local gzip server (https would TLS-fail).
          await _seedOwnerChain(
            db,
            cipher,
            clock,
            guard,
            ai,
            baseUrl: 'http://api.example:${server.port}/v1',
          );
          final runtime = ModelRuntime(
            db: db,
            cipher: cipher,
            clock: clock,
            urlGuard: guard,
            adapter: OpenAiCompatibleChatAdapter(
              GuardedHttpTransport(
                resolver: (_) async => [InternetAddress('93.184.216.34')],
                connector: _LoopbackConnector(server.port),
                timeout: const Duration(seconds: 5),
                autoUncompress: true,
              ),
            ),
          );
          final result = await runtime.chat(
            ownerId: 'owner',
            ai: ai,
            turns: const [
              ChatTurn(role: 'user', content: 'Reply with the word OK only.'),
            ],
            requestId: 'gzip-regression-1',
            layer: BudgetLayer.b2DeepChat,
            context: TrustedChatContext(
              initiator: AccountId.parse('owner'),
              conversationKind: ChatConversationKind.private,
              scopeKey: 'private:owner:profile',
            ),
            maxTokens: 8,
          );
          expect(result.isOk, isTrue, reason: result.failureOrNull?.code.name);
          expect(result.value.text, 'OK');
          expect(result.value.totalTokens, 7);
        } finally {
          await subscription.cancel();
          await server.close(force: true);
          await db?.close();
          cipher?.dispose();
          await directory?.delete(recursive: true);
        }
      },
    );

    test(
      'observer persists canonical s2, settles usage and moves budget',
      () async {
        final directory = await Directory.systemTemp.createTemp('chain-obs-');
        final cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i + 1));
        final ai = AiId.parse('profile');
        final clock = FakeClock(DateTime.utc(2026, 11, 17, 6));
        final guard = UrlGuard();
        final db = await SqliteDatabase.open(
          '${directory.path}/observer.sqlite',
          migrations: _migrations,
        );
        try {
          await _seedOwnerChain(
            db,
            cipher,
            clock,
            guard,
            ai,
            // Public IP literal; the fake transport never dials it.
            baseUrl: 'https://93.184.216.34/v1',
          );
          // The observer chain is fail-closed without a persona (REQ-059).
          final persona =
              await SqlitePersonaService.forOwner(
                ownerId: 'owner',
                actorAccountId: 'owner',
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
          final messages = SqliteMessageStore(
            database: db,
            cipher: cipher,
            clock: clock,
          );
          final incoming = OwnerAiDirectIncoming(
            database: db,
            messages: messages,
          );
          final consent = OwnerAiDirectConsent(database: db, clock: clock);
          final opened = await consent.open(
            ownerId: 'owner',
            aiProfileId: 'profile',
            expectedRevision: 0,
          );
          expect(opened.isOk, isTrue);
          final direct = opened.value['conversationId']! as String;

          final before =
              await UsageMeter.forOwner(
                    ownerId: 'owner',
                    db: db,
                    clock: clock,
                    dayForClock: (c) =>
                        BudgetDay.fromClock(c, offsetMinutes: 480),
                  )
                  .inspect(
                    ai,
                    layer: BudgetLayer.b2DeepChat,
                    capability: ProviderCapability.chat,
                  )
                  .then((r) => r.value);
          expect(before.dailyUsed, BigInt.zero);

          final runtime = ModelRuntime(
            db: db,
            cipher: cipher,
            clock: clock,
            urlGuard: guard,
            adapter: OpenAiCompatibleChatAdapter.withRequest(
              (method, uri, {headers = const <String, String>{}, body}) async =>
                  Ok<GuardedResponse>(
                    GuardedResponse(
                      statusCode: 200,
                      headers: const <String, List<String>>{
                        'content-type': <String>['application/json'],
                      },
                      body: utf8.encode(jsonEncode(_body())),
                    ),
                  ),
            ),
          );
          final observer = OwnerAiDirectReplyObserver(
            database: db,
            cipher: cipher,
            messages: messages,
            system: '你是 Nora，用一句简洁中文回应。',
            maxTokens: 256,
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

          final appended = await incoming.append(
            conversationId: direct,
            senderId: 'owner',
            clientMsgId: 'regression-inbound-1',
            kind: MessageKind.text,
            body: const {'text': _question},
          );
          expect(appended.isOk, isTrue);
          final source = appended.value.message;
          await observer.onAccepted(source);

          final attempt = await db.transaction(
            (tx) => const OwnerReplyAttempts().getForOwnerInTx(
              tx,
              ownerAccountId: 'owner',
              sourceMessageId: source.messageId,
              aiProfileId: 'profile',
            ),
          );
          expect(attempt!.status, OwnerReplyAttemptStatus.completed);

          final synced = await messages.since(
            conversationId: direct,
            afterSeq: 0,
          );
          final rows = synced.value.messages.map((m) => m.toPayload()).toList();
          expect(rows.map((r) => r['seq']).toList(), [1, 2]);
          final assistant = rows.last;
          expect(assistant['senderId'], 'ai');
          final body = (assistant['body'] as Map).cast<String, Object?>();
          expect(body['source'], 's2');
          expect((body['text'] as String).trim(), isNotEmpty);
          expect(attempt.replyId, assistant['messageId']);

          final ledger = (await db.query('SELECT * FROM usage_ledger')).single;
          expect(ledger['source_usage_unknown'], 0);
          final input = BigInt.parse(ledger['input_tokens'] as String);
          final output = BigInt.parse(ledger['output_tokens'] as String);
          final total = BigInt.parse(ledger['total_tokens'] as String);
          expect(total, input + output);

          final after =
              await UsageMeter.forOwner(
                    ownerId: 'owner',
                    db: db,
                    clock: clock,
                    dayForClock: (c) =>
                        BudgetDay.fromClock(c, offsetMinutes: 480),
                  )
                  .inspect(
                    ai,
                    layer: BudgetLayer.b2DeepChat,
                    capability: ProviderCapability.chat,
                  )
                  .then((r) => r.value);
          expect(after.dailyUsed - before.dailyUsed, total);
          expect(after.sourceUsageUnknown, isFalse);
        } finally {
          await db.close();
          cipher.dispose();
          await directory.delete(recursive: true);
        }
      },
    );
  });
}
