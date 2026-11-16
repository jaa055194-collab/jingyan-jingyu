/// Synthetic rules-S1 demo. No provider, no model call, no production changes.
/// Run from apps/host: dart run tool/demo_s1.dart [--data-dir PATH] [--port 8787] [--keep]
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

const demoAccount = 'demo_human';
const demoAi = 'demo_ai';
const demoGroup = 'demo_group';
const _marker = 'demo_s1.synthetic';
const _markerValue = 'jingyu isolated synthetic rules S1 demo v1';
const _fixtureConfig = 'demo_s1.fixture.local.json';

/// The real restart/close boundary calls this guard before claiming success.
void checkDemoShutdownErrors(List<Object> errors) {
  if (errors.isNotEmpty) {
    throw StateError('Demo host shutdown failed (${errors.length} errors)');
  }
}

class DemoS1 {
  DemoS1._(this.dataDir, this.port, this.passphrase);
  final String dataDir;
  final int port;

  /// Runtime-generated synthetic credential, persisted only in local dataDir.
  /// Tests may read it without printing it; never add it to evidence.
  final String passphrase;
  Host? _host;
  HttpServer? _server;
  final HttpClient _http = HttpClient();
  String? _token;
  String get origin => 'http://127.0.0.1:${_server!.port}';

  static Future<DemoS1> open(String dataDir, {int port = 0}) async {
    final directory = Directory(dataDir).absolute;
    if (await directory.exists()) {
      final files = await directory.list().toList();
      final marker = File('${directory.path}/$_marker');
      if (files.isNotEmpty &&
          (!await marker.exists() ||
              await marker.readAsString() != _markerValue)) {
        throw StateError(
          'Refusing non-demo nonempty dataDir: ${directory.path}',
        );
      }
    } else {
      await directory.create(recursive: true);
    }
    final config = File('${directory.path}/$_fixtureConfig');
    final String passphrase;
    if (await config.exists()) {
      final Object? parsed = jsonDecode(await config.readAsString());
      if (parsed is! Map<String, Object?> ||
          parsed['accountId'] != demoAccount ||
          parsed['passphrase'] is! String ||
          (parsed['passphrase']! as String).length < 32) {
        throw StateError('Invalid local synthetic fixture credentials');
      }
      passphrase = parsed['passphrase']! as String;
    } else {
      // Never silently rotate credentials on an existing database: the saved
      // production hash would no longer match. Legacy fixed-secret demos must
      // use a fresh directory instead.
      if (await File('${directory.path}/host.sqlite').exists()) {
        throw StateError(
          'Existing demo database has no local credentials; use a fresh demo directory',
        );
      }
      final random = Random.secure();
      passphrase = base64UrlEncode(
        List<int>.generate(32, (_) => random.nextInt(256)),
      ).replaceAll('=', '');
      await config.writeAsString(
        jsonEncode({'accountId': demoAccount, 'passphrase': passphrase}),
        flush: true,
      );
    }
    await File('${directory.path}/$_marker').writeAsString(_markerValue);
    final demo = DemoS1._(directory.path, port, passphrase);
    try {
      await demo._start();
      await demo._seed();
      return demo;
    } catch (_) {
      await demo.close();
      rethrow;
    }
  }

  Future<void> _start() async {
    _host = await buildHost(config: HostConfig(dataDir: dataDir));
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    unawaited(serve(_server!, _host!.pipeline));
  }

  Future<void> _seed() async {
    final db = _host!.registry.services.get<Database>();
    if ((await db.query('SELECT id FROM account WHERE id=?', [
      demoAccount,
    ])).isNotEmpty) {
      return;
    }
    // Real production PBKDF2 hash: HTTP /auth/login is not bypassed.
    final hash = await PasswordHasher().hashAsync(passphrase);
    await db.transaction((tx) async {
      await tx.execute("INSERT INTO account VALUES(?,?,'human',1,0,?,0,0)", [
        demoAccount,
        'Synthetic S1 demo human',
        hash,
      ]);
      await tx.execute("INSERT INTO account VALUES(?,?,'ai',0,0,NULL,0,0)", [
        demoAi,
        'Synthetic rules S1 AI',
      ]);
      await tx.execute('INSERT INTO ai_operator VALUES(?,?)', [
        demoAi,
        demoAccount,
      ]);
      await tx.execute('INSERT INTO ai_profile VALUES(?,?)', [
        'demo_profile',
        demoAi,
      ]);
      await tx.execute(
        "INSERT INTO social_conversations VALUES(?,?,?,'all',0)",
        [demoGroup, demoAccount, 'Synthetic S1 demo group'],
      );
      for (final member in [demoAccount, demoAi]) {
        await tx.execute('INSERT INTO social_members VALUES(?,?,0,1)', [
          demoGroup,
          member,
        ]);
      }
      await tx.execute(
        'INSERT INTO group_ai_settings VALUES(?,30000,1,10,0,600000,0,0)',
        [demoGroup],
      );
      await tx.execute('INSERT INTO ai_social_levels VALUES(?,?,?,?)', [
        demoAccount,
        'demo_profile',
        'L1',
        const SystemClock().now().toUtc().toIso8601String(),
      ]);
      await tx.execute(
        'INSERT INTO usage_budget(owner_id,ai_id,daily_tokens,layer_limits,capability_limits,offset_minutes) VALUES(?,?,?,?,?,?)',
        [
          demoAccount,
          'demo_profile',
          '100',
          jsonEncode({for (final layer in BudgetLayer.values) layer.name: '0'}),
          jsonEncode({
            for (final capability in [
              'chat',
              'chatFast',
              'vision',
              'imageGen',
              'tts',
              'asr',
              'embedding',
            ])
              capability: capability == 'chatFast' ? '100' : '0',
          }),
          480,
        ],
      );
    });
  }

  Future<Map<String, Object?>> _call(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool authenticated = true,
  }) async {
    final request = await _http.openUrl(method, Uri.parse('$origin$path'));
    request.headers.contentType = ContentType.json;
    if (authenticated) request.headers.set('authorization', 'Bearer $_token');
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != 200) {
      throw StateError('$method $path: ${response.statusCode} $text');
    }
    return (jsonDecode(text) as Map).cast<String, Object?>();
  }

  Future<void> _login() async {
    final result = await _call(
      'POST',
      Routes.authLogin,
      authenticated: false,
      body: {
        'accountId': demoAccount,
        'password': passphrase,
        'deviceName': 'synthetic-s1-demo',
      },
    );
    _token = result['accessToken']! as String;
  }

  Future<List<Map<String, Object?>>> _sync() async {
    final result = await _call(
      'GET',
      Routes.sync.replaceFirst('{conversationId}', demoGroup),
    );
    return (result['messages']! as List)
        .map((row) => (row as Map).cast<String, Object?>())
        .toList();
  }

  /// All observable demo actions go through real TCP HTTP + production pipeline.
  Future<Map<String, Object?>> verifyRoundTrip() async {
    await _login();
    final groups = await _call('GET', Routes.conversations);
    final visible = (groups['conversations']! as List).any(
      (row) => (row as Map)['id'] == demoGroup,
    );
    if (!visible) throw StateError('Demo group missing from HTTP group list');
    await _call(
      'POST',
      Routes.messages.replaceFirst('{conversationId}', demoGroup),
      body: {
        'clientMsgId': 'demo-s1-hello-v1',
        'kind': 'text',
        'body': {
          'text': '你好',
          'mentionAccountIds': [demoAi],
        },
      },
    );
    final before = await _sync();
    final replies = before.where((row) => row['senderId'] == demoAi).toList();
    if (before.length != 2 || replies.length != 1) {
      throw StateError(
        'Expected exactly human + canonical S1 reply; got ${before.length}',
      );
    }
    final reply = replies.single;
    final body = (reply['body']! as Map).cast<String, Object?>();
    if (body['text'] != '你好呀' || body['source'] != 's1') {
      throw StateError('Expected canonical curated rules-S1 hello reply');
    }
    await _stopHost();
    await _start(); // Same database + DPAPI-wrapped key, new host and HTTP listener.
    await _login();
    final after = await _sync();
    final persisted = after.singleWhere((row) => row['senderId'] == demoAi);
    if (after.length != 2 ||
        persisted['messageId'] != reply['messageId'] ||
        (persisted['body']! as Map)['text'] != '你好呀') {
      throw StateError('Canonical reply did not survive same-database restart');
    }
    return {
      'demo': 'synthetic rules-S1, NOT model chat',
      'loginStatus': 200,
      'groupVisible': visible,
      'senderId': reply['senderId'],
      'text': body['text'],
      'source': body['source'],
      'messagesBeforeRestart': before.length,
      'messagesAfterRestart': after.length,
      'canonicalId': reply['messageId'],
      'canonicalIdAfterRestart': persisted['messageId'],
      'originAfterRestart': origin,
      'dataDir': dataDir,
    };
  }

  Future<void> _stopHost() async {
    await _server?.close(force: true);
    _server = null;
    final host = _host;
    _host = null;
    final errors = await host?.shutdown();
    if (errors != null) checkDemoShutdownErrors(errors);
  }

  Future<void> close() async {
    _http.close(force: true);
    await _stopHost();
  }
}

Future<void> main(List<String> args) async {
  String? directory;
  var port = 8787;
  var keep = false;
  for (var index = 0; index < args.length; index++) {
    switch (args[index]) {
      case '--data-dir':
        directory = args[++index];
      case '--port':
        port = int.parse(args[++index]);
        if (port < 0 || port > 65535) throw ArgumentError('Invalid port');
      case '--keep':
        keep = true;
      default:
        throw ArgumentError('Unknown option ${args[index]}');
    }
  }
  directory ??= (await Directory.systemTemp.createTemp('jingyu-demo-s1-')).path;
  final demo = await DemoS1.open(directory, port: port);
  try {
    final evidence = await demo.verifyRoundTrip();
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(evidence));
    if (keep) {
      stdout.writeln(
        'Synthetic login: accountId=$demoAccount; passphrase=${demo.passphrase}',
      );
      stdout.writeln(
        'KEEP listening ${demo.origin}; Ctrl+C stops host; database is retained.',
      );
      await ProcessSignal.sigint.watch().first;
    }
  } finally {
    await demo.close();
  }
}
