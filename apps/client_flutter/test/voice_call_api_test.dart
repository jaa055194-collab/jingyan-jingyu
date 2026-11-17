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
  late List<(String, String)> requests;
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
      requests.add((request.method, request.uri.path));
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

  Map<String, Object?> json({bool withOptional = true}) => {
    'callId': 'call-1',
    'aiId': 'ai-1',
    'peerAccountId': 'acct-1',
    'state': 'active',
    'startedAt': '2026-03-01T12:00:00Z',
    if (withOptional) ...{
      'answeredAt': '2026-03-01T12:00:05Z',
      'endedAt': '2026-03-01T12:05:00Z',
    },
  };

  test('reads one call with exact GET path and strict metadata', () async {
    responseBody = json();
    final call = await api.readCall('call-1');
    expect(call.callId, 'call-1');
    expect(call.aiId, 'ai-1');
    expect(call.peerAccountId, 'acct-1');
    expect(call.state, 'active');
    expect(call.startedAt, DateTime.utc(2026, 3, 1, 12));
    expect(call.answeredAt, DateTime.utc(2026, 3, 1, 12, 0, 5));
    expect(call.endedAt, DateTime.utc(2026, 3, 1, 12, 5));
    final (method, path) = requests.single;
    expect(method, 'GET');
    expect(path, Routes.voiceCall.replaceAll('{callId}', 'call-1'));
  });

  test('optional timestamps may be absent', () async {
    responseBody = json(withOptional: false);
    final call = await api.readCall('call-1');
    expect(call.answeredAt, isNull);
    expect(call.endedAt, isNull);
  });

  test('rejects malformed snapshots and invalid ids before request', () async {
    final payloads = <Object?>[
      {...json(), 'state': 'unknown-state'},
      {...json(), 'transcript': 'secret-speech'},
      {...json(), 'callId': 'bad id!'},
      {...json(), 'startedAt': 'not-a-time'},
      {'aiId': 'ai-1', 'peerAccountId': 'a', 'state': 'active'},
    ];
    for (final payload in payloads) {
      responseBody = payload;
      try {
        await api.readCall('call-1');
        fail('must reject malformed call snapshot');
      } catch (error) {
        expect(error.toString(), isNot(contains('secret-speech')));
      }
    }
    await expectLater(api.readCall('bad id!'), throwsFormatException);
    await expectLater(api.readCall(''), throwsFormatException);
    expect(requests.where((r) => r.$1 == 'GET').length, 5);
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
        calls == 1 ? '{"error":"unauthenticated"}' : jsonEncode(json()),
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
      final call = await VoiceCallApi(renewed).readCall('call-1');
      expect(call.callId, 'call-1');
      expect(calls, 2);
      expect(renewals, 1);
    } finally {
      await renewed.close();
      await renewServer.close(force: true);
    }
  });
}
