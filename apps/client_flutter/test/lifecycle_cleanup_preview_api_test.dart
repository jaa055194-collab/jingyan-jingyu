import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/lifecycle_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

void main() {
  late HttpServer server;
  late HostConnection connection;
  late LifecycleApi api;
  late List<(String, String, String?)> requests;
  Object? responseBody;
  late int status;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture',
    );
    api = LifecycleApi(connection);
    requests = [];
    responseBody = null;
    status = 200;
    server.listen((request) async {
      await request.drain<void>();
      requests.add((
        request.method,
        request.uri.toString(),
        request.headers.value(HttpHeaders.authorizationHeader),
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

  Map<String, Object?> previewJson() => {
    'dayKey': '2026-03-01',
    'remindSoon': {'video': 1, 'voice': 0},
    'expiring': {'video': 2, 'voice': 3},
    'totalHeld': {'video': 4, 'voice': 5},
  };

  test('cleanup preview uses exact GET path and parses strict DTO', () async {
    responseBody = previewJson();
    final preview = await api.readCleanupPreview();
    expect(preview.dayKey, '2026-03-01');
    expect(preview.remindSoon, {'video': 1, 'voice': 0});
    expect(preview.expiring, {'video': 2, 'voice': 3});
    expect(preview.totalHeld, {'video': 4, 'voice': 5});
    expect(requests.single.$1, 'GET');
    expect(requests.single.$2, Routes.lifecycleCleanupPreview);
    expect(requests.single.$3, 'Bearer fixture');
  });

  test('rejects malformed previews without leaking payload', () async {
    final payloads = <Object?>[
      {}, // missing fields
      {
        'dayKey': '2026-03-01',
        'remindSoon': {},
        'expiring': {},
        'totalHeld': {},
      }, // missing kinds
      {
        'dayKey': 'not-a-date',
        'remindSoon': {'video': 0, 'voice': 0},
        'expiring': {'video': 0, 'voice': 0},
        'totalHeld': {'video': 0, 'voice': 0},
      },
      {
        'dayKey': '2026-03-01',
        'remindSoon': {'video': -1, 'voice': 0},
        'expiring': {'video': 0, 'voice': 0},
        'totalHeld': {'video': 0, 'voice': 0},
      },
      {
        'dayKey': '2026-03-01',
        'remindSoon': {'video': 0, 'voice': 0, 'image': 1},
        'expiring': {'video': 0, 'voice': 0},
        'totalHeld': {'video': 0, 'voice': 0},
      },
      {
        'dayKey': '2026-03-01',
        'remindSoon': {},
        'expiring': {},
        'totalHeld': {},
        'api_key': 'leaked-key',
      },
      'raw-private-payload',
    ];
    for (final payload in payloads) {
      responseBody = payload;
      try {
        await api.readCleanupPreview();
        fail('must reject malformed cleanup preview');
      } catch (error) {
        expect(error.toString(), isNot(contains('raw-private-payload')));
        expect(error.toString(), isNot(contains('leaked-key')));
      }
    }
  });

  test('maps HTTP failure to a safe error without leaking bearer', () async {
    status = 500;
    await expectLater(
      api.readCleanupPreview(),
      throwsA(
        isA<HostRequestException>().having(
          (e) => e.failure.code,
          'code',
          FailureCode.unavailable,
        ),
      ),
    );
    expect(requests.single.$3, 'Bearer fixture');
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
        calls == 1 ? '{"error":"unauthenticated"}' : jsonEncode(previewJson()),
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
      final preview = await LifecycleApi(renewed).readCleanupPreview();
      expect(preview.dayKey, '2026-03-01');
      expect(calls, 2);
      expect(renewals, 1);
    } finally {
      await renewed.close();
      await renewServer.close(force: true);
    }
  });
}
