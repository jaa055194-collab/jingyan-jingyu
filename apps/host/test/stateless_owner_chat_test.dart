import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_service.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/model_gateway.dart';
import 'package:jingyu_host/src/models/openai_chat_adapter.dart';
import 'package:jingyu_host/src/models/stateless_owner_chat.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late SqlitePersonaService persona;
  late StatelessOwnerChat facade;
  final clock = FakeClock(DateTime.utc(2026, 11, 17));
  final ai = AiId.parse('profile');
  var calls = 0;
  var output = '答复';
  Failure? portFailure;
  List<ChatTurn> received = [];
  TrustedChatContext? receivedContext;
  String? receivedProvider, receivedModel;
  BudgetLayer? receivedLayer;
  int? receivedMax;

  StatelessOwnerChat compose({
    int inputCap = 4096,
    int outputCap = 8192,
    int encodedCap = 8192,
    int tokenCap = 2048,
  }) => StatelessOwnerChat(
    db: db,
    cipher: cipher,
    clock: clock,
    maxInputBytes: inputCap,
    maxOutputBytes: outputCap,
    maxEncodedRequestBytes: encodedCap,
    maxAllowedTokens: tokenCap,
    chat:
        ({
          required ownerId,
          required ai,
          required turns,
          required requestId,
          required layer,
          required context,
          maxTokens,
          expectedProviderId,
          expectedModel,
        }) async {
          calls++;
          received = turns;
          receivedContext = context;
          receivedLayer = layer;
          receivedProvider = expectedProviderId;
          receivedModel = expectedModel;
          receivedMax = maxTokens;
          if (portFailure != null) return Err<ChatCompletion>(portFailure!);
          return Ok(
            ChatCompletion(
              text: output,
              inputTokens: 2,
              outputTokens: 3,
              totalTokens: 5,
            ),
          );
        },
  );

  Future<Result<ChatCompletion>> ask({
    String owner = 'owner',
    String scope = 'direct',
    String input = '你好',
    String system = 'System.',
    String provider = 'pinned-provider',
    String model = 'pinned-model',
    int maxTokens = 32,
    String requestId = 'r1',
  }) => facade.chat(
    ownerId: owner,
    ai: ai,
    conversationId: scope,
    requestId: requestId,
    system: system,
    input: input,
    expectedProviderId: provider,
    expectedModel: model,
    maxTokens: maxTokens,
  );

  setUp(() async {
    db = await SqliteDatabase.open(
      ':memory:',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        aiIdentityMigration,
        privateConversationMigration,
        ...personaMigrations,
      ],
    );
    cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
    for (final owner in ['owner', 'other']) {
      await db.execute(
        "INSERT INTO account VALUES(?,?,'human',0,0,'synthetic',0,0)",
        [owner, owner],
      );
    }
    await db.execute("INSERT INTO account VALUES('ai','AI','ai',0,0,NULL,0,0)");
    await db.execute("INSERT INTO ai_operator VALUES('ai','owner')");
    await db.execute("INSERT INTO ai_profile VALUES('profile','ai')");
    await db.execute(
      "INSERT INTO direct_conversations VALUES('direct','ai','owner',0)",
    );
    await db.execute(
      "INSERT INTO direct_conversations VALUES('foreign','ai','other',0)",
    );
    persona = SqlitePersonaService.forOwner(
      ownerId: 'owner',
      actorAccountId: 'owner',
      database: db,
      cipher: cipher,
      clock: clock,
    );
    expect(
      (await persona.initialize(
        ai,
        initial: PersonaLayers(
          p0: {'name': 'Nora'},
          p1: {'style': 'warm'},
          p2: {'mood': 'calm'},
        ),
      )).isOk,
      isTrue,
    );
    calls = 0;
    output = '答复';
    portFailure = null;
    received = [];
    facade = compose();
  });
  tearDown(() async {
    await db.close();
    cipher.dispose();
  });

  test(
    'exact saved persona plus system plus one input, fixed B2 private pinning',
    () async {
      final result = await ask();
      expect(result.value.text, '答复');
      expect(result.value.totalTokens, 5);
      expect(received.map((turn) => turn.role).toList(), ['system', 'user']);
      expect(received.map((turn) => turn.content).toList(), [
        'System.\n\nSaved persona (JSON):\n{"p0":{"name":"Nora"},"p1":{"style":"warm"},"p2":{"mood":"calm"}}',
        '你好',
      ]);
      expect(receivedLayer, BudgetLayer.b2DeepChat);
      expect(receivedContext!.initiator.value, 'owner');
      expect(receivedContext!.conversationKind, ChatConversationKind.private);
      expect(receivedContext!.scopeKey, 'direct');
      expect(receivedProvider, 'pinned-provider');
      expect(receivedModel, 'pinned-model');
      expect(receivedMax, 32);
      expect(calls, 1);
      await persona.edit(
        ai,
        PersonaDiff(p2: {'mood': 'happy'}),
        expectedVersion: 1,
        reason: 'synthetic update',
      );
      await ask(requestId: 'r2');
      expect(received[0].content, contains('happy'));
      expect((await persona.current(ai)).value.version, 2);
    },
  );

  test(
    'UTF8 cap includes system and whole persisted persona, exact boundary accepted',
    () async {
      const saved =
          '{"p0":{"name":"Nora"},"p1":{"style":"warm"},"p2":{"mood":"calm"}}';
      final bytes =
          utf8.encode('System.\n\nSaved persona (JSON):\n').length +
          utf8.encode(saved).length +
          utf8.encode('你😀').length;
      facade = compose(inputCap: bytes);
      expect((await ask(input: '你😀')).isOk, isTrue);
      expect(calls, 1);
      facade = compose(inputCap: bytes - 1);
      expect(
        (await ask(input: '你😀')).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(calls, 1); // never truncate or call provider on overflow
    },
  );

  test(
    'JSON escaped payload has its own byte cap, exact boundary accepted',
    () async {
      const combined =
          'System.\n\nSaved persona (JSON):\n'
          '{"p0":{"name":"Nora"},"p1":{"style":"warm"},"p2":{"mood":"calm"}}';
      final input = '"\\\n' * 20;
      final bytes = utf8
          .encode(
            jsonEncode({
              'model': 'pinned-model',
              'messages': [
                {'role': 'system', 'content': combined},
                {'role': 'user', 'content': input},
              ],
              'stream': false,
              'max_tokens': 32,
            }),
          )
          .length;
      facade = compose(encodedCap: bytes);
      expect((await ask(input: input)).isOk, isTrue);
      facade = compose(encodedCap: bytes - 1);
      expect(
        (await ask(input: input)).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(calls, 1);
    },
  );

  test(
    'oversized persona alone is rejected without trimming or provider call',
    () async {
      await persona.edit(
        ai,
        PersonaDiff(p0: {'name': '长' * 2000}),
        expectedVersion: 1,
        reason: 'large persisted persona',
      );
      expect((await ask()).failureOrNull?.code, FailureCode.invalidArgument);
      expect(calls, 0);
    },
  );

  test(
    'unpaired surrogate in stored persona is never implicitly replaced',
    () async {
      final changed = await persona.edit(
        ai,
        PersonaDiff(p2: {'mood': String.fromCharCode(0xd800)}),
        expectedVersion: 1,
        reason: 'synthetic malformed text',
      );
      expect(changed.isOk, isTrue);
      expect((await ask()).failureOrNull?.code, FailureCode.internal);
      expect(calls, 0);
    },
  );

  test(
    'malformed output is safe failure after exactly one runtime call',
    () async {
      output = String.fromCharCode(0xdc00);
      expect((await ask()).failureOrNull?.code, FailureCode.modelUnavailable);
      expect(calls, 1);
    },
  );

  test('explicit maxTokens at policy ceiling is forwarded exactly', () async {
    expect((await ask(maxTokens: 2048)).isOk, isTrue);
    expect(receivedMax, 2048);
    facade = compose(tokenCap: 10);
    expect(
      (await ask(maxTokens: 11)).failureOrNull?.code,
      FailureCode.invalidArgument,
    );
    expect(calls, 1);
  });

  test(
    'trusted composition can raise token policy to 4096, not a global 2048 cap',
    () async {
      facade = compose(tokenCap: 4096);
      expect((await ask(maxTokens: 4096)).isOk, isTrue);
      expect(receivedMax, 4096);
      expect(calls, 1);
      expect(
        (await ask(maxTokens: 4097)).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(calls, 1);
    },
  );

  test(
    'profile ID collision never substitutes an unrelated account in direct pair',
    () async {
      // profile='profile' belongs to AI account 'ai'. A different account whose
      // account ID equals that profile ID must not be treated as that AI.
      await db.execute(
        "INSERT INTO account VALUES('profile','Other AI','ai',0,0,NULL,0,0)",
      );
      await db.execute("INSERT INTO ai_operator VALUES('profile','owner')");
      await db.execute(
        "INSERT INTO direct_conversations VALUES('collision','owner','profile',0)",
      );
      expect(
        (await ask(scope: 'collision')).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(calls, 0);
      expect((await ask(scope: 'direct')).isOk, isTrue);
      expect(receivedContext!.scopeKey, 'direct');
      expect(calls, 1);
    },
  );

  test('invalid input and configuration never call port', () async {
    for (final run in <Future<Result<ChatCompletion>> Function()>[
      () => ask(input: ''),
      () => ask(system: ' '),
      () => ask(provider: ' '),
      () => ask(model: ' bad'),
      () => ask(maxTokens: 0),
      () => ask(maxTokens: 2049),
      () => ask(input: String.fromCharCode(0xd800)),
      () => ask(system: String.fromCharCode(0xdc00)),
      () => ask(requestId: 'bad/id'),
      () => ask(scope: 'bad/id'),
      () => ask(owner: 'bad/id'),
    ]) {
      expect((await run()).isErr, isTrue);
    }
    facade = compose(inputCap: 0);
    expect((await ask()).isErr, isTrue);
    facade = compose(outputCap: 0);
    expect((await ask()).isErr, isTrue);
    expect(calls, 0);
  });

  test(
    'foreign owner, foreign scope, missing scope and missing persona fail closed',
    () async {
      expect(
        (await ask(owner: 'other')).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await ask(scope: 'foreign')).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await ask(scope: 'group')).failureOrNull?.code,
        FailureCode.notFound,
      );
      // Seed another canonical AI lacking persona without deleting immutable history.
      await db.execute(
        "INSERT INTO account VALUES('ai2','AI2','ai',0,0,NULL,0,0)",
      );
      await db.execute("INSERT INTO ai_operator VALUES('ai2','owner')");
      await db.execute("INSERT INTO ai_profile VALUES('no-persona','ai2')");
      await db.execute(
        "INSERT INTO direct_conversations VALUES('direct2','ai2','owner',0)",
      );
      final missing = await facade.chat(
        ownerId: 'owner',
        ai: AiId.parse('no-persona'),
        conversationId: 'direct2',
        requestId: 'missing-persona',
        system: 'System.',
        input: '你好',
        expectedProviderId: 'pinned-provider',
        expectedModel: 'pinned-model',
        maxTokens: 32,
      );
      expect(missing.failureOrNull?.code, FailureCode.notFound);
      expect(calls, 0);
    },
  );

  test(
    'disabled owner or AI and transferred ownership deny before call',
    () async {
      for (final id in ['owner', 'ai']) {
        await db.execute('UPDATE account SET disabled=1 WHERE id=?', [id]);
        expect((await ask()).failureOrNull?.code, FailureCode.notFound);
        await db.execute('UPDATE account SET disabled=0 WHERE id=?', [id]);
      }
      await db.execute("UPDATE ai_operator SET operator_id='other'");
      expect((await ask()).failureOrNull?.code, FailureCode.notFound);
      expect(calls, 0);
    },
  );

  test(
    'output UTF8 byte limit accepts boundary and rejects overflow without retry',
    () async {
      facade = compose(outputCap: 7);
      output = '你😀';
      expect((await ask()).value.text, '你😀');
      output = '你😀a';
      final result = await ask(requestId: 'r2');
      expect(result.failureOrNull?.code, FailureCode.modelUnavailable);
      expect(result.valueOrNull, isNull);
      expect(calls, 2);
    },
  );

  test(
    'runtime safe failures propagate once without retries or classification',
    () async {
      for (final code in [
        FailureCode.rateLimited,
        FailureCode.modelUnavailable,
        FailureCode.budgetExhausted,
        FailureCode.conflict,
      ]) {
        portFailure = Failure(code, 'safe existing runtime error');
        expect((await ask()).failureOrNull?.code, code);
      }
      expect(calls, 4);
    },
  );
}
