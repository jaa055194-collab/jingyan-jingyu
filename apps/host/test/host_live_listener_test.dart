import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

import 'live_provider_support.dart';

const _owner = 'listener-owner';
const _aiAccount = 'listener-ai';
const _profile = 'listener-profile';
const _offlineBase = 'https://192.0.2.1/v1';
const _prompt = '为什么这样？请解释原因。';
const _maxDuration = Duration(minutes: 2);

void main() {
  test(
    'offline: real host HTTP and fixture child persist one S2 reply',
    () async {
      await _verifyListener(live: false);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'live: real host HTTP and packaged worker persist one auto reply',
    () async {
      await _verifyListener(live: true);
    },
    skip: Platform.environment['JINGYU_RUN_LIVE_LISTENER'] == '1'
        ? false
        : 'explicitly opt in with JINGYU_RUN_LIVE_LISTENER=1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _verifyListener({required bool live}) async {
  final env = live ? LiveProviderEnv.fromEnvironment() : null;
  if (env != null) {
    final uri = Uri.tryParse(env.baseUrl);
    if (!env.hasCredentials ||
        env.model != 'auto' ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment) {
      fail(
        'Live listener requires a chat key, an HTTPS provider base, and model auto',
      );
    }
  }
  final elapsed = Stopwatch()..start();
  Duration remaining() {
    final result = _maxDuration - elapsed.elapsed;
    if (result <= Duration.zero) fail('Listener acceptance deadline exceeded');
    return result;
  }

  final directory = await Directory.systemTemp.createTemp(
    'host-listener-test-',
  );
  addTearDown(() => directory.delete(recursive: true));
  final worker = live
      ? File('bin/http_worker.dart').absolute
      : File('${directory.path}/response_fixture.dart');
  if (!live) await worker.writeAsString(_responseFixture);
  expect(await worker.exists(), isTrue, reason: 'worker script exists');
  final clock = FakeClock(DateTime.utc(2026, 11, 18, 4));
  final config = HostConfig(
    dataDir: directory.path,
    modelWorkerExecutable: File(Platform.resolvedExecutable).absolute.path,
    modelWorkerPath: worker.path,
  );
  final random = Random.secure();
  final token = base64UrlEncode(
    List.generate(16, (_) => random.nextInt(256)),
  ).replaceAll('=', '');

  final consentPath = Routes.ownerAiDirectConsent.replaceFirst(
    '{aiId}',
    _profile,
  );
  final usagePath = Routes.aiUsage.replaceFirst('{aiId}', _profile);
  late String syncPath;
  late String statusPath;
  late String sourceId;
  late String replyId;
  late String replyText;
  late BigInt total;

  Future<Map<String, Object?>> readBack(_Listener listener) async {
    final status = await listener.call('GET', statusPath);
    // Surface only known status/error enums, never provider text or raw replies.
    final phase = status['status'];
    final failure = status['failureCode'];
    expect(
      phase == 'completed',
      isTrue,
      reason:
          'S2 attempt: '
          '${const {'notAttempted', 'pending', 'failed', 'discarded'}.contains(phase) ? phase : 'unexpected'} '
          '${ErrorCode.values.any((code) => code.wire == failure) ? failure : ''}',
    );
    expect(
      status['sourceMessageId'] == sourceId,
      isTrue,
      reason: 'source ID matches',
    );
    final synced = await listener.call('GET', syncPath);
    final messages = synced['messages']! as List;
    expect(messages.length, 2, reason: 'one owner message and one S2 reply');
    final source = (messages.first as Map).cast<String, Object?>();
    final assistant = (messages.last as Map).cast<String, Object?>();
    expect(
      source['messageId'] == sourceId &&
          source['senderId'] == _owner &&
          source['seq'] == 1,
      isTrue,
    );
    expect(
      assistant['senderId'] == _aiAccount && assistant['seq'] == 2,
      isTrue,
    );
    expect(
      assistant['messageId'] is String &&
          assistant['messageId'] == status['replyMessageId'],
      isTrue,
      reason: 'status and sync reference the same canonical reply',
    );
    final body = (assistant['body']! as Map).cast<String, Object?>();
    expect(body['source'] == 's2', isTrue);
    expect(
      body['text'] is String && (body['text']! as String).trim().isNotEmpty,
      isTrue,
    );
    return {'id': assistant['messageId'], 'text': body['text']};
  }

  Future<BigInt> readUsage(_Listener listener) async {
    final usage = await listener.call('GET', usagePath);
    final byCapability = usage['byCapability']! as Map;
    final byLayer = usage['byLayer']! as Map;
    final unknown = usage['sourceUsageUnknown']! as Map;
    final raw = usage['recordedTokens'];
    final recorded = raw is String ? BigInt.tryParse(raw) : null;
    if (recorded == null) fail('Invalid recorded token count');
    expect(unknown['chat'] == false, isTrue, reason: 'known chat usage');
    expect(byCapability['chat'] == recorded.toString(), isTrue);
    expect(byLayer['b2DeepChat'] == recorded.toString(), isTrue);
    return recorded;
  }

  final first = await _Listener.boot(config, clock, token, remaining);
  try {
    await _seed(first.host, clock, token);
    final provider = await first.call(
      'POST',
      Routes.modelProviders,
      body: {
        'name': 'Listener acceptance fixture',
        'base_url': env?.baseUrl ?? _offlineBase,
        'api_key': env?.apiKey ?? 'synthetic-listener-key',
        'capabilities': ['chat'],
      },
    );
    final providerId = provider['id']! as String;
    await first.call(
      'PUT',
      Routes.aiBinding
          .replaceFirst('{aiId}', _profile)
          .replaceFirst('{capability}', 'chat'),
      body: {'providerId': providerId, 'model': 'auto'},
    );
    await first.call(
      'POST',
      Routes.aiPersonaInitialize.replaceFirst('{aiId}', _profile),
      body: {
        'p0': {'name': 'Listener fixture'},
        'p1': {'style': 'concise'},
        'p2': {'mood': 'calm'},
      },
    );
    await first.call(
      'PUT',
      Routes.aiBudget.replaceFirst('{aiId}', _profile),
      body: {
        'dailyTokens': 10000,
        'offsetMinutes': 0,
        'layerLimits': {
          for (final layer in BudgetLayer.values)
            layer.name: layer == BudgetLayer.b2DeepChat ? 10000 : 0,
        },
        'capabilityLimits': {
          for (final cap in ProviderCapability.values)
            cap.name: cap == ProviderCapability.chat ? 10000 : 0,
        },
      },
    );
    expect(await readUsage(first), BigInt.zero);
    await first.call(
      'GET',
      consentPath,
      authenticated: false,
      expectedStatus: 401,
    );
    final grant = await first.call(
      'POST',
      consentPath,
      body: {'expectedRevision': 0},
    );
    expect(grant['enabled'] == true, isTrue, reason: 'consent enabled');
    final direct = grant['conversationId']! as String;
    syncPath = Routes.sync.replaceFirst('{conversationId}', direct);
    final accepted = await first.call(
      'POST',
      Routes.messages.replaceFirst('{conversationId}', direct),
      body: {
        'clientMsgId': 'listener-single-send',
        'kind': 'text',
        'body': {'text': _prompt},
      },
    );
    expect(accepted['duplicate'] == false, isTrue, reason: 'new message');
    sourceId = (accepted['message']! as Map)['messageId']! as String;
    statusPath = Routes.ownerAiReplyStatus
        .replaceFirst('{conversationId}', direct)
        .replaceFirst('{messageId}', sourceId);
    final reply = await readBack(first);
    replyId = reply['id']! as String;
    replyText = reply['text']! as String;
    total = await readUsage(first);
    expect(total > BigInt.zero, isTrue);
    if (!live) {
      expect(replyText == 'synthetic worker reply', isTrue);
      expect(total, BigInt.from(7));
    }
  } finally {
    await first.close();
  }

  final reopened = await _Listener.boot(config, clock, token, remaining);
  try {
    final reply = await readBack(reopened);
    expect(
      reply['id'] == replyId && reply['text'] == replyText,
      isTrue,
      reason: 'same canonical reply after reopening SQLite',
    );
    expect(await readUsage(reopened), total);
  } finally {
    await reopened.close();
  }
  remaining();
  if (live) {
    print(
      'LIVE_LISTENER_OK replyChars=${replyText.length} recordedTokens=$total reopened=true',
    );
  }
}

Future<void> _seed(Host host, Clock clock, String token) async {
  final now = clock.now().millisecondsSinceEpoch;
  String digest(String value) => sha256.convert(utf8.encode(value)).toString();
  await host.auth.store.transaction((state) {
    state.accounts[_owner] = {
      'id': _owner,
      'displayName': 'Synthetic listener owner',
      'kind': 'human',
      'isAdmin': false,
      'disabled': false,
      'passwordHash': 'unused-fixture',
      'failedPasswords': 0,
      'lockedUntil': 0,
    };
    state.devices['listener-device'] = {
      'id': 'listener-device',
      'account': _owner,
      'deviceName': 'synthetic-device',
      'accessHash': digest(token),
      'refreshHash': digest('refresh-$token'),
      'accessExpires': now + const Duration(hours: 1).inMilliseconds,
      'refreshExpires': now + const Duration(days: 1).inMilliseconds,
      'lastUsedAt': now,
    };
    return null;
  });
  final db = host.registry.services.get<Database>();
  await db.transaction((tx) async {
    await tx.execute(
      "INSERT INTO account VALUES (?, 'Synthetic AI', 'ai', 0, 0, NULL, 0, 0)",
      [_aiAccount],
    );
    await tx.execute('INSERT INTO ai_operator VALUES (?, ?)', [
      _aiAccount,
      _owner,
    ]);
    await tx.execute('INSERT INTO ai_profile VALUES (?, ?)', [
      _profile,
      _aiAccount,
    ]);
  });
}

class _Listener {
  _Listener(this.host, this.server, this.serving, this.token, this.remaining);

  final Host host;
  final HttpServer server;
  final Future<void> serving;
  final String token;
  final Duration Function() remaining;

  static Future<_Listener> boot(
    HostConfig config,
    Clock clock,
    String token,
    Duration Function() remaining,
  ) async {
    remaining();
    final host = await buildHost(config: config, clock: clock);
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      return _Listener(
        host,
        server,
        serve(server, host.pipeline),
        token,
        remaining,
      );
    } catch (_) {
      await host.shutdown();
      rethrow;
    }
  }

  Future<Map<String, Object?>> call(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool authenticated = true,
    int expectedStatus = 200,
  }) async {
    final timeout = remaining();
    // One fresh client per request (including status, sync and post-restart reads).
    final client = HttpClient()..findProxy = ((_) => 'DIRECT');
    try {
      return await (() async {
        final request = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:${server.port}$path'),
        );
        request.followRedirects = false;
        if (authenticated) {
          request.headers.set('authorization', 'Bearer $token');
        }
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.add(utf8.encode(jsonEncode(body)));
        }
        final response = await request.close();
        expect(response.statusCode, expectedStatus, reason: 'listener $method');
        final bytes = await response
            .expand((chunk) => chunk)
            .take(1024 * 1024 + 1)
            .toList();
        if (bytes.length > 1024 * 1024) fail('Unexpected oversized HTTP reply');
        try {
          return (jsonDecode(utf8.decode(bytes)) as Map)
              .cast<String, Object?>();
        } on Object {
          fail('Invalid JSON object from listener');
        }
      })().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> close() async {
    try {
      await server.close(force: true);
      await serving;
    } finally {
      final errors = await host.shutdown();
      expect(errors.length, 0, reason: 'host shutdown');
    }
  }
}

// Actually spawned via ProcessHttpTransport; never opens a socket. It validates
// the trusted launch/protocol, then returns only a synthetic completion.
const _responseFixture = r'''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final input = jsonDecode(await utf8.decoder.bind(stdin).join()) as Map;
  final payload = jsonDecode(utf8.decode(base64Decode(input['body'] as String))) as Map;
  final messages = payload['messages'] as List;
  if (args.length != 1 || args.single != '--decode-gzip' || input.length != 6 ||
      input['method'] != 'POST' || input['url'] != 'https://192.0.2.1/v1/chat/completions' ||
      (input['headers'] as Map)['authorization'] != 'Bearer synthetic-listener-key' ||
      payload['model'] != 'auto' || payload['max_tokens'] != 512 || payload['stream'] != false ||
      messages.length != 2 || messages.first['role'] != 'system' ||
      messages.last['role'] != 'user' || messages.last['content'] != '为什么这样？请解释原因。') {
    stdout.writeln('{"ok":false,"code":"unavailable"}');
    return;
  }
  final content = utf8.encode(jsonEncode({
    'choices': [{'message': {'role': 'assistant', 'content': 'synthetic worker reply'}}],
    'usage': {'prompt_tokens': 5, 'completion_tokens': 2, 'total_tokens': 7},
  }));
  stdout.writeln(jsonEncode({'ok': true, 'statusCode': 200, 'headers': {}, 'body': base64Encode(content)}));
}
''';
