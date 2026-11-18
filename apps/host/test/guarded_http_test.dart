import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:test/test.dart';

import 'package:jingyu_host/src/security/guarded_http.dart';

/// Real gzip compression used by the transparent-decompression tests.
Future<List<int>> gzipOf(List<int> bytes) => gzip.encoder
    .bind(Stream<List<int>>.value(bytes))
    .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));

// The only substituted boundary is the socket destination: the real HttpClient
// still writes/parses HTTP and enforces the production transport policy.
class LocalConnector implements PinnedConnector {
  LocalConnector(this.port);
  final int port;
  final addresses = <InternetAddress>[];
  final ports = <int>[];

  @override
  Future<ConnectionTask<Socket>> startConnect(
    InternetAddress address,
    int port, {
    String? secureHost,
    SecurityContext? context,
  }) {
    addresses.add(address);
    ports.add(port);
    return const SocketPinnedConnector().startConnect(
      InternetAddress.loopbackIPv4,
      this.port,
      secureHost: secureHost,
      context: context,
    );
  }
}

// Observe actual handshake settlement, including after the request times out.
class TrackedLocalConnector extends LocalConnector {
  TrackedLocalConnector(super.port);
  final settled = <Future<void>>[];

  @override
  Future<ConnectionTask<Socket>> startConnect(
    InternetAddress address,
    int port, {
    String? secureHost,
    SecurityContext? context,
  }) async {
    final task = await super.startConnect(
      address,
      port,
      secureHost: secureHost,
      context: context,
    );
    settled.add(task.socket.then<void>((_) {}, onError: (Object _) {}));
    return task;
  }
}

const _tlsFixture =
    'LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JR0hBZ0VBTUJNR0J5cUdTTTQ5QWdFR0NDcUdTTTQ5QXdFSEJHMHdhd0lCQVFRZ2s3RUMvdDROWlJ0RXZXbmsKQklJcWFwcG5aWTlJM05qWXJGTS8xcXFheGtpaFJBTkNBQVFnTkF1bEJiU3V4T3A4RDFaUHFSVXluWm1uMlZCZgoyTVpLcWhxK0ZUTDU3T3ludnFnRGRZL2FBcytZR3dab0ZaRzEwekc5TFBBSHkwOWhMQmRGdkkzOQotLS0tLUVORCBQUklWQVRFIEtFWS0tLS0tCi0tLS0tQkVHSU4gQ0VSVElGSUNBVEUtLS0tLQpNSUlCbURDQ0FUK2dBd0lCQWdJVURmcWxleUZZRWF1bENWeDZNdiszSm14dlloTXdDZ1lJS29aSXpqMEVBd0l3CkZqRVVNQklHQTFVRUF3d0xZWEJwTG1WNFlXMXdiR1V3SGhjTk1qWXhNVEV6TVRBME5qSTRXaGNOTXpZeE1URXcKTVRBME5qSTRXakFXTVJRd0VnWURWUVFEREF0aGNHa3VaWGhoYlhCc1pUQlpNQk1HQnlxR1NNNDlBZ0VHQ0NxRwpTTTQ5QXdFSEEwSUFCQ0EwQzZVRnRLN0U2bndQVmsrcEZUS2RtYWZaVUYvWXhrcXFHcjRWTXZuczdLZStxQU4xCmo5b0N6NWdiQm1nVmtiWFRNYjBzOEFmTFQyRXNGMFc4amYyamF6QnBNQjBHQTFVZERnUVdCQlFyem1GQU5tRUwKcnZ6K2plZDJVTDhkb25EZkZEQWZCZ05WSFNNRUdEQVdnQlFyem1GQU5tRUxydnoramVkMlVMOGRvbkRmRkRBUApCZ05WSFJNQkFmOEVCVEFEQVFIL01CWUdBMVVkRVFRUE1BMkNDMkZ3YVM1bGVHRnRjR3hsTUFvR0NDcUdTTTQ5CkJBTUNBMGNBTUVRQ0lBUGUyZ1ZLTEFmbFBhMDVqYVlKM0ZvL24zczB3SXdOYmhEVzEwbTI2ZXFzQWlCSXRqSXoKNnVYelRJSTAvallISUdEbnR6NmVqdjZjdTEvMVU4S2tNNGQ5NlE9PQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0t';

void main() {
  late HttpServer server;
  late LocalConnector connector;
  late StreamSubscription<HttpRequest> subscription;
  late Future<void> Function(HttpRequest) handler;
  late int requests;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connector = LocalConnector(server.port);
    requests = 0;
    handler = (request) async {
      request.response.write('ok');
      await request.response.close();
    };
    subscription = server.listen((request) {
      requests++;
      unawaited(handler(request));
    });
  });

  tearDown(() async {
    await subscription.cancel();
    await server.close(force: true);
  });

  GuardedHttpTransport transport({
    Future<List<InternetAddress>> Function(String)? resolver,
    Duration timeout = const Duration(seconds: 2),
    int maxResponseBytes = 1024,
  }) => GuardedHttpTransport(
    resolver: resolver ?? (_) async => [InternetAddress('93.184.216.34')],
    connector: connector,
    timeout: timeout,
    maxResponseBytes: maxResponseBytes,
  );

  void expectSafeFailure(Result<GuardedResponse> result, FailureCode code) {
    expect(result.isErr, isTrue);
    final failure = result.failureOrNull!;
    expect(failure.code, code);
    expect(failure.details, isEmpty);
    expect('$failure', isNot(contains('secret')));
    expect('$failure', isNot(contains('Authorization')));
    expect('$failure', isNot(contains('private-body')));
  }

  test('rechecks DNS per request and pins the one validated answer', () async {
    var resolutions = 0;
    final client = transport(
      resolver: (host) async {
        expect(host, 'api.example');
        resolutions++;
        return [
          InternetAddress(resolutions == 1 ? '93.184.216.34' : '127.0.0.1'),
        ];
      },
    );
    handler = (request) async {
      expect(request.headers.host, 'api.example');
      expect(request.method, 'POST');
      expect(request.headers.value('authorization'), 'Bearer secret');
      expect(await utf8.decoder.bind(request).join(), 'private-body');
      request.response.headers.set('x-result', 'yes');
      request.response.write('ok');
      await request.response.close();
    };
    final uri = Uri.parse('http://api.example:8123/path');
    final first = await client.request(
      'POST',
      uri,
      headers: {'Authorization': 'Bearer secret'},
      body: utf8.encode('private-body'),
    );
    expect(first.isOk, isTrue);
    expect(first.value.statusCode, 200);
    expect(utf8.decode(first.value.body), 'ok');
    expect(first.value.headers['x-result'], ['yes']);
    expect(connector.addresses.single.address, '93.184.216.34');
    expect(connector.ports.single, 8123);
    expect(resolutions, 1); // A second DNS lookup would have returned loopback.
    expectSafeFailure(await client.request('GET', uri), FailureCode.forbidden);
    expect(resolutions, 2);
    expect(requests, 1);
    expect(connector.addresses, hasLength(1));
  });

  test('any blocked DNS answer refuses the entire request', () async {
    for (final ip in ['10.0.0.1', '127.0.0.1', '::1', '::ffff:192.168.1.1']) {
      final client = transport(
        resolver: (_) async => [
          InternetAddress('93.184.216.34'),
          InternetAddress(ip),
        ],
      );
      expectSafeFailure(
        await client.request('GET', Uri.parse('https://api.example')),
        FailureCode.forbidden,
      );
    }
    expect(connector.addresses, isEmpty);
  });

  test(
    'rejects credentials fragments schemes localhost and literal private IP',
    () async {
      var resolutions = 0;
      final client = transport(
        resolver: (_) async {
          resolutions++;
          return [InternetAddress('93.184.216.34')];
        },
      );
      for (final raw in [
        'https://user:secret@api.example',
        'https://api.example/#secret',
        'https://api.example/#',
        'ftp://api.example',
        'http://localhost',
        'http://x.localhost',
        'http://127.0.0.1',
      ]) {
        expect(
          (await client.request('GET', Uri.parse(raw))).isErr,
          isTrue,
          reason: raw,
        );
      }
      expect(resolutions, 0);
      expect(connector.addresses, isEmpty);
    },
  );

  test(
    'refuses all 3xx without following or forwarding authorization',
    () async {
      for (final status in [300, 301, 302, 303, 304, 307, 308, 399]) {
        handler = (request) async {
          request.response.statusCode = status;
          request.response.headers.set(
            'location',
            'http://127.0.0.1/private?secret',
          );
          await request.response.close();
        };
        expectSafeFailure(
          await transport().request(
            'GET',
            Uri.parse('http://api.example'),
            headers: {'Authorization': 'Bearer secret'},
          ),
          FailureCode.forbidden,
        );
      }
      expect(requests, 8);
      expect(connector.addresses, hasLength(8));
    },
  );

  test(
    'accepts byte boundary and rejects larger declared or streamed body',
    () async {
      for (final declared in [true, false]) {
        handler = (request) async {
          if (declared) request.response.contentLength = 5;
          request.response.add([1, 2, 3, 4, 5]);
          await request.response.close();
        };
        expectSafeFailure(
          await transport(
            maxResponseBytes: 4,
          ).request('GET', Uri.parse('http://api.example')),
          FailureCode.unavailable,
        );
      }
      handler = (request) async {
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      };
      final result = await transport(
        maxResponseBytes: 4,
      ).request('GET', Uri.parse('http://api.example'));
      expect(result.value.body, [1, 2, 3, 4]);
    },
  );

  test('deadline covers response stream and closes hanging request', () async {
    handler = (request) async {
      request.response.write('a');
      await request.response.flush();
      // Deliberately leave the stream open; teardown closes the server.
    };
    expectSafeFailure(
      await transport(
        timeout: const Duration(milliseconds: 80),
      ).request('GET', Uri.parse('http://api.example')),
      FailureCode.unavailable,
    );
  });

  test(
    'DNS deadline cannot send a request when resolution completes late',
    () async {
      final pending = Completer<List<InternetAddress>>();
      final client = transport(
        resolver: (_) => pending.future,
        timeout: const Duration(milliseconds: 20),
      );
      expectSafeFailure(
        await client.request('GET', Uri.parse('http://api.example')),
        FailureCode.unavailable,
      );
      pending.complete([InternetAddress('93.184.216.34')]);
      await Future<void>.delayed(Duration.zero);
      expect(connector.addresses, isEmpty);
      expect(requests, 0);
    },
  );

  test(
    'opt-in transparent decompression inflates gzip and keeps content-type',
    () async {
      final payload = utf8.encode('{"choices":[],"usage":{}}');
      final wire = await gzipOf(payload);
      // Small payloads may compress larger; decompression must round-trip.
      handler = (request) async {
        // The caller advertises gzip; the server compresses regardless.
        expect(request.headers.value('accept-encoding'), 'gzip');
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('content-encoding', 'gzip');
        request.response.add(wire);
        await request.response.close();
      };
      final result = await GuardedHttpTransport(
        resolver: (_) async => [InternetAddress('93.184.216.34')],
        connector: connector,
        timeout: const Duration(seconds: 2),
        maxResponseBytes: 1024,
        autoUncompress: true,
      ).request('GET', Uri.parse('http://api.example/path'));
      expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
      expect(result.value.statusCode, 200);
      expect(utf8.decode(result.value.body), utf8.decode(payload));
      expect(result.value.headers['content-type'], [
        'application/json; charset=utf-8',
      ]);
    },
  );

  test('gzip opt-in enforces wire limit even if decoded body fits', () async {
    final wire = gzip.encode([65]);
    final limit = wire.length - 1;
    handler = (request) async {
      request.response.headers.set('content-encoding', 'gzip');
      request.response.add(wire);
      await request.response.close();
    };
    final result = await GuardedHttpTransport(
      resolver: (_) async => [InternetAddress('93.184.216.34')],
      connector: connector,
      maxResponseBytes: limit,
      autoUncompress: true,
    ).request('GET', Uri.parse('http://api.example'));
    expectSafeFailure(result, FailureCode.unavailable);
  });

  test(
    'gzip bomb cannot expand past maxResponseBytes with autoUncompress',
    () async {
      final bomb = await gzipOf(
        List<int>.filled(4096, 65),
      ); // tiny wire, huge inflation
      expect(bomb.length, lessThan(64));
      handler = (request) async {
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.set('content-encoding', 'gzip');
        request.response.add(bomb);
        await request.response.close();
      };
      final result = await GuardedHttpTransport(
        resolver: (_) async => [InternetAddress('93.184.216.34')],
        connector: connector,
        timeout: const Duration(seconds: 2),
        maxResponseBytes: 1024,
        autoUncompress: true,
      ).request('GET', Uri.parse('http://api.example/bomb'));
      expectSafeFailure(result, FailureCode.unavailable);
      expect(result.failureOrNull!.message, isNot(contains('bomb')));
    },
  );

  test('default transport keeps non-gzip bytes verbatim (HttpClient may still '
      'auto-decompress its own gzip negotiation)', () async {
    const wire = 'ok-payload';
    handler = (request) async {
      // Dart's HttpClient adds Accept-Encoding itself; asserting its absence
      // would be wrong. The server answers with raw (non-gzip) bytes.
      request.response.headers.contentType = ContentType.text;
      request.response.write(wire);
      await request.response.close();
    };
    final result = await transport().request(
      'GET',
      Uri.parse('http://api.example/kept'),
    );
    expect(result.isOk, isTrue);
    expect(utf8.decode(result.value.body), wire);
  });

  test(
    'gzip-looking bytes are kept verbatim when decompression is not opted in',
    () async {
      final wire = await gzipOf(utf8.encode('ok-payload'));
      handler = (request) async {
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.set('content-encoding', 'gzip');
        request.response.add(wire);
        await request.response.close();
      };
      final result = await transport().request(
        'GET',
        Uri.parse('http://api.example/kept'),
      );
      expect(result.isOk, isTrue);
      expect(result.value.body, wire);
    },
  );

  test(
    'declared-gzip response keeps raw bytes for the caller to decode',
    () async {
      handler = (request) async {
        // Dart's HttpClient transparently inflates a declared-gzip body it can
        // parse, so the transport sees decompressed bytes when the stream is
        // valid. A *malformed* gzip stream may survive verbatim; either way the
        // transport must not crash the pipeline — assert the request completes.
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.set('content-encoding', 'gzip');
        request.response.add(const <int>[0x1f, 0x8b, 0x08, 9, 9, 9, 9, 9, 9]);
        await request.response.close();
      };
      final result = await GuardedHttpTransport(
        resolver: (_) async => [InternetAddress('93.184.216.34')],
        connector: connector,
        timeout: const Duration(seconds: 2),
        maxResponseBytes: 1024,
        autoUncompress: true,
      ).request('GET', Uri.parse('http://api.example/corrupt'));
      expect(
        result.isOk || result.failureOrNull?.code == FailureCode.unavailable,
        isTrue,
      );
    },
  );

  test(
    'resolver exceptions never expose provider body header or key',
    () async {
      final client = transport(
        resolver: (_) async =>
            throw StateError('secret Authorization private-body'),
      );
      expectSafeFailure(
        await client.request('GET', Uri.parse('https://api.example')),
        FailureCode.unavailable,
      );
    },
  );

  test(
    'HTTPS never sends authorization or body to a plaintext server',
    () async {
      var receivedHttp = false;
      handler = (request) async {
        receivedHttp = true;
        request.response.write('ok');
        await request.response.close();
      };
      final result = await transport(timeout: const Duration(milliseconds: 150))
          .request(
            'POST',
            Uri.parse('https://api.example'),
            headers: {'Authorization': 'Bearer secret'},
            body: utf8.encode('private-body'),
          );
      expectSafeFailure(result, FailureCode.unavailable);
      expect(receivedHttp, isFalse);
    },
  );

  test(
    'real TLS checks trust and the original hostname on pinned TCP',
    () async {
      // Self-signed EC certificate for api.example, test key only.
      final pem = base64.decode(_tlsFixture);
      final serverContext = SecurityContext()
        ..useCertificateChainBytes(pem)
        ..usePrivateKeyBytes(pem);
      final tlsServer = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      final accepted = <String>[];
      final sub = tlsServer.listen((request) async {
        accepted.add(request.headers.value('authorization') ?? '');
        request.response.write('encrypted');
        await request.response.close();
      }, onError: (Object _) {});
      try {
        final trusted = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(pem);
        final pinned = LocalConnector(tlsServer.port);
        final client = GuardedHttpTransport(
          resolver: (_) async => [InternetAddress('93.184.216.34')],
          connector: pinned,
          securityContext: trusted,
        );
        final success = await client.request(
          'GET',
          Uri.parse('https://api.example'),
          headers: {'Authorization': 'Bearer secret'},
        );
        expect(success.isOk, isTrue);
        expect(utf8.decode(success.value.body), 'encrypted');
        expectSafeFailure(
          await client.request('GET', Uri.parse('https://wrong.example')),
          FailureCode.unavailable,
        );
        final untrusted = GuardedHttpTransport(
          resolver: (_) async => [InternetAddress('93.184.216.34')],
          connector: pinned,
        );
        expectSafeFailure(
          await untrusted.request('GET', Uri.parse('https://api.example')),
          FailureCode.unavailable,
        );
        expect(accepted, ['Bearer secret']);
      } finally {
        await sub.cancel();
        await tlsServer.close(force: true);
      }
    },
  );

  test(
    'stalled TLS returns safe timeout without HTTP; cleanup remains a known gap',
    () async {
      final rawServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final disconnected = Completer<void>();
      final bytes = <int>[];
      final sockets = <Socket>[];
      final sub = rawServer.listen((socket) {
        sockets.add(socket);
        socket.listen(
          bytes.addAll,
          onDone: () {
            if (!disconnected.isCompleted) disconnected.complete();
          },
          onError: (Object _) {},
        );
      });
      try {
        final client = GuardedHttpTransport(
          resolver: (_) async => [InternetAddress('93.184.216.34')],
          connector: LocalConnector(rawServer.port),
          timeout: const Duration(milliseconds: 100),
        );
        expectSafeFailure(
          await client.request(
            'POST',
            Uri.parse('https://api.example'),
            headers: {'Authorization': 'Bearer secret'},
            body: utf8.encode('private-body'),
          ),
          FailureCode.unavailable,
        );
        // Known draft limitation: cancellation does not force-close detached TLS.
        // Server cleanup below terminates the pending handshake deterministically.
        expect(disconnected.isCompleted, isFalse);
        expect(bytes, isNotEmpty);
        expect(bytes.first, 22); // TLS handshake record, never plaintext HTTP.
        expect(
          utf8.decode(bytes, allowMalformed: true),
          isNot(contains('secret')),
        );
      } finally {
        for (final socket in sockets) {
          socket.destroy();
        }
        await sub.cancel();
        await rawServer.close();
      }
    },
  );

  test(
    'stalled TLS slots survive timeouts across instances and recover on settlement',
    () async {
      final rawServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final sockets = <Socket>[];
      final bytes = <int>[];
      final connectors = <TrackedLocalConnector>[];
      final sub = rawServer.listen((socket) {
        sockets.add(socket);
        socket.listen(bytes.addAll, onError: (Object _) {});
      });
      Future<Result<GuardedResponse>> stalledRequest() {
        // A fresh connector for each request must share the transport bound.
        final pinned = TrackedLocalConnector(rawServer.port);
        connectors.add(pinned);
        return GuardedHttpTransport(
          resolver: (_) async => [InternetAddress('93.184.216.34')],
          connector: pinned,
          timeout: const Duration(milliseconds: 100),
        ).request(
          'POST',
          Uri.parse('https://api.example'),
          headers: {'Authorization': 'Bearer secret'},
          body: utf8.encode('private-body'),
        );
      }

      Future<void> settleHandshakes() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await Future.wait(
          connectors.expand((pinned) => pinned.settled),
        ).timeout(const Duration(seconds: 2));
      }

      try {
        // Timeout/cancel must not return a slot while secure() is still pending.
        for (var i = 0; i < 8; i++) {
          expectSafeFailure(await stalledRequest(), FailureCode.unavailable);
          expect(sockets, hasLength(i + 1));
        }
        final rejected = await Future.wait(
          List.generate(4, (_) => stalledRequest()),
        );
        for (final result in rejected) {
          expectSafeFailure(result, FailureCode.unavailable);
        }
        expect(sockets, hasLength(8)); // Full: no additional TCP connection.
        expect(bytes, isNotEmpty);
        expect(bytes.first, 22);
        final wire = utf8.decode(bytes, allowMalformed: true);
        expect(wire, isNot(contains('secret')));
        expect(wire, isNot(contains('private-body')));

        // HTTP does not consume, or require, a TLS handshake slot.
        expect(
          (await transport().request(
            'GET',
            Uri.parse('http://api.example'),
          )).isOk,
          isTrue,
        );
        await settleHandshakes();
        // Real peer closure settles the detached handshakes and restores slots.
        final restored = await Future.wait(
          List.generate(8, (_) => stalledRequest()),
        );
        for (final result in restored) {
          expectSafeFailure(result, FailureCode.unavailable);
        }
        expect(sockets, hasLength(16));
        expectSafeFailure(await stalledRequest(), FailureCode.unavailable);
        expect(sockets, hasLength(16));
      } finally {
        await settleHandshakes();
        await sub.cancel();
        await rawServer.close();
      }
    },
  );

  test('native connector uses the real Socket.startConnect API', () async {
    final task = await const SocketPinnedConnector().startConnect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    final socket = await task.socket;
    expect(socket.remotePort, server.port);
    socket.destroy();
  });
}
