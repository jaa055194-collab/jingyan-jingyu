import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/attachment_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

void main() {
  late HttpServer server;
  late HostConnection connection;
  late AttachmentApi api;
  late List<(String, String, Map<String, List<String>>)> requests;
  Object? responseBody;
  late int status;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture',
    );
    api = AttachmentApi(connection);
    requests = [];
    responseBody = null;
    status = 200;
    server.listen((request) async {
      await request.drain<void>();
      requests.add((
        request.method,
        request.uri.path,
        request.uri.queryParametersAll,
      ));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      if (responseBody != null) {
        request.response.write(jsonEncode(responseBody));
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  Map<String, Object?> item(String id, {String? conversation}) => {
    'id': id,
    'conversationId': conversation,
    'kind': 'image',
    'mime': 'image/png',
    'size': 1234,
    'extractionStatus': 'extracted',
    'createdAt': '2026-03-01T12:00:00Z',
  };

  test('builds exact GET query and parses metadata-only array', () async {
    responseBody = [item('att-1', conversation: 'conv-1'), item('att-2')];
    final items = await api.listAttachments(
      conversationId: 'conv-1',
      limit: 2,
      before: DateTime.utc(2026, 3, 5, 6),
    );
    expect(items.map((e) => e.id).toList(), ['att-1', 'att-2']);
    expect(items.first.conversationId, 'conv-1');
    expect(items.last.conversationId, isNull);
    expect(items.first.extractionStatus, 'extracted');
    final (method, path, query) = requests.single;
    expect(method, 'GET');
    expect(path, Routes.attachments);
    expect(query['limit'], ['2']);
    expect(query['conversationId'], ['conv-1']);
    expect(query['before'], [DateTime.utc(2026, 3, 5, 6).toIso8601String()]);
  });

  test('defaults to limit 50 without conversation filter', () async {
    responseBody = [];
    final items = await api.listAttachments();
    expect(items, isEmpty);
    expect(requests.single.$3, {
      'limit': ['50'],
    });
  });

  test('rejects invalid paging/parameter before any request', () async {
    await expectLater(api.listAttachments(limit: 0), throwsFormatException);
    await expectLater(api.listAttachments(limit: 101), throwsFormatException);
    await expectLater(
      api.listAttachments(conversationId: 'bad id!'),
      throwsFormatException,
    );
    expect(requests, isEmpty);
  });

  test('rejects items leaking extractedText/bytes or malformed', () async {
    final payloads = <Object?>[
      [
        {...item('att-1'), 'extractedText': 'secret-body'},
      ],
      [
        {...item('att-1'), 'bytes': 'base64'},
      ],
      [
        {...item('att-1'), 'sha256': 'deadbeef'},
      ],
      [
        {...item('att-1'), 'size': -1},
      ],
      [
        {...item('att-1'), 'extractionStatus': 'unknown-status'},
      ],
      {'attachments': <Object?>[]}, // envelope not an array
    ];
    for (final payload in payloads) {
      responseBody = payload;
      try {
        await api.listAttachments();
        fail('must reject malformed list payload');
      } catch (error) {
        expect(error.toString(), isNot(contains('secret-body')));
        expect(error.toString(), isNot(contains('base64')));
      }
    }
  });

  test('bounded inherited 401 replays at most once', () async {
    var calls = 0;
    final renewServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    renewServer.listen((request) async {
      await request.drain<void>();
      calls++;
      request.response.statusCode = calls == 1 ? 401 : 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        calls == 1
            ? '{"error":"unauthenticated"}'
            : jsonEncode([item('att-1')]),
      );
      await request.response.close();
    });
    var renewals = 0;
    final renewed = HostConnection(
      Uri.parse('http://127.0.0.1:${renewServer.port}'),
      'stale',
      onUnauthorized: () async {
        renewals++;
        return true;
      },
    );
    try {
      final items = await AttachmentApi(renewed).listAttachments();
      expect(items.single.id, 'att-1');
      expect(calls, 2);
      expect(renewals, 1);
    } finally {
      await renewed.close();
      await renewServer.close(force: true);
    }
  });
}
