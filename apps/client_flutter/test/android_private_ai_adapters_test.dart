import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/data/android_private_ai_vault.dart';
import 'package:client_flutter/net/android_private_model_api.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _scope = 'ab' * 32;
final _otherScope = 'cd' * 32;
const _providerKey = 'synthetic-provider-only-key';
const _response = '''{
  "id":"completion-test", "object":"chat.completion", "model":"local-model",
  "choices":[{"index":0,"finish_reason":"stop","message":{
    "role":"assistant","content":"测试回复"}}]
}''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('private vault Dart boundary', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('jingyu/platform');
    const vault = AndroidPrivateAiVault();

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test(
      'write/read/remove use only dedicated channel methods and exact scope',
      () async {
        final encryptedSide = <String, Uint8List>{};
        final calls = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map).cast<String, Object?>();
          final scope = args['scope']! as String;
          calls.add('${call.method}:$scope');
          switch (call.method) {
            case 'writePrivateAiVault':
              expect(args.keys, unorderedEquals(['scope', 'bytes']));
              encryptedSide[scope] = args['bytes']! as Uint8List;
              return null;
            case 'readPrivateAiVault':
              expect(args.keys, ['scope']);
              return encryptedSide[scope];
            case 'removePrivateAiVault':
              expect(args.keys, ['scope']);
              encryptedSide.remove(scope);
              return null;
            default:
              fail('Used a method outside the private vault');
          }
        });

        const first = <String, Object?>{
          'credential': _providerKey,
          'turns': [
            {'text': '私聊'},
          ],
        };
        await vault.write(_scope, first);
        await vault.write(_otherScope, {'turns': []});
        expect(await vault.read(_scope), first);
        await vault.remove(_scope);
        expect(await vault.read(_scope), isNull);
        expect(await vault.read(_otherScope), {'turns': []});
        expect(calls, [
          'writePrivateAiVault:$_scope',
          'writePrivateAiVault:$_otherScope',
          'readPrivateAiVault:$_scope',
          'removePrivateAiVault:$_scope',
          'readPrivateAiVault:$_scope',
          'readPrivateAiVault:$_otherScope',
        ]);
      },
    );

    test(
      'unsafe scopes and invalid or oversized writes never reach native',
      () async {
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (_) async {
          calls++;
          return null;
        });
        for (final bad in [
          '../../file',
          'aa',
          'A' * 64,
          'a' * 65,
          '$_scope\n',
        ]) {
          await expectLater(vault.read(bad), throwsA(_vaultError));
          await expectLater(vault.write(bad, {}), throwsA(_vaultError));
          await expectLater(vault.remove(bad), throwsA(_vaultError));
        }
        for (final bad in <Map<String, Object?>>[
          {'turns': '鲸' * (400 * 1024)},
          {'credential': ArgumentError(_providerKey)},
        ]) {
          await expectLater(vault.write(_scope, bad), throwsA(_vaultError));
        }
        expect(calls, 0);
      },
    );

    test(
      'native failure is safe and not mistaken for a missing record',
      () async {
        messenger.setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(
            code: 'private_ai_vault_error',
            message: _providerKey,
            details: {'secret': _providerKey},
          );
        });
        await expectLater(vault.read(_scope), throwsA(_vaultError));
        await expectLater(vault.write(_scope, {}), throwsA(_vaultError));
        await expectLater(vault.remove(_scope), throwsA(_vaultError));
      },
    );

    test(
      'malformed, wrong-type and oversized native data fail safely',
      () async {
        for (final bad in <Object?>[
          _providerKey,
          Uint8List.fromList(utf8.encode('"$_providerKey"')),
          Uint8List.fromList(utf8.encode('{"$_providerKey":')),
          Uint8List(1024 * 1024 + 1),
        ]) {
          messenger.setMockMethodCallHandler(channel, (_) async => bad);
          await expectLater(vault.read(_scope), throwsA(_vaultError));
        }
      },
    );
  });

  group('provider endpoint', () {
    test(
      'requires a full HTTPS endpoint without rewriting its destination',
      () {
        const valid =
            'https://api.example.test:8443/custom/v1/chat/completions';
        final parsed = AndroidPrivateModelApi.parseEndpoint(valid);
        expect(parsed.toString(), valid);
        expect(parsed.host, 'api.example.test');
        expect(parsed.port, 8443);
      },
    );

    test(
      'rejects ambiguous destinations without exposing the supplied URL',
      () {
        for (final invalid in [
          'http://127.0.0.1/v1/chat/completions',
          '//api.example.test/v1/chat/completions',
          'https:///v1/chat/completions',
          'https://api.example.test/v1',
          'https://api.example.test/v1/chat/completions/',
          'https://$_providerKey@api.example.test/v1/chat/completions',
          'https://@api.example.test/v1/chat/completions',
          'https://api.example.test/v1/chat/completions?',
          'https://api.example.test/v1/chat/completions?key=$_providerKey',
          'https://api.example.test/v1/chat/completions#',
          'https://api.example.test:0/v1/chat/completions',
          'https://api.example.test:65536/v1/chat/completions',
          'https://api.example.test:/v1/chat/completions',
          'https://api.example.test/v1/../chat/completions',
          'https://api.example.test/%2e%2e/chat/completions',
          'https://api.example.test/%2Fprefix/chat/completions',
          r'https://api.example.test\another.test/v1/chat/completions',
          'https://api.example.test/v1/chat/completions\n',
        ]) {
          expect(
            () => AndroidPrivateModelApi.parseEndpoint(invalid),
            throwsA(
              isA<FormatException>().having((e) => e.source, 'source', isNull),
            ),
            reason: invalid,
          );
        }
      },
    );
  });

  group('direct provider egress over injected loopback transport', () {
    test(
      'sends one exact, direct, text-only POST with no ambient auth/proxy',
      () async {
        final requests = <Map<String, Object?>>[];
        final server = await _serve((request) async {
          requests.add({
            'method': request.method,
            'path': request.uri.toString(),
            'host': request.headers.value(HttpHeaders.hostHeader),
            'authorization': request.headers.value(
              HttpHeaders.authorizationHeader,
            ),
            'proxyAuthorization': request.headers.value(
              HttpHeaders.proxyAuthorizationHeader,
            ),
            'cookie': request.headers.value(HttpHeaders.cookieHeader),
            'body': jsonDecode(await utf8.decoder.bind(request).join()),
          });
          await _sendJson(request.response, _response);
        });
        final transport = _LoopbackTransport(server);
        final api = AndroidPrivateModelApi();
        addTearDown(api.close);

        expect(await transport.run(() => _reply(api, server)), '测试回复');
        expect(transport.proxyLookups, 0);
        expect(transport.clients, 1);
        expect(requests, [
          {
            'method': 'POST',
            'path': '/custom/v1/chat/completions',
            'host': '127.0.0.1:${server.port}',
            'authorization': 'Bearer $_providerKey',
            'proxyAuthorization': null,
            'cookie': null,
            'body': {
              'model': 'local-model',
              'stream': false,
              'messages': [
                {'role': 'system', 'content': '你是这次选择的人格'},
                {'role': 'user', 'content': '前一轮'},
                {'role': 'assistant', 'content': '前一轮回答'},
                {'role': 'user', 'content': '当前私聊'},
              ],
            },
          },
        ]);
      },
    );

    test(
      'rejects redirect and authentication challenge without replay',
      () async {
        final paths = <String>[];
        final server = await _serve((request) async {
          paths.add(request.uri.path);
          await request.drain<void>();
          if (request.uri.path.startsWith('/redirect/')) {
            request.response.statusCode = HttpStatus.seeOther;
            request.response.headers.set(HttpHeaders.locationHeader, '/trap');
          } else {
            request.response.statusCode = HttpStatus.unauthorized;
            request.response.headers.set(
              HttpHeaders.wwwAuthenticateHeader,
              'Basic realm="trap"',
            );
          }
          await _sendJson(request.response, '{"error":"$_providerKey"}');
        });
        final transport = _LoopbackTransport(server);
        final api = AndroidPrivateModelApi();
        addTearDown(api.close);
        for (final route in [
          '/redirect/chat/completions',
          '/auth/chat/completions',
        ]) {
          await expectLater(
            transport.run(() => _reply(api, server, path: route)),
            throwsA(_modelError(AndroidPrivateModelFailure.rejected)),
          );
        }
        expect(paths, ['/redirect/chat/completions', '/auth/chat/completions']);
      },
    );

    test('invalid inputs fail before creating a connection', () async {
      final server = await _serve(
        (request) => _sendJson(request.response, _response),
      );
      final transport = _LoopbackTransport(server);
      final api = AndroidPrivateModelApi();
      addTearDown(api.close);
      for (final (key, text) in <(String, String)>[
        ('$_providerKey\r\nX-Bad: injected', 'text'),
        (_providerKey, '鲸' * (400 * 1024)),
        (_providerKey, 'do not sync $_providerKey'),
      ]) {
        await expectLater(
          transport.run(() => _reply(api, server, key: key, text: text)),
          throwsA(_modelError(AndroidPrivateModelFailure.invalidInput)),
        );
      }
      expect(transport.clients, 0);
    });

    test(
      'response validation rejects non-text, echoed key and oversized data',
      () async {
        final server = await _serve((request) async {
          await request.drain<void>();
          switch (request.uri.path.split('/')[1]) {
            case 'oversized':
              request.response.headers.contentType = ContentType.json;
              // Chunked, so checking Content-Length alone would not catch this.
              request.response.add(Uint8List(1024 * 1024 + 1));
              await request.response.close();
            case 'echo':
              await _sendJson(
                request.response,
                _response.replaceAll('测试回复', _providerKey),
              );
            case 'malformed':
              await _sendJson(request.response, '{"secret":"$_providerKey",');
            default:
              await _sendJson(
                request.response,
                '''{"choices":[{"message":{
              "role":"assistant","content":null,"tool_calls":[{"id":"tool"}]}}]}''',
              );
          }
        });
        final transport = _LoopbackTransport(server);
        final api = AndroidPrivateModelApi();
        addTearDown(api.close);
        for (final route in ['oversized', 'echo', 'malformed', 'non-text']) {
          await expectLater(
            transport.run(
              () => _reply(api, server, path: '/$route/chat/completions'),
            ),
            throwsA(_modelError(AndroidPrivateModelFailure.invalidResponse)),
          );
        }
      },
    );

    test(
      'close aborts an active request and does not permit future requests',
      () async {
        final connected = Completer<Socket>();
        final server = await _serve((request) async {
          await request.drain<void>();
          connected.complete(
            await request.response.detachSocket(writeHeaders: false),
          );
        });
        final transport = _LoopbackTransport(server);
        final api = AndroidPrivateModelApi();
        addTearDown(api.close);
        final reply = transport.run(() => _reply(api, server));
        final rejected = expectLater(
          reply,
          throwsA(_modelError(AndroidPrivateModelFailure.closed)),
        );
        final socket = await connected.future.timeout(
          const Duration(seconds: 5),
        );
        addTearDown(socket.destroy);
        final ended = _socketEnded(socket);
        api.close();
        await rejected;
        await ended.timeout(const Duration(seconds: 5));
        await expectLater(
          transport.run(() => _reply(api, server)),
          throwsA(_modelError(AndroidPrivateModelFailure.closed)),
        );
        expect(transport.clients, 1);
      },
    );

    test(
      'one deadline covers a peer that never finishes its response',
      () async {
        final connected = Completer<Socket>();
        final server = await _serve((request) async {
          await request.drain<void>();
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'
            'Content-Length: 100\r\n\r\n{',
          );
          await socket.flush();
          connected.complete(socket);
        });
        final transport = _LoopbackTransport(server);
        final api = AndroidPrivateModelApi(timeout: const Duration(seconds: 1));
        addTearDown(api.close);
        final reply = transport.run(() => _reply(api, server));
        final rejected = expectLater(
          reply,
          throwsA(_modelError(AndroidPrivateModelFailure.timeout)),
        );
        final socket = await connected.future.timeout(
          const Duration(seconds: 5),
        );
        addTearDown(socket.destroy);
        final ended = _socketEnded(socket);
        await rejected;
        await ended.timeout(const Duration(seconds: 5));
        expect(transport.clients, 1);
      },
    );
  });
}

final _vaultError = isA<AndroidPrivateAiVaultException>().having(
  (error) => error.toString(),
  'message',
  isNot(contains(_providerKey)),
);

Matcher _modelError(AndroidPrivateModelFailure kind) =>
    isA<AndroidPrivateModelException>()
        .having((error) => error.kind, 'kind', kind)
        .having(
          (error) => error.toString(),
          'message',
          isNot(anyOf(contains(_providerKey), contains('127.0.0.1'))),
        );

Future<String> _reply(
  AndroidPrivateModelApi api,
  HttpServer server, {
  String path = '/custom/v1/chat/completions',
  String key = _providerKey,
  String text = '当前私聊',
}) => api.reply(
  endpoint: 'https://127.0.0.1:${server.port}$path',
  model: 'local-model',
  apiKey: key,
  persona: '你是这次选择的人格',
  text: text,
  history: const [(user: '前一轮', assistant: '前一轮回答')],
);

Future<HttpServer> _serve(Future<void> Function(HttpRequest) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen(handler);
  return server;
}

Future<void> _sendJson(HttpResponse response, String body) async {
  response.headers.contentType = ContentType.json;
  response.write(body);
  await response.close();
}

Future<void> _socketEnded(Socket socket) =>
    socket.drain<void>().onError<SocketException>((_, _) {});

/// Test-only transport: the adapter is given a real [HttpClient] whose socket is
/// a plain loopback connection, so request bytes are observed by a real HTTP
/// server while production code keeps validating an HTTPS destination. No
/// certificate, private key or HTTP exception exists outside this file.
class _LoopbackTransport extends HttpOverrides {
  _LoopbackTransport(this.server);

  final HttpServer server;
  int clients = 0;
  int proxyLookups = 0;

  Future<T> run<T>(Future<T> Function() action) =>
      HttpOverrides.runWithHttpOverrides(action, this);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    return super.createHttpClient(context)
      ..connectionFactory = (uri, proxyHost, proxyPort) {
        if (proxyHost != null || proxyPort != null) {
          throw StateError('Unexpected ambient proxy');
        }
        return Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
      };
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    proxyLookups++;
    return 'PROXY 127.0.0.1:1';
  }
}
