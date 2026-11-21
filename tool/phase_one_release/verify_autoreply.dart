// Independent release drill, run from the repository root. No real data or
// credentials; the shipping worker's outbound URL policy is never changed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const _prompt = '为什么这样？请解释原因。';
const _prefix = '/api/v1';
const _providerPath = '$_prefix/model-providers';
const _testNetBase = 'https://192.0.2.1/v1';
const _reply = 'release fixture reply';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

String nonce() {
  final random = Random.secure();
  return base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
}

Future<void> main(List<String> args) async {
  if (args.length != 1 ||
      !const ['base-red', 'base-explicit'].contains(args.single)) {
    stderr.writeln(
      'Usage: dart tool/phase_one_release/verify_autoreply.dart base-red|base-explicit',
    );
    exitCode = 64;
    return;
  }
  final expectsReply = args.single == 'base-explicit';
  final hostDir = Directory('apps/host').absolute;
  check(
    File('${hostDir.path}/bin/server.dart').existsSync(),
    'Run from repository root',
  );
  final sdkBin = File(Platform.resolvedExecutable).parent.path;
  final launcher = File('$sdkBin/${Platform.isWindows ? 'dart.exe' : 'dart'}');
  check(launcher.existsSync(), 'Dart SDK launcher missing');
  final temporary = await Directory.systemTemp.createTemp(
    'jingyu-release-drill-',
  );
  final fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  final password = nonce();
  final providerKey = 'fixture-${nonce()}';
  var fixtureCalls = 0;
  fixture.listen((request) async {
    fixtureCalls++;
    try {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      check(
        request.method == 'POST' && request.uri.path == '/v1/chat/completions',
        'Wrong completion route',
      );
      check(
        request.headers.value('authorization') == 'Bearer $providerKey',
        'Wrong fixture credential',
      );
      check(
        body['model'] == 'auto' &&
            (body['messages'] as List).last['content'] == _prompt,
        'Unexpected fixture completion request',
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'id': 'release-fixture-completion',
          'object': 'chat.completion',
          'model': 'auto',
          'created': 0,
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': _reply},
              'finish_reason': 'stop',
            },
          ],
          'usage': {
            'prompt_tokens': 5,
            'completion_tokens': 2,
            'total_tokens': 7,
          },
        }),
      );
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
    } finally {
      await request.response.close();
    }
  });
  final mode = args.single;
  final environment = <String, String>{
    if (Platform.isWindows && Platform.environment['SystemRoot'] != null)
      'SystemRoot': Platform.environment['SystemRoot']!,
    if (Platform.environment['USERPROFILE'] != null)
      'USERPROFILE': Platform.environment['USERPROFILE']!,
    if (Platform.environment['LOCALAPPDATA'] != null)
      'LOCALAPPDATA': Platform.environment['LOCALAPPDATA']!,
    if (Platform.environment['TEMP'] != null)
      'TEMP': Platform.environment['TEMP']!,
    if (Platform.environment['HOME'] != null)
      'HOME': Platform.environment['HOME']!,
    if (Platform.environment['PUB_CACHE'] != null)
      'PUB_CACHE': Platform.environment['PUB_CACHE']!,
    for (final name in const [
      'APPDATA',
      'PROGRAMDATA',
      'SystemDrive',
      'windir',
      'TMP',
      'PATH',
    ])
      if (Platform.environment[name] != null) name: Platform.environment[name]!,
    'JINGYU_DATA_DIR': '${temporary.path}/data',
    'JINGYU_BIND': '127.0.0.1',
  };
  Process? host;
  Future<void> stopHost() async {
    final process = host;
    if (process == null) return;
    host = null;
    if (Platform.isWindows) {
      // dart.exe can have a separate VM child, the real socket owner.
      final taskkill =
          '${Platform.environment['SystemRoot']}\\System32\\taskkill.exe';
      await Process.run(taskkill, ['/PID', '${process.pid}', '/T', '/F']);
    } else {
      process.kill(ProcessSignal.sigint);
    }
    await process.exitCode.timeout(const Duration(seconds: 8));
  }

  var origin = '';
  String? token;
  Future<Map<String, dynamic>> call(
    String method,
    String path, {
    Map<String, Object?>? body,
    int status = 200,
  }) async {
    final request = await client
        .openUrl(method, Uri.parse('$origin$path'))
        .timeout(const Duration(seconds: 5));
    request.followRedirects = false;
    if (token != null) request.headers.set('authorization', 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final response = await request.close().timeout(const Duration(seconds: 35));
    final result = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 5));
    check(
      response.statusCode == status,
      '$method $path: HTTP ${response.statusCode}, expected $status',
    );
    return (jsonDecode(result) as Map).cast<String, dynamic>();
  }

  Future<void> startHost() async {
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = reservation.port;
    await reservation.close();
    origin = 'http://127.0.0.1:$port';
    final process = await Process.start(
      launcher.path,
      ['run', 'bin/server.dart'],
      workingDirectory: hostDir.path,
      environment: {...environment, 'JINGYU_PORT': '$port'},
      includeParentEnvironment: false,
    );
    host = process;
    unawaited(process.stdin.close());
    unawaited(process.stderr.drain<void>());
    final bound = Completer<void>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (!bound.isCompleted &&
              line.startsWith('jingyu host ') &&
              line.endsWith(' listening on 127.0.0.1:$port')) {
            print(line);
            bound.complete();
          }
        });
    unawaited(
      process.exitCode.then((code) {
        if (!bound.isCompleted)
          bound.completeError(StateError('Host exited before binding: $code'));
      }),
    );
    await bound.future.timeout(const Duration(seconds: 60));
    check(
      (await call('GET', '$_prefix/health'))['status'] == 'ok',
      'Host health not OK',
    );
  }

  try {
    print('MODE=$mode ISOLATED_DATA=true LAUNCH=dart run bin/server.dart');
    final init = await Process.run(
      launcher.path,
      ['run', 'bin/init_accounts.dart'],
      workingDirectory: hostDir.path,
      environment: {
        ...environment,
        'JINGYU_ADMIN_NAME': 'Release drill administrator',
        'JINGYU_ADMIN_PASSWORD': password,
      },
      includeParentEnvironment: false,
    ).timeout(const Duration(seconds: 90));
    final account = RegExp(r'Administrator account:\s*([A-Za-z0-9_-]+)')
        .firstMatch(init.stdout as String)
        ?.group(1);
    final failed = RegExp(r'Administrator initialization failed: (\w+)')
        .firstMatch(init.stderr as String)
        ?.group(1);
    check(
      init.exitCode == 0 && account != null,
      'Administrator initialization exit ${init.exitCode} ${failed ?? ''}',
    );
    print('INITIALIZE exit=0');
    if (expectsReply) {
      final worker = await File(
        'tool/phase_one_release/reply_fixture_worker.dart',
      ).copy('${temporary.path}/fixture_worker.dart');
      await File('${temporary.path}/fixture.port')
          .writeAsString('${fixture.port}');
      environment['JINGYU_MODEL_WORKER_EXECUTABLE'] = launcher.path;
      environment['JINGYU_MODEL_WORKER_PATH'] = worker.path;
    }
    print(
      'WORKER_EXECUTABLE=${environment.containsKey('JINGYU_MODEL_WORKER_EXECUTABLE') ? 'set' : 'unset'} WORKER_PATH=${environment.containsKey('JINGYU_MODEL_WORKER_PATH') ? 'set' : 'unset'}',
    );
    await startHost();
    token =
        (await call(
              'POST',
              '$_prefix/auth/login',
              body: {
                'accountId': account,
                'password': password,
                'deviceName': 'release drill',
              },
            ))['accessToken']
            as String;
    final ai =
        (await call(
              'POST',
              '$_prefix/accounts/me/ai',
              body: {'displayName': 'Release fixture AI'},
            ))['accountId']
            as String;
    final registered = await call(
      'POST',
      '$_prefix/ai-profiles/register',
      body: {'accountId': ai},
    );
    final profilePath = '$_prefix/ai-profiles/${registered['profileId']}';
    Map<String, Object?> providerBody(String base) => {
      'name': 'Release fixture only',
      'base_url': base,
      'api_key': providerKey,
      'capabilities': ['chat'],
    };
    final blocked = await call(
      'POST',
      _providerPath,
      body: providerBody('http://127.0.0.1:${fixture.port}/v1'),
      status: 403,
    );
    check(
      blocked['error'] == 'forbidden' && fixtureCalls == 0,
      'Production URL guard must block loopback',
    );
    print('PROVIDER_LOOPBACK http=403 error=forbidden fixtureCalls=0');
    final provider = await call(
      'POST',
      _providerPath,
      body: providerBody(_testNetBase),
    );
    await call(
      'PUT',
      '$profilePath/bindings/chat',
      body: {'providerId': provider['id'], 'model': 'auto'},
    );
    await call(
      'PUT',
      '$profilePath/budget',
      body: {
        'dailyTokens': 10000,
        'offsetMinutes': 0,
        'layerLimits': {
          'b0Life': 0,
          'b1FastBrain': 0,
          'b2DeepChat': 10000,
          'b3Proactive': 0,
          'b4Maintenance': 0,
        },
        'capabilityLimits': {
          'chat': 10000,
          'chatFast': 0,
          'vision': 0,
          'imageGen': 0,
          'tts': 0,
          'asr': 0,
          'embedding': 0,
        },
      },
    );
    await call(
      'POST',
      '$profilePath/persona/initialize',
      body: {
        'p0': {'name': 'Release fixture AI'},
        'p1': {'style': 'concise'},
        'p2': {'mood': 'calm'},
      },
    );
    await call('PUT', '$profilePath/social-level', body: {'level': 'L0'});
    final grant = await call(
      'POST',
      '$profilePath/direct-conversation',
      body: {'expectedRevision': 0},
    );
    check(
      grant['enabled'] == true && grant['scope'] == 'ownerTextOnly',
      'Expected owner private chat consent',
    );
    print(
      'HTTP_SETUP login=200 ai=200 profile=200 provider=200 binding=200 budget=200 persona=200 level=L0 consent=ownerTextOnly',
    );
    final conversation = '$_prefix/conversations/${grant['conversationId']}';
    final accepted = await call(
      'POST',
      '$conversation/messages',
      body: {
        'clientMsgId': 'release-fixture-single-send',
        'kind': 'text',
        'body': {'text': _prompt},
      },
    );
    check(accepted['duplicate'] == false, 'Expected a new private message');
    final source = accepted['message']['messageId'] as String;
    final statusPath = '$conversation/messages/$source/owner-reply';
    final timer = Stopwatch()..start();
    Map<String, dynamic> status;
    do {
      status = await call('GET', statusPath);
      if (const ['completed', 'failed', 'discarded'].contains(status['status']))
        break;
      await Future<void>.delayed(const Duration(milliseconds: 125));
    } while (timer.elapsed < const Duration(seconds: 30));
    final rows = (await call('GET', '$conversation/sync'))['messages'] as List;
    final usage = (await call('GET', '$profilePath/usage'))['recordedTokens'];
    print(
      'AUTO_REPLY status=${status['status']} failure=${status['failureCode'] ?? '-'} syncRows=${rows.length} fixtureCalls=$fixtureCalls recordedTokens=$usage',
    );
    check(
      rows.isNotEmpty &&
          rows.first['seq'] == 1 &&
          rows.first['messageId'] == source &&
          rows.first['senderId'] == account,
      'Owner message must be canonical',
    );
    if (!expectsReply) {
      check(
        status['status'] == 'failed' &&
            status['failureCode'] == 'model_unavailable' &&
            status['replyMessageId'] == null &&
            rows.length == 1 &&
            fixtureCalls == 0 &&
            usage == '0',
        'RED did not reproduce expected failure',
      );
      print('BASE_RED_REPRODUCED');
      return;
    }
    check(
      status['status'] == 'completed' &&
          rows.length == 2 &&
          fixtureCalls == 1 &&
          usage == '7',
      'Expected exactly one S2 reply and seven settled tokens',
    );
    final reply = rows.last as Map;
    check(
      reply['seq'] == 2 &&
          reply['senderId'] == ai &&
          reply['messageId'] == status['replyMessageId'] &&
          reply['body']['source'] == 's2' &&
          reply['body']['text'] == _reply,
      'Expected the fixture completion in canonical history',
    );
    await stopHost();
    await startHost();
    final after = (await call('GET', '$conversation/sync'))['messages'] as List;
    check(
      after.length == 2 &&
          after.last['messageId'] == reply['messageId'] &&
          after.last['body']['text'] == _reply &&
          fixtureCalls == 1,
      'Persisted reply missing after reopening',
    );
    print('BASE_EXPLICIT_GREEN canonical=true reopened=true fixtureCalls=1');
  } finally {
    try {
      await stopHost();
    } finally {
      client.close(force: true);
      await fixture.close(force: true);
      // `temporary` is the exact directory allocated by systemTemp above.
      await temporary.delete(recursive: true);
    }
  }
}
