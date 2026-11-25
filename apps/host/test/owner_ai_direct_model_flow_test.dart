// Offline integration: real SQLite/consent/incoming/observer/facade/runtime,
// injected fake guarded provider transport. NOT a live provider or HTTP test.
import 'dart:async';
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
import 'package:jingyu_host/src/messages/message_store.dart';
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
const _question = '为什么这样？请解释原因。';
const _nextQuestion = '为什么会不同？请解释原因。';
const _answer = 'Synthetic S2 explanation';
const _normalChoice = {
  'message': {'role': 'assistant', 'content': _answer},
};
const _blankChoice = {
  'message': {'role': 'assistant', 'content': ' \t\n'},
};
const _reportedUsage = {
  'prompt_tokens': 7,
  'completion_tokens': 3,
  'total_tokens': 10,
};

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late SqliteMessageStore messages;
  late OwnerAiDirectIncoming incoming;
  late OwnerAiDirectConsent consent;
  late OwnerAiDirectReplyObserver observer;
  late String direct, provider;
  final clock = FakeClock(DateTime.utc(2026, 11, 17));
  final ai = AiId.parse(
    'profile',
  ); // Profile ID deliberately differs from account.
  final guard = UrlGuard(resolver: (_) async => [InternetAddress('8.8.8.8')]);
  var providerCalls = 0, responseStatus = 200;
  Object? responseChoice, responseUsage;
  List<Map<String, Object?>> received = [];
  Completer<void>? entered, release;

  Future<void> connect() async {
    db = await SqliteDatabase.open(
      '${directory.path}/flow.sqlite',
      migrations: _migrations,
    );
    messages = SqliteMessageStore(database: db, cipher: cipher, clock: clock);
    incoming = OwnerAiDirectIncoming(database: db, messages: messages);
    consent = OwnerAiDirectConsent(database: db, clock: clock);
    final runtime = ModelRuntime(
      db: db,
      cipher: cipher,
      clock: clock,
      urlGuard: guard,
      adapter: OpenAiCompatibleChatAdapter.withRequest((
        method,
        uri, {
        headers = const {},
        body,
      }) async {
        providerCalls++;
        expect(method, 'POST');
        // Boolean matcher avoids exposing credential/header text on failure.
        expect(headers['authorization'] == 'Bearer synthetic-flow-key', isTrue);
        expect(uri.toString(), 'https://offline.example/v1/chat/completions');
        final payload = (jsonDecode(utf8.decode(body!)) as Map)
            .cast<String, Object?>();
        expect(payload['model'], 'pinned-s2');
        expect(payload['max_tokens'], 32);
        expect(payload['stream'], isFalse);
        received = (payload['messages']! as List)
            .map((turn) => (turn as Map).cast<String, Object?>())
            .toList();
        entered?.complete();
        await release?.future;
        return Ok(
          GuardedResponse(
            statusCode: responseStatus,
            headers: const {},
            body: utf8.encode(
              jsonEncode(
                responseStatus == 200
                    ? {
                        'choices': [responseChoice],
                        'usage': ?responseUsage,
                      }
                    : {
                        'error': {
                          'message': 'synthetic provider private error detail',
                        },
                      },
              ),
            ),
          ),
        );
      }),
    );
    observer = OwnerAiDirectReplyObserver(
      database: db,
      cipher: cipher,
      messages: messages,
      system: 'Trusted system.',
      maxTokens: 32,
      admitS1: (_) async =>
          throw StateError('Complex fixture must use S2 only'),
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

  Future<AppendResult> send({
    String? conversation,
    String clientMsgId = 'owner-complex-v1',
    String text = _question,
  }) async {
    final appended = await incoming.append(
      conversationId: conversation ?? direct,
      senderId: 'owner',
      clientMsgId: clientMsgId,
      kind: MessageKind.text,
      body: {'text': text},
    );
    expect(appended.isOk, isTrue);
    return appended.value;
  }

  Future<List<Map<String, Object?>>> sync({String? conversation}) async =>
      (await messages.since(
        conversationId: conversation ?? direct,
        afterSeq: 0,
      )).value.messages.map((message) => message.toPayload()).toList();

  Future<OwnerReplyAttempt?> attempt(StoredMessage source) => db.transaction(
    (tx) => const OwnerReplyAttempts().getForOwnerInTx(
      tx,
      ownerAccountId: 'owner',
      sourceMessageId: source.messageId,
      aiProfileId: 'profile',
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('owner-ai-model-flow-');
    cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i + 1));
    providerCalls = 0;
    responseStatus = 200;
    responseChoice = _normalChoice;
    responseUsage = _reportedUsage;
    received = [];
    entered = null;
    release = null;
    await connect();
    await db.execute(
      "INSERT INTO account VALUES('owner','Owner','human',0,0,'synthetic',0,0)",
    );
    await db.execute("INSERT INTO account VALUES('ai','AI','ai',0,0,NULL,0,0)");
    await db.execute("INSERT INTO ai_operator VALUES('ai','owner')");
    await db.execute("INSERT INTO ai_profile VALUES('profile','ai')");
    final opened = await consent.open(
      ownerId: 'owner',
      aiProfileId: 'profile',
      expectedRevision: 0,
    );
    expect(opened.isOk, isTrue);
    direct = opened.value['conversationId']! as String;
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
    expect(
      (await BudgetConfiguration.forOwner(
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
          ))
          .isOk,
      isTrue,
    );
    // Synthetic fixture credential only. No external config, user key or network.
    provider =
        (await ProviderRegistry.forOwner(
              ownerId: 'owner',
              db: db,
              cipher: cipher,
              urlGuard: guard,
              clock: clock,
            ).create(
              name: 'Offline fixture',
              baseUrl: 'https://offline.example/v1',
              apiKey: 'synthetic-flow-key',
              capabilities: {ProviderCapability.chat},
            ))
            .value
            .id;
    expect(
      (await BindingMatrix.forOwner('owner', db).set(
        ai,
        ProviderCapability.chat,
        providerId: provider,
        model: 'pinned-s2',
      )).isOk,
      isTrue,
    );
  });
  tearDown(() async {
    if (release != null && !release!.isCompleted) release!.complete();
    await db.close();
    cipher.dispose();
    // Only this exact directory is owned by this fixture, never a provider path.
    await directory.delete(recursive: true);
  });

  test(
    'complex owner text settles B2 usage and canonical S2 sync survives reopen',
    () async {
      final source = (await send()).message;
      expect(
        await db.query('SELECT * FROM owner_ai_direct_sources'),
        hasLength(1),
      );
      await observer.onAccepted(source);
      expect(providerCalls, 1);
      expect(received, [
        {
          'role': 'system',
          'content':
              'Trusted system.\n\nSaved persona (JSON):\n'
              '{"p0":{"name":"Nora"},"p1":{"style":"warm"},"p2":{"mood":"calm"}}',
        },
        {'role': 'user', 'content': _question},
      ]);
      final before = await sync();
      expect(before.map((row) => row['seq']).toList(), [1, 2]);
      expect(before.last['senderId'], 'ai');
      expect(before.last['body'], {
        'text': _answer,
        'source': 's2',
        'activityRefs': [],
      });
      final completed = (await attempt(source))!;
      expect(completed.status, OwnerReplyAttemptStatus.completed);
      expect(completed.replyId, before.last['messageId']);
      final ledger = await db.query('SELECT * FROM usage_ledger');
      expect(ledger, hasLength(1));
      expect(ledger.single['request_id'], completed.claim.requestId);
      expect(ledger.single['layer'], 'b2DeepChat');
      expect(ledger.single['capability'], 'chat');
      expect(ledger.single['input_tokens'], '7');
      expect(ledger.single['output_tokens'], '3');
      expect(ledger.single['total_tokens'], '10');
      expect(ledger.single['source_usage_unknown'], 0);
      await db.close();
      await connect();
      expect(await sync(), before);
      final restored = (await attempt(source))!;
      expect(restored.status, OwnerReplyAttemptStatus.completed);
      expect(restored.replyId, completed.replyId);
      expect(await db.query('SELECT * FROM usage_ledger'), ledger);
      final duplicate = await send();
      expect(duplicate.duplicate, isTrue);
      expect(duplicate.message.messageId, source.messageId);
      await observer.onAccepted(duplicate.message);
      await observer.onAccepted(source);
      expect(providerCalls, 1);
      expect(await sync(), before);
      expect(
        await db.query('SELECT * FROM owner_reply_attempts'),
        hasLength(1),
      );
    },
  );

  test(
    'populated direct, private group and persona history never enter stateless prompt',
    () async {
      const priorOwner = 'PRIVATE_OWNER_HISTORY_SENTINEL';
      const priorAi = 'PRIVATE_AI_HISTORY_SENTINEL';
      const priorGroup = 'PRIVATE_GROUP_HISTORY_SENTINEL';
      const oldPersona = 'OLD_PERSONA_HISTORY_SENTINEL';
      for (final entry in [
        ('owner', priorOwner, 'prior-owner'),
        ('ai', priorAi, 'prior-ai'),
      ]) {
        expect(
          (await incoming.append(
            conversationId: direct,
            senderId: entry.$1,
            clientMsgId: entry.$3,
            kind: MessageKind.text,
            body: {'text': entry.$2},
          )).isOk,
          isTrue,
        );
      }
      await db.execute(
        "INSERT INTO social_conversations VALUES('private-group','owner','Private group','all',0)",
      );
      await db.execute(
        "INSERT INTO social_members VALUES('private-group','owner',0,1)",
      );
      expect(
        (await incoming.append(
          conversationId: 'private-group',
          senderId: 'owner',
          clientMsgId: 'prior-group',
          kind: MessageKind.text,
          body: const {'text': priorGroup},
        )).isOk,
        isTrue,
      );
      final persona = SqlitePersonaService.forOwner(
        ownerId: 'owner',
        actorAccountId: 'owner',
        database: db,
        cipher: cipher,
        clock: clock,
      );
      expect(
        (await persona.edit(
          ai,
          PersonaDiff(p2: {'mood': oldPersona}),
          expectedVersion: 1,
          reason: 'synthetic history',
        )).isOk,
        isTrue,
      );
      expect(
        (await persona.edit(
          ai,
          PersonaDiff(p2: {'mood': 'calm'}),
          expectedVersion: 2,
          reason: 'restore current persona',
        )).isOk,
        isTrue,
      );
      final history = (await persona.history(ai)).value;
      expect(
        history.any((change) => change.after.p2['mood'] == oldPersona),
        isTrue,
      );
      expect((await sync()).length, 2);
      expect((await sync(conversation: 'private-group')).length, 1);
      final source = (await send()).message;
      await observer.onAccepted(source);
      expect(providerCalls, 1);
      expect(received, [
        {
          'role': 'system',
          'content':
              'Trusted system.\n\nSaved persona (JSON):\n'
              '{"p0":{"name":"Nora"},"p1":{"style":"warm"},"p2":{"mood":"calm"}}',
        },
        {'role': 'user', 'content': _question},
      ]);
      final prompt = jsonEncode(received);
      for (final sentinel in [priorOwner, priorAi, priorGroup, oldPersona]) {
        expect(prompt.contains(sentinel), isFalse);
      }
      final synced = await sync();
      expect(synced.length, 4);
      expect(synced.last['body'], {
        'text': _answer,
        'source': 's2',
        'activityRefs': [],
      });
      expect(
        (await attempt(source))!.status,
        OwnerReplyAttemptStatus.completed,
      );
      final ledger = (await db.query('SELECT * FROM usage_ledger')).single;
      expect(ledger['input_tokens'], '7');
      expect(ledger['output_tokens'], '3');
    },
  );

  test(
    'revoke while provider is in flight keeps settled usage but discards reply',
    () async {
      entered = Completer<void>();
      release = Completer<void>();
      final source = (await send()).message;
      final dispatch = observer.onAccepted(source);
      await entered!.future.timeout(const Duration(seconds: 10));
      try {
        expect(
          (await attempt(source))!.status,
          OwnerReplyAttemptStatus.pending,
        );
        expect(
          (await consent.revoke(
            ownerId: 'owner',
            aiProfileId: 'profile',
            expectedRevision: 1,
          )).isOk,
          isTrue,
        );
      } finally {
        release!.complete();
      }
      await dispatch;
      expect(providerCalls, 1);
      expect((await sync()).length, 1);
      final discarded = (await attempt(source))!;
      expect(discarded.status, OwnerReplyAttemptStatus.discarded);
      expect(discarded.failureCode, FailureCode.conflict);
      expect(discarded.replyId, isNull);
      final ledger = (await db.query('SELECT * FROM usage_ledger')).single;
      expect(ledger['total_tokens'], '10');
      expect(ledger['source_usage_unknown'], 0);
      await observer.onAccepted(source);
      expect(providerCalls, 1);
    },
  );

  test(
    'provider error keeps unknown usage and failed safe status with no retry',
    () async {
      responseStatus = 503;
      final source = (await send()).message;
      await observer.onAccepted(source);
      final failed = (await attempt(source))!;
      expect(failed.status, OwnerReplyAttemptStatus.failed);
      expect(failed.failureCode, FailureCode.modelUnavailable);
      expect(failed.replyId, isNull);
      expect((await sync()).length, 1);
      final ledger = await db.query('SELECT * FROM usage_ledger');
      expect(ledger.single['source_usage_unknown'], 1);
      expect(ledger.single['total_tokens'], isNull);
      expect(
        jsonEncode(await db.query('SELECT * FROM owner_reply_attempts')),
        isNot(contains('synthetic provider private error detail')),
      );
      await db.close();
      await connect();
      await observer.onAccepted((await send()).message);
      await observer.onAccepted(source);
      expect(providerCalls, 1);
      expect((await attempt(source))!.status, OwnerReplyAttemptStatus.failed);
      expect(await db.query('SELECT * FROM usage_ledger'), ledger);
    },
  );

  test(
    'blank reply settles reported usage without publishing or retrying the turn',
    () async {
      responseChoice = _blankChoice;
      final source = (await send()).message;
      await observer.onAccepted(source);
      expect(providerCalls, 1);
      expect(await sync(), [source.toPayload()]);
      final failed = (await attempt(source))!;
      expect(failed.status, OwnerReplyAttemptStatus.failed);
      expect(failed.failureCode, FailureCode.modelUnavailable);
      expect(failed.replyId, isNull);
      final ledger = await db.query('SELECT * FROM usage_ledger');
      expect(ledger.single['request_id'], failed.claim.requestId);
      expect(ledger.single['source_usage_unknown'], 0);
      expect(ledger.single['input_tokens'], '7');
      expect(ledger.single['output_tokens'], '3');
      expect(ledger.single['total_tokens'], '10');

      responseChoice = _normalChoice;
      await observer.onAccepted(source);
      expect(providerCalls, 1);
      expect(await sync(), [source.toPayload()]);
      expect(await db.query('SELECT * FROM usage_ledger'), ledger);

      final next = await send(
        clientMsgId: 'owner-complex-v2',
        text: _nextQuestion,
      );
      expect(next.duplicate, isFalse);
      await observer.onAccepted(next.message);
      expect(providerCalls, 2);
      expect(received.last, {'role': 'user', 'content': _nextQuestion});
      final synced = await sync();
      expect(synced.take(2), [source.toPayload(), next.message.toPayload()]);
      expect(synced, hasLength(3));
      expect(synced.last['senderId'], 'ai');
      expect(synced.last['body'], {
        'text': _answer,
        'source': 's2',
        'activityRefs': [],
      });
      final completed = (await attempt(next.message))!;
      expect(completed.status, OwnerReplyAttemptStatus.completed);
      expect(completed.replyId, synced.last['messageId']);
      expect((await attempt(source))!.status, OwnerReplyAttemptStatus.failed);
      expect(await db.query('SELECT * FROM usage_ledger'), hasLength(2));
      expect(
        await db.query('SELECT * FROM usage_ledger WHERE request_id=?', [
          failed.claim.requestId,
        ]),
        ledger,
      );
    },
  );

  for (final fixture in <String, (Object, Object?)>{
    'inconsistent token sum': (
      _blankChoice,
      {..._reportedUsage, 'total_tokens': 11},
    ),
    'non-integer count': (
      _blankChoice,
      {..._reportedUsage, 'prompt_tokens': 7.0},
    ),
    'missing usage': (_blankChoice, null),
    'null content': (
      {
        'message': {'role': 'assistant', 'content': null},
      },
      _reportedUsage,
    ),
    'malformed message': ({'message': []}, _reportedUsage),
    'wrong role': (
      {
        'message': {'role': 'user', 'content': ''},
      },
      _reportedUsage,
    ),
    'tool call': (
      {
        'message': {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'synthetic-tool-call',
              'type': 'function',
              'function': {'name': 'synthetic_tool', 'arguments': '{}'},
            },
          ],
        },
      },
      _reportedUsage,
    ),
    'legacy function call': (
      {
        'message': {
          'role': 'assistant',
          'content': '',
          'function_call': {'name': 'synthetic_tool', 'arguments': '{}'},
        },
      },
      _reportedUsage,
    ),
    'tool call finish reason': (
      {..._blankChoice, 'finish_reason': 'tool_calls'},
      _reportedUsage,
    ),
    'malformed finish reason': (
      {..._blankChoice, 'finish_reason': false},
      _reportedUsage,
    ),
    'empty string finish reason': (
      {..._blankChoice, 'finish_reason': ''},
      _reportedUsage,
    ),
    'whitespace-only finish reason': (
      {..._blankChoice, 'finish_reason': ' \t'},
      _reportedUsage,
    ),
    'padded tool finish reason': (
      {..._blankChoice, 'finish_reason': ' tool_calls '},
      _reportedUsage,
    ),
    'audio response with blank content': (
      {
        'message': {
          'role': 'assistant',
          'content': '',
          'audio': {
            'id': 'synthetic-audio',
            'data': 'AA==',
            'expires_at': 1789980000,
            'transcript': 'Synthetic audio response',
          },
        },
      },
      _reportedUsage,
    ),
  }.entries) {
    test(
      '${fixture.key} keeps usage unknown and blocks a separate turn',
      () async {
        (responseChoice, responseUsage) = fixture.value;
        final source = (await send()).message;
        await observer.onAccepted(source);
        expect(providerCalls, 1);
        expect(await sync(), [source.toPayload()]);
        final failed = (await attempt(source))!;
        expect(failed.status, OwnerReplyAttemptStatus.failed);
        expect(failed.failureCode, FailureCode.modelUnavailable);
        expect(failed.replyId, isNull);
        final ledger = await db.query('SELECT * FROM usage_ledger');
        expect(ledger.single['request_id'], failed.claim.requestId);
        expect(ledger.single['source_usage_unknown'], 1);
        expect(ledger.single['input_tokens'], isNull);
        expect(ledger.single['output_tokens'], isNull);
        expect(ledger.single['total_tokens'], isNull);

        responseChoice = _normalChoice;
        responseUsage = _reportedUsage;
        final next = await send(
          clientMsgId: 'owner-complex-v2',
          text: _nextQuestion,
        );
        expect(next.duplicate, isFalse);
        await observer.onAccepted(next.message);
        expect(providerCalls, 1);
        expect(await sync(), [source.toPayload(), next.message.toPayload()]);
        final blocked = (await attempt(next.message))!;
        expect(blocked.status, OwnerReplyAttemptStatus.failed);
        expect(blocked.failureCode, FailureCode.unavailable);
        expect(blocked.replyId, isNull);
        expect(await db.query('SELECT * FROM usage_ledger'), ledger);
      },
    );
  }

  test('ordinary group complex text never invokes owner model path', () async {
    await db.execute(
      "INSERT INTO social_conversations VALUES('group','owner','Group','all',0)",
    );
    await db.execute("INSERT INTO social_members VALUES('group','owner',0,1)");
    final source = (await send(conversation: 'group')).message;
    await observer.onAccepted(source);
    expect(providerCalls, 0);
    expect(await attempt(source), isNull);
    expect(await db.query('SELECT * FROM owner_ai_direct_sources'), isEmpty);
    expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
    expect((await sync(conversation: 'group')).single['senderId'], 'owner');
  });
}
