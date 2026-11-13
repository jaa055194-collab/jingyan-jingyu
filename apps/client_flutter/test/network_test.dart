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
