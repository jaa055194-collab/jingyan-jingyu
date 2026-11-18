import 'dart:convert';
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
  late Directory dir;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late ModelRuntime runtime;
  late String providerId;
  var calls = 0;
  var receivedMaxTokens = <Object?>[];
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
  ];
  final context = TrustedChatContext(
    initiator: AccountId.parse('alice'),
    conversationKind: ChatConversationKind.private,
  );
  final adapter = OpenAiCompatibleChatAdapter.withRequest((
    method,
    uri, {
    headers = const {},
    body,
  }) async {
    calls++;
    expect(method, 'POST');
    expect(uri.toString(), 'https://models.example/v1/chat/completions');
    final payload = jsonDecode(utf8.decode(body!)) as Map;
    receivedMaxTokens.add(payload['max_tokens']);
    expect(payload['model'], 'chat-model');
    expect(payload['messages'], [
      {'role': 'user', 'content': 'hello'},
    ]);
    return Ok(
      GuardedResponse(
        statusCode: 200,
        headers: {},
        body: utf8.encode(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'answer'},
              },
            ],
            'usage': {
              'prompt_tokens': 3,
              'completion_tokens': 2,
              'total_tokens': 5,
            },
          }),
        ),
      ),
    );
  });
  void compose() => runtime = ModelRuntime(
    db: db,
    cipher: cipher,
    urlGuard: guard,
    clock: clock,
    adapter: adapter,
  );
  Future<void> configure(int offset) async {
    final result =
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
          offsetMinutes: offset,
        );
    expect(result.isOk, isTrue);
  }

  Future<Result<ChatCompletion>> chat(
    String requestId, {
    String owner = 'alice',
    ModelRuntime? service,
    int? maxTokens,
    String? expectedProviderId,
    String? expectedModel,
  }) => (service ?? runtime).chat(
    ownerId: owner,
    ai: ai,
    turns: const [ChatTurn(role: 'user', content: 'hello')],
    requestId: requestId,
    layer: BudgetLayer.b2DeepChat,
    context: context,
    maxTokens: maxTokens,
    expectedProviderId: expectedProviderId,
    expectedModel: expectedModel,
  );
  setUp(() async {
    calls = 0;
    receivedMaxTokens = [];
    dir = await Directory.systemTemp.createTemp('model-runtime-');
    db = await SqliteDatabase.open(
      '${dir.path}/db.sqlite',
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
              apiKey: 'runtime-test-key',
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
    compose();
  });
  tearDown(() async {
    await db.close();
    cipher.dispose();
    await dir.delete(recursive: true);
  });

  test(
    'missing explicit budget configuration fails closed before provider call',
    () async {
      final result = await chat('missing');
      expect(result.failureOrNull?.code, FailureCode.budgetExhausted);
      expect(result.failureOrNull?.details['configurationRequired'], isTrue);
      expect(calls, 0);
      expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );

  test('legacy budget without an explicit timezone fails closed', () async {
    await configure(480);
    await db.execute('UPDATE usage_budget SET offset_minutes=NULL');
    final result = await chat('legacy');
    expect(result.failureOrNull?.code, FailureCode.budgetExhausted);
    expect(calls, 0);
    expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
  });

  test(
    'persisted offset determines civil day after reopen and is read per call',
    () async {
      await configure(480);
      await db.close();
      db = await SqliteDatabase.open(
        '${dir.path}/db.sqlite',
        migrations: migrations,
      );
      compose();
      expect((await chat('east')).value.text, 'answer');
      await configure(-300);
      expect((await chat('west')).value.totalTokens, 5);
      final rows = await db.query(
        'SELECT * FROM usage_ledger ORDER BY request_id',
      );
      expect(rows.map((r) => r['budget_day']).toList(), [
        '2026-11-14',
        '2026-11-13',
      ]);
      expect(rows.map((r) => r['offset_minutes']).toList(), [480, -300]);
      expect(rows.map((r) => r['source_usage_unknown']).toList(), [0, 0]);
      expect(rows.map((r) => r['total_tokens']).toList(), ['5', '5']);
      expect(calls, 2);
    },
  );

  test('runtime forwards expected binding and token cap', () async {
    await configure(480);
    expect(
      (await chat(
        'runtime-bound',
        maxTokens: 37,
        expectedProviderId: providerId,
        expectedModel: 'chat-model',
      )).isOk,
      isTrue,
    );
    expect(receivedMaxTokens, [37]);
  });

  test('runtime rejects incomplete expected binding before outbound', () async {
    await configure(480);
    final result = await chat(
      'runtime-incomplete-binding',
      expectedProviderId: providerId,
    );
    expect(result.failureOrNull?.code, FailureCode.invalidArgument);
    expect(calls, 0);
    expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
  });

  test('runtime forwards explicit maxTokens to its adapter', () async {
    await configure(480);
    expect((await chat('max-tokens', maxTokens: 37)).isOk, isTrue);
    expect(receivedMaxTokens, [37]);
  });

  test(
    'one runtime scopes each call to owner without leaking owner configuration',
    () async {
      await configure(480);
      final denied = await chat('other', owner: 'bob');
      expect(denied.failureOrNull?.code, FailureCode.notFound);
      expect(calls, 0);
      expect((await chat('own')).value.text, 'answer');
      final row = (await db.query('SELECT * FROM usage_ledger')).single;
      expect(row['owner_id'], 'alice');
      expect(calls, 1);
      expect(
        (await chat('other-again', owner: 'bob')).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(calls, 1);
    },
  );

  for (final compressed in [false, true]) {
    test(
      'process chat reads a ${compressed ? 'gzip' : 'plain'} fixture response',
      () async {
        await configure(480);
        final worker = File('${dir.path}/response_fixture.dart');
        final plain = utf8.encode(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'fixture reply'},
              },
            ],
            'usage': {
              'prompt_tokens': 3,
              'completion_tokens': 2,
              'total_tokens': 5,
            },
          }),
        );
        final wire = compressed ? gzip.encode(plain) : plain;
        // This child does no networking. It supplies the same raw bytes the
        // packaged worker would return absent opt-in, or the decoded bytes the
        // opt-in worker contract promises. The parent uses real process IPC.
        await worker.writeAsString('''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  final request = jsonDecode(await utf8.decoder.bind(stdin).join()) as Map;
  final payload = jsonDecode(utf8.decode(base64Decode(request['body'] as String))) as Map;
  if (request.length != 6 || request['method'] != 'POST' ||
      Uri.parse(request['url'] as String).path != '/v1/chat/completions' ||
      request['headers']['authorization'] != 'Bearer runtime-test-key' ||
      payload['max_tokens'] != 256 || payload['model'] != 'chat-model' ||
      Platform.executableArguments.any((arg) => arg.contains('runtime-test-key'))) {
    exitCode = 1;
    return;
  }
  final wire = base64Decode('${base64Encode(wire)}');
  final decode = $compressed && args.length == 1 && args.single == '--decode-gzip';
  final bytes = decode ? gzip.decode(wire) : wire;
  stdout.writeln(jsonEncode({
    'ok':true, 'statusCode':200,
    'headers': ${compressed ? "{'content-encoding':['gzip']}" : '{}'},
    'body':base64Encode(bytes),
  }));
}
''');
        final result = await chat(
          'process-fixture',
          service: ModelRuntime.withProcess(
            db: db,
            cipher: cipher,
            urlGuard: guard,
            clock: clock,
            executable: Platform.resolvedExecutable,
            workerPath: worker.path,
          ),
          maxTokens: 256,
        );
        expect(result.isOk, isTrue, reason: result.failureOrNull?.code.name);
        expect(result.value.text, 'fixture reply');
        expect(result.value.totalTokens, 5);
        final usage = (await db.query('SELECT * FROM usage_ledger')).single;
        expect(usage['source_usage_unknown'], 0);
        expect(usage['total_tokens'], '5');
      },
    );
  }

  test(
    'process factory blocks localhost before worker spawn or outbound request',
    () async {
      await configure(480);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var received = 0;
      server.listen((request) async {
        received++;
        await request.response.close();
      });
      final marker = File('${dir.path}/worker-started');
      final worker = File('${dir.path}/worker.dart');
      await worker.writeAsString(
        "import 'dart:io'; void main() { File(${jsonEncode(marker.path)}).writeAsStringSync('started'); }",
      );
      try {
        // Simulate stale persisted provider data; runtime must recheck its URL.
        await db.execute('UPDATE providers SET base_url=? WHERE id=?', [
          'http://localhost:${server.port}/v1',
          providerId,
        ]);
        final processRuntime = ModelRuntime.withProcess(
          db: db,
          cipher: cipher,
          urlGuard: guard,
          clock: clock,
          executable: Platform.resolvedExecutable,
          workerPath: worker.path,
        );
        final result = await chat('blocked', service: processRuntime);
        expect(result.failureOrNull?.code, FailureCode.forbidden);
        expect(await marker.exists(), isFalse);
        expect(received, 0);
        expect(calls, 0);
        expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
      } finally {
        await server.close(force: true);
      }
    },
  );
}
