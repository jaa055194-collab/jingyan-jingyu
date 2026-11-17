import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/voice_call_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

void main() {
  late HttpServer server;
  late HostConnection connection;
  late VoiceCallApi api;
  late List<(String, String, Map<String, List<String>>)> requests;
  Object? responseBody;
  late int status;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture',
    );
    api = VoiceCallApi(connection);
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

  Map<String, Object?> item(String id) => {
    'callId': id,
    'aiId': 'ai-1',
    'peerAccountId': 'acct-1',
    'state': 'ended',
    'startedAt': '2026-03-01T12:00:00Z',
    'answeredAt': '2026-03-01T12:00:05Z',
    'endedAt': '2026-03-01T12:05:00Z',
  };

  test('exact GET path/query and strict envelope parsing', () async {
    responseBody = {
      'calls': [item('call-1'), item('call-2')],
    };
    final calls = await api.listCalls(
      status: 'ended',
      limit: 2,
      before: DateTime.utc(2026, 3, 5, 6),
    );
    expect(calls.map((c) => c.callId).toList(), ['call-1', 'call-2']);
    expect(calls.first.state, 'ended');
    expect(calls.last.answeredAt, DateTime.utc(2026, 3, 1, 12, 0, 5));
    final (method, path, query) = requests.single;
    expect(method, 'GET');
    expect(path, Routes.voiceCalls);
    expect(query['limit'], ['2']);
    expect(query['status'], ['ended']);
    expect(query['before'], [DateTime.utc(2026, 3, 5, 6).toIso8601String()]);
  });

  test('defaults to limit 50 without filters', () async {
    responseBody = {'calls': []};
    final calls = await api.listCalls();
    expect(calls, isEmpty);
    expect(requests.single.$3, {
      'limit': ['50'],
    });
  });

  test('invalid paging/status never issues a request', () async {
    await expectLater(api.listCalls(limit: 0), throwsFormatException);
    await expectLater(api.listCalls(limit: 101), throwsFormatException);
    await expectLater(api.listCalls(status: 'talking'), throwsFormatException);
    expect(requests, isEmpty);
  });

  test('rejects malformed envelopes/items without leaking payload', () async {
    final payloads = <Object?>[
      [], // must be an envelope, not an array
      {'calls': []}, // fine; keep
      {'calls': [], 'transcript': 'secret-speech'},
      {'attachments': []},
      {'calls': []},
      {
        'calls': [
          {
            'callId': 'call-1',
            'aiId': 'ai-1',
            'peerAccountId': 'acct-1',
            'state': 'talking',
            'startedAt': '2026-03-01T12:00:00Z',
          },
        ],
      },
      {
        'calls': [
          {
            'callId': 'call-1',
            'aiId': 'ai-1',
            'peerAccountId': 'acct-1',
            'state': 'ended',
            'startedAt': '2026-03-01T12:00:00Z',
            'transcript': 'secret-speech',
          },
        ],
      },
      {
        'calls': [42],
      },
    ];
    for (final payload in payloads) {
      responseBody = payload;
      if (payload == const {'calls': []}) continue;
      try {
        await api.listCalls();
        fail('must reject malformed list payload');
      } catch (error) {
        expect(error.toString(), isNot(contains('secret-speech')));
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
            : jsonEncode({
                'calls': [item('call-1')],
              }),
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
      final items = await VoiceCallApi(renewed).listCalls();
      expect(items.single.callId, 'call-1');
      expect(calls, 2);
      expect(renewals, 1);
    } finally {
      await renewed.close();
      await renewServer.close(force: true);
    }
  });
}
