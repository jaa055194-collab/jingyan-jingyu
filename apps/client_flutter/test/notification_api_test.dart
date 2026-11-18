import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/notification_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late StreamSubscription<HttpRequest> sub;
  late HostConnection connection;
  late NotificationApi api;
  late List<(String, String, String, String?)> requests;
  late int status;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'token',
    );
    api = NotificationApi(connection);
    requests = [];
    status = 200;
    sub = server.listen((request) async {
      requests.add((
        request.method,
        request.uri.path,
        request.uri.query,
        request.headers.value(HttpHeaders.authorizationHeader),
      ));
      request.response.statusCode = status;
      if (status == 200) {
        request.response.write(
          jsonEncode([
            {
              'kind': 'friendRequest',
              'title': '好友邀请',
              'status': 'pending',
              'createdAt': '2026-11-18T00:00:00.000Z',
              'refId': 'acct-a',
            },
          ]),
        );
      } else {
        request.response.write('{"error":"unavailable","detail":"secret-xyz"}');
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await sub.cancel();
    await connection.close();
    await server.close(force: true);
  });

  test(
    'readNotifications uses exact method/path/query and parses strict DTO',
    () async {
      final items = await api.readNotifications(limit: 25);
      expect(items.length, 1);
      final item = items.single;
      expect(item.kind, 'friendRequest');
      expect(item.title, '好友邀请');
      expect(item.status, 'pending');
      expect(item.createdAt, '2026-11-18T00:00:00.000Z');
      expect(item.refId, 'acct-a');
      expect(requests.single, (
        'GET',
        '/api/v1/notifications',
        'limit=25',
        'Bearer token',
      ));
    },
  );

  test('non-object rows are rejected as safe format failures', () async {
    final badServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => badServer.close(force: true));
    badServer.listen((request) async {
      request.response.write('["fixture-private-detail"]');
      await request.response.close();
    });
    final badConnection = HostConnection(
      Uri.parse('http://127.0.0.1:${badServer.port}'),
      'fixture-token',
    );
    addTearDown(badConnection.close);
    await expectLater(
      NotificationApi(badConnection).readNotifications(),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', '通知响应无效'),
      ),
    );
  });

  test('malformed items are rejected safely', () async {
    final malformed = <Map<String, Object?>>[
      {
        'kind': 'friendRequest',
        'title': '好友邀请',
        'status': 'pending',
        'createdAt': 'x',
        'refId': 'acct-a',
        'extra': 'nope',
      },
    ];
    final badServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final badSub = badServer.listen((r) async {
      r.response.write(jsonEncode(malformed));
      await r.response.close();
    });
    final badApi = NotificationApi(
      HostConnection(Uri.parse('http://127.0.0.1:${badServer.port}'), 'token'),
    );
    await expectLater(
      badApi.readNotifications(),
      throwsA(isA<FormatException>()),
    );
    await badSub.cancel();
    await badServer.close(force: true);
  });

  test('503 fails safely without leaking details', () async {
    status = 503;
    await expectLater(
      api.readNotifications(),
      throwsA(
        predicate(
          (e) =>
              e is HostRequestException && !e.toString().contains('secret-xyz'),
        ),
      ),
    );
    expect(requests.where((r) => r.$2 == '/api/v1/notifications').length, 1);
  });

  test('limit outside 1..100 is rejected before any request', () async {
    await expectLater(
      api.readNotifications(limit: 0),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      api.readNotifications(limit: 101),
      throwsA(isA<FormatException>()),
    );
    expect(requests, isEmpty);
  });
}
