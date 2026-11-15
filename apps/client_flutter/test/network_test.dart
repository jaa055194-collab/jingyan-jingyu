import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

void main() {
  late HttpServer server;
  late HostConnection connection;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'device-token',
    );
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  for (final status in [200, 204]) {
    test('explicit empty-success option accepts HTTP $status', () async {
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = status;
        await request.response.close();
      });
      final result = await connection.request(
        'POST',
        '/membership',
        body: {'accountId': 'member'},
        allowEmptySuccess: true,
      );
      expect(result, isEmpty);
    });
  }

  test('default map-response mode still rejects empty successful body', () async {
    server.listen((request) async {
      await request.drain<void>();
      await request.response.close();
    });
    await expectLater(
      connection.request('GET', '/map-response'),
      throwsFormatException,
    );
  });

  test('empty-success option still strictly parses every nonempty response',
      () async {
    final bodies = [' ', 'not-json', 'null', '[]', '{"ok":true}'];
    var next = 0;
    server.listen((request) async {
      await request.drain<void>();
      request.response.write(bodies[next++]);
      await request.response.close();
    });
    for (var i = 0; i < 4; i++) {
      await expectLater(
        connection.request('POST', '/membership', allowEmptySuccess: true),
        throwsFormatException,
      );
    }
    expect(
      await connection.request('POST', '/membership', allowEmptySuccess: true),
      {'ok': true},
    );
  });

  test('401 retry preserves empty-success option and original request data',
      () async {
    await connection.close();
    var renewals = 0;
    final requests = <({String? bearer, String method, String uri, Object? body})>[];
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'expired',
      onUnauthorized: () async {
        renewals++;
        connection.updateAccessToken('rotated');
        return true;
      },
    );
    server.listen((request) async {
      requests.add((
        bearer: request.headers[HttpHeaders.authorizationHeader]?.single,
        method: request.method,
        uri: request.uri.toString(),
        body: jsonDecode(await utf8.decoder.bind(request).join()),
      ));
      request.response.statusCode = requests.length == 1 ? 401 : 200;
      if (requests.length == 1) {
        request.response.write('{"error":"unauthenticated"}');
      }
      await request.response.close();
    });
    expect(
      await connection.request(
        'POST',
        '/membership',
        query: {'fixture': 'value'},
        body: {'accountId': 'member'},
        allowEmptySuccess: true,
      ),
      isEmpty,
    );
    expect(renewals, 1);
    expect(requests.map((request) => request.bearer), [
      'Bearer expired',
      'Bearer rotated',
    ]);
    for (final request in requests) {
      expect(request.method, 'POST');
      expect(request.uri, '/membership?fixture=value');
      expect(request.body, {'accountId': 'member'});
    }
  });

  test('empty-success option never accepts an unsuccessful empty response',
      () async {
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 404;
      await request.response.close();
    });
    await expectLater(
      connection.request('POST', '/membership', allowEmptySuccess: true),
      throwsA(
        isA<HostRequestException>().having(
          (error) => error.failure.code,
          'failure code',
          FailureCode.notFound,
        ),
      ),
    );
  });

  test(
    'permanently rejected queue head is dropped and next message sends',
    () async {
      final submitted = <String>[];
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        submitted.add(body['clientMsgId'] as String);
        request.response.statusCode = submitted.length == 1 ? 403 : 200;
        request.response.write(
          submitted.length == 1 ? '{"error":"forbidden"}' : '{}',
        );
        await request.response.close();
      });
      final outbox = Outbox();
      final first = outbox.enqueue('conversation-a', MessageKind.text, {
        'text': 'rejected',
      });
      final second = outbox.enqueue('conversation-b', MessageKind.text, {
        'text': 'allowed',
      });
      final dropped = <FailureCode>[];
      final report = await outbox.flush(
        (item) => connection.submit(
          OutboxSubmission(item.conversationId, {
            'clientMsgId': item.clientMsgId,
            'kind': item.kind.wire,
            'body': item.body,
          }),
        ),
        onDropped: (_, failure) => dropped.add(failure.code),
      );
      expect(submitted, [first, second]);
      expect(dropped, [FailureCode.forbidden]);
      expect(report.sent, 1);
      expect(report.remaining, 0);
    },
  );

  test(
    'expired credentials preserve queued message for later authentication',
    () async {
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 401;
        request.response.write('{"error":"unauthenticated"}');
        await request.response.close();
      });
      final outbox = Outbox();
      final id = outbox.enqueue('conversation-a', MessageKind.text, {
        'text': 'private',
      });
      final report = await outbox.flush(
        (item) => connection.submit(
          OutboxSubmission(item.conversationId, {
            'clientMsgId': item.clientMsgId,
          }),
        ),
      );
      expect(report.remaining, 1);
      expect(outbox.items.single.clientMsgId, id);
    },
  );

  test('401 renews once and retries request with rotated bearer', () async {
    var renewals = 0;
    final headers = <String?>[];
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'expired',
      onUnauthorized: () async {
        renewals++;
        connection.updateAccessToken('rotated');
        return true;
      },
    );
    server.listen((request) async {
      headers.add(request.headers.value(HttpHeaders.authorizationHeader));
      await request.drain<void>();
      request.response.statusCode = headers.length == 1 ? 401 : 200;
      request.response.write(
        headers.length == 1 ? '{"error":"unauthenticated"}' : '{}',
      );
      await request.response.close();
    });
    expect(
      (await connection.submit(
        const OutboxSubmission('a', {'clientMsgId': 'same'}),
      )).isOk,
      isTrue,
    );
    expect(renewals, 1);
    expect(headers, ['Bearer expired', 'Bearer rotated']);
  });
  test('refresh does not loop when retry remains unauthorized', () async {
    var renewals = 0, requests = 0;
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'expired',
      onUnauthorized: () async {
        renewals++;
        return true;
      },
    );
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      request.response.statusCode = 401;
      request.response.write('{"error":"unauthenticated"}');
      await request.response.close();
    });
    final result = await connection.submit(
      const OutboxSubmission('a', {'clientMsgId': 'same'}),
    );
    expect(result.failureOrNull?.code, FailureCode.unavailable);
    expect(renewals, 1);
    expect(requests, 2);
  });

  for (final fixture in [
    (
      status: 400,
      body: '{"error":"invalid_argument"}',
      code: FailureCode.invalidArgument,
    ),
    (status: 404, body: 'not found', code: FailureCode.notFound),
    (
      status: 429,
      body: '{"error":"rate_limited"}',
      code: FailureCode.rateLimited,
    ),
    (
      status: 429,
      body: '{"error":"budget_exhausted"}',
      code: FailureCode.budgetExhausted,
    ),
    (
      status: 503,
      body: '{"error":"unavailable"}',
      code: FailureCode.unavailable,
    ),
  ]) {
    test(
      'HTTP ${fixture.status} ${fixture.code.name} preserves failure classification',
      () async {
        server.listen((request) async {
          await request.drain<void>();
          request.response.statusCode = fixture.status;
          request.response.write(fixture.body);
          await request.response.close();
        });
        final result = await connection.submit(
          const OutboxSubmission('conversation-a', {
            'clientMsgId': 'stable-id',
          }),
        );
        expect(result.failureOrNull?.code, fixture.code);
      },
    );
  }
}
