import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/security/guarded_http.dart';
import 'package:jingyu_host/src/security/process_http.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp('process-http-'),
  );
  tearDown(() async => await temp.delete(recursive: true));

  Future<String> script(String source) async {
    final file = File('${temp.path}/worker.dart');
    await file.writeAsString(source);
    return file.path;
  }

  ProcessHttpTransport transport(
    String path, {
    Duration timeout = const Duration(seconds: 15),
    int maxResponseBytes = 1024,
    bool autoUncompress = false,
  }) => ProcessHttpTransport(
    executable: Platform.resolvedExecutable,
    workerPath: path,
    timeout: timeout,
    maxResponseBytes: maxResponseBytes,
    autoUncompress: autoUncompress,
  );

  void safeFailure(Result<GuardedResponse> result) {
    expect(result.isErr, isTrue);
    expect(result.failureOrNull!.details, isEmpty);
    expect('${result.failureOrNull}', isNot(contains('secret-token')));
    expect('${result.failureOrNull}', isNot(contains('private-body')));
  }

  test(
    'credentials use only stdin and response preserves request contract',
    () async {
      final path = await script(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  final request = jsonDecode(await stdin.transform(utf8.decoder).transform(const LineSplitter()).first) as Map;
  final safe = args.isEmpty && !Platform.executableArguments.join().contains('secret-token') &&
    !Platform.environment.values.any((v) => v.contains('secret-token')) &&
    request.keys.toSet().difference({'method','url','headers','body','timeout','maxResponseBytes'}).isEmpty &&
    request['method'] == 'POST' && request['headers']['Authorization'] == 'Bearer secret-token' &&
    utf8.decode(base64Decode(request['body'])) == 'private-body';
  stdout.writeln(jsonEncode({'ok':true,'statusCode':safe ? 201 : 400,'headers':{'x-result':['yes']},'body':base64Encode(utf8.encode('ok'))}));
}
''');
      final result = await transport(path).request(
        'POST',
        Uri.parse('https://api.example/path'),
        headers: {'Authorization': 'Bearer secret-token'},
        body: utf8.encode('private-body'),
      );
      expect(result.isOk, isTrue);
      expect(result.value.statusCode, 201);
      expect(result.value.headers['x-result'], ['yes']);
      expect(utf8.decode(result.value.body), 'ok');
    },
  );

  test(
    'stderr and malformed or oversized stdout fail closed without secrets',
    () async {
      for (final output in [
        "stdout.writeln('secret-token');",
        "stdout.writeln('{\"ok\":false,\"code\":\"unavailable\",\"message\":\"secret-token\"}');",
        "stdout.writeln('{\"ok\":true,\"statusCode\":200,\"headers\":{},\"body\":\"AAECAwQ=\"}');",
        "stdout.write('x' * 200000);",
        "stdout.writeln('{\"ok\":true,\"statusCode\":200,\"headers\":{},\"body\":\"\"}'); stdout.writeln('{}');",
      ]) {
        final path = await script(
          "import 'dart:io'; Future<void> main() async { await stdin.drain<void>(); stderr.writeln('secret-token'); $output }",
        );
        safeFailure(
          await transport(
            path,
            maxResponseBytes: 4,
          ).request('GET', Uri.parse('https://api.example')),
        );
      }
    },
  );

  test(
    'real local TLS success and size failures leave transport reusable',
    () async {
      // Reuse the existing test-only key without modifying its source file.
      final fixtureSource = await File(
        'test/guarded_http_test.dart',
      ).readAsString();
      final fixture = RegExp(
        r"const _tlsFixture =\s*'([^']+)'",
      ).firstMatch(fixtureSource)!.group(1)!;
      final pem = base64Decode(fixture);
      final context = SecurityContext()
        ..useCertificateChainBytes(pem)
        ..usePrivateKeyBytes(pem);
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      final sub = server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer secret-token');
        final body = request.uri.path == '/large' ? 'oversized' : 'ok';
        request.response.persistentConnection = false;
        request.response.contentLength = body.length;
        request.response.write(body);
        await request.response.close();
      });
      addTearDown(() async {
        await sub.cancel();
        await server.close(force: true);
      });
      final path = await script('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  final input = jsonDecode(await stdin.transform(utf8.decoder).transform(const LineSplitter()).first);
  final context = SecurityContext(withTrustedRoots:false)..setTrustedCertificatesBytes(base64Decode('$fixture'));
  final socket = await Socket.connect('127.0.0.1', ${server.port});
  final tls = await SecureSocket.secure(socket, host:'api.example', context:context);
  tls.write('GET \${Uri.parse(input['url']).path} HTTP/1.1\\r\\nHost: api.example\\r\\nAuthorization: \${input['headers']['Authorization']}\\r\\nConnection: close\\r\\n\\r\\n');
  await tls.flush();
  final response = await utf8.decoder.bind(tls).join();
  tls.destroy();
  final body = response.substring(response.indexOf('\\r\\n\\r\\n')+4);
  stdout.writeln(jsonEncode({'ok':true,'statusCode':200,'headers':{},'body':base64Encode(utf8.encode(body))}));
}
''');
      final client = transport(path, maxResponseBytes: 4);
      for (var i = 0; i < 2; i++) {
        safeFailure(
          await client.request(
            'GET',
            Uri.parse('https://api.example/large'),
            headers: {'Authorization': 'Bearer secret-token'},
          ),
        );
        final result = await client.request(
          'GET',
          Uri.parse('https://api.example/ok'),
          headers: {'Authorization': 'Bearer secret-token'},
        );
        expect(result.isOk, isTrue);
        expect(utf8.decode(result.value.body), 'ok');
      }
    },
  );

  test('packaged worker accepts only the single fixed gzip flag', () async {
    final worker = File('bin/http_worker.dart').absolute.path;
    for (final (arguments, expected) in [
      (<String>[], 'forbidden'),
      (['--decode-gzip'], 'forbidden'),
      (['--unknown'], 'unavailable'),
      (['--decode-gzip', '--decode-gzip'], 'unavailable'),
      (['--decode-gzip', '--unknown'], 'unavailable'),
    ]) {
      final child = await Process.start(Platform.resolvedExecutable, [
        worker,
        ...arguments,
      ]);
      try {
        final stdout = utf8.decoder.bind(child.stdout).join();
        final stderr = utf8.decoder.bind(child.stderr).join();
        child.stdin.writeln(
          jsonEncode({
            'method': 'GET',
            'url': 'http://127.0.0.1',
            'headers': {},
            'body': null,
            'timeout': 1000000,
            'maxResponseBytes': 1024,
          }),
        );
        await child.stdin.close();
        expect(await child.exitCode.timeout(const Duration(seconds: 15)), 0);
        expect(await stderr, isEmpty);
        expect(jsonDecode(await stdout), {
          'ok': false,
          'code': expected,
        }, reason: 'argv: $arguments');
      } finally {
        child.kill();
      }
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('production worker rejects localhost with no local bypass', () async {
    final client = transport(File('bin/http_worker.dart').absolute.path);
    for (final url in [
      'http://localhost',
      'http://127.0.0.1',
      'https://[::1]',
    ]) {
      final result = await client.request(
        'GET',
        Uri.parse(url),
        headers: {'Authorization': 'Bearer secret-token'},
      );
      safeFailure(result);
      expect(result.failureOrNull!.code, FailureCode.forbidden);
    }
  });

  test(
    'parent deadline kills actual stalled TLS child and closes peer repeatedly',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final accepted = StreamController<Socket>();
      final listener = server.listen((socket) {
        sockets.add(socket);
        accepted.add(socket);
      });
      final peers = StreamIterator(accepted.stream);
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await peers.cancel();
        await listener.cancel();
        await accepted.close();
        await server.close();
      });
      final path = await script('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  await File(${jsonEncode('${temp.path}/pid')}).writeAsString('\$pid');
  final socket = await Socket.connect('127.0.0.1', ${server.port});
  await SecureSocket.secure(socket, host: 'api.example');
}
''');
      final client = transport(
        path,
        timeout: const Duration(seconds: 6),
        autoUncompress: true,
      );
      for (var i = 0; i < 3; i++) {
        final resultFuture = client.request(
          'GET',
          Uri.parse('https://api.example'),
        );
        expect(
          await peers.moveNext().timeout(const Duration(seconds: 8)),
          isTrue,
        );
        final closed = Completer<void>();
        peers.current.listen(
          (_) {},
          onDone: () => closed.complete(),
          onError: (Object _) {
            if (!closed.isCompleted) closed.complete();
          },
        );
        final childPid = int.parse(
          await File('${temp.path}/pid').readAsString(),
        );
        safeFailure(await resultFuture);
        await closed.future.timeout(const Duration(seconds: 2));
        expect(
          Process.killPid(childPid, ProcessSignal.sigkill),
          isFalse,
          reason: 'request must await actual child exit',
        );
      }
      final successPath = await script(
        "import 'dart:io'; Future<void> main() async { await stdin.drain<void>(); stdout.writeln('{\"ok\":true,\"statusCode\":200,\"headers\":{},\"body\":\"b2s=\"}'); }",
      );
      expect(
        (await transport(
          successPath,
        ).request('GET', Uri.parse('https://api.example'))).isOk,
        isTrue,
      );
    },
  );

  test(
    'concurrent requests are bounded and capacity returns after deadlines',
    () async {
      final path = await script(
        "import 'dart:io'; Future<void> main() async { await stdin.drain<void>(); await Future<void>.delayed(const Duration(seconds:30)); }",
      );
      final client = transport(
        path,
        timeout: const Duration(milliseconds: 1200),
      );
      final running = List.generate(
        4,
        (_) => client.request('GET', Uri.parse('https://api.example')),
      );
      final watch = Stopwatch()..start();
      safeFailure(
        await client.request('GET', Uri.parse('https://api.example')),
      );
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
      for (final result in await Future.wait(running)) {
        safeFailure(result);
      }
      final good = await script(
        "import 'dart:io'; Future<void> main() async { await stdin.drain<void>(); stdout.writeln('{\"ok\":true,\"statusCode\":200,\"headers\":{},\"body\":\"\"}'); }",
      );
      expect(
        (await transport(
          good,
        ).request('GET', Uri.parse('https://api.example'))).isOk,
        isTrue,
      );
    },
  );
}
