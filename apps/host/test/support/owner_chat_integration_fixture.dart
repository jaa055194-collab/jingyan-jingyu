// Subprocess for the opt-in Flutter owner-chat acceptance test. Not a deployed
// server: it owns a disposable DB, binds only loopback, and takes shutdown on stdin.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2 ||
      args.length > 3 ||
      (args.length == 3 && args.last != 'reject-reply')) {
    throw ArgumentError('Expected fresh test data path, port, [reject-reply]');
  }
  final data = Directory(args.first).absolute;
  final port = int.parse(args[1]);
  final fresh = port == 0;
  final rejectReply = args.length == 3;
  final input = StreamIterator<String>(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  if (!await input.moveNext()) throw StateError('Missing parent configuration');
  final setup = (jsonDecode(input.current) as Map).cast<String, Object?>();
  final password = setup['password'];
  if (fresh && (password is! String || password.length < 12)) {
    throw StateError('Invalid synthetic bootstrap password');
  }
  final worker = File('${data.path}/fixture_worker.dart');
  if (fresh) {
    if (await FileSystemEntity.type(data.path) !=
        FileSystemEntityType.notFound) {
      throw StateError('Owner-chat fixture requires a fresh data directory');
    }
    await data.create();
    await worker.writeAsString(
      _worker.replaceFirst('__REJECT__', rejectReply.toString()),
    );
  } else if (!await worker.exists()) {
    throw StateError('Owner-chat fixture restart requires its existing worker');
  }
  final host = await buildHost(
    config: HostConfig(
      dataDir: data.path,
      modelWorkerExecutable: Platform.resolvedExecutable,
      modelWorkerPath: worker.path,
    ),
  );
  try {
    final owner = fresh
        ? (await host.auth.bootstrapAdmin(
            displayName: 'Synthetic owner',
            password: password as String,
          )).value.value
        : null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final serving = serve(server, _ObservedPipeline(host.pipeline));
    try {
      stdout.writeln(
        jsonEncode({'event': 'ready', 'port': server.port, 'owner': owner}),
      );
      await stdout.flush();
      while (await input.moveNext()) {
        if (input.current == 'stop') break;
        throw StateError('Unexpected owner-chat fixture control message');
      }
    } finally {
      await input.cancel();
      await server.close(force: true);
      await serving;
    }
  } finally {
    if ((await host.shutdown()).isNotEmpty) {
      throw StateError('Owner-chat fixture host did not shut down cleanly');
    }
  }
}

/// Keep the real listener and authorization/dispatch pipeline on both sides of
/// the restart. The trace contains only route metadata and sync row counts, not
/// headers, credentials, requests or message bodies.
class _ObservedPipeline extends Pipeline {
  _ObservedPipeline(this.delegate)
    : super(router: delegate.router, authenticate: delegate.authenticate);
  final Pipeline delegate;

  @override
  Future<HostResponse> handle(HostRequest request) async {
    final response = await delegate.handle(request);
    final after = request.query['afterSeq'];
    final body = response.json;
    final rows = body is Map ? body['messages'] : null;
    stdout.writeln(
      jsonEncode({
        'method': request.method,
        'path': request.path,
        'status': response.status,
        'afterSeq': ?after,
        if (rows is List) 'rows': rows.length,
      }),
    );
    return response;
  }
}

// Same ProcessHttpTransport stdin/stdout seam as host_live_listener_test.dart.
// This worker never opens a socket. The configured endpoint is a numeric TEST-
// NET address, avoiding DNS or any external provider in the fixture.
const _worker = r'''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final input = jsonDecode(await utf8.decoder.bind(stdin).join()) as Map;
  final payload = jsonDecode(utf8.decode(base64Decode(input['body'] as String))) as Map;
  final messages = payload['messages'] as List;
  if (__REJECT__ || args.length != 1 || args.single != '--decode-gzip' ||
      input['method'] != 'POST' ||
      input['url'] != 'https://192.0.2.1/v1/chat/completions' ||
      payload['model'] != 'auto' || payload['max_tokens'] != 512 ||
      payload['stream'] != false || messages.length != 2 ||
      messages.first['role'] != 'system' || messages.last['role'] != 'user' ||
      messages.last['content'] != '为什么这样？请解释原因。') {
    stdout.writeln('{"ok":false,"code":"unavailable"}');
    return;
  }
  final content = utf8.encode(jsonEncode({
    'choices': [{'message': {'role': 'assistant', 'content': 'synthetic worker reply'}}],
    'usage': {'prompt_tokens': 5, 'completion_tokens': 2, 'total_tokens': 7},
  }));
  stdout.writeln(jsonEncode({
    'ok': true,
    'statusCode': 200,
    'headers': {},
    'body': base64Encode(content),
  }));
}
''';
