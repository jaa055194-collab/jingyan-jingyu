import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/friends_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';

void main() {
  late HttpServer server;
  late StreamSubscription<HttpRequest> sub;
  late HostConnection connection;
  late FriendsApi api;
  late List<(String, String, String?)> requests;
  late int status;
  late String errorBody;
  late int renewals;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'token',
      onUnauthorized: () async {
        renewals++;
        connection.updateAccessToken('renewed-fixture');
        status = 200;
        return true;
      },
    );
    api = FriendsApi(connection);
    requests = [];
    status = 200;
    renewals = 0;
    errorBody = '{"error":"conflict"}';
    sub = server.listen((request) async {
      requests.add((
        request.method,
        request.uri.path,
        request.headers.value(HttpHeaders.authorizationHeader),
      ));
      final body = await utf8.decoder.bind(request).join();
      expect(body, isEmpty, reason: 'write routes take no body');
      request.response.statusCode = status;
      if (status == 200) {
        request.response.write('');
      } else {
        request.response.write(errorBody);
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
    'acceptFriend POSTs the exact accept route with an empty body',
    () async {
      await api.acceptFriend('acct-b');
      expect(requests.single, (
        'POST',
        '/api/v1/friends/acct-b/accept',
        'Bearer token',
      ));
    },
  );

  test('denyFriend POSTs the exact deny route', () async {
    await api.denyFriend('acct-b');
    expect(requests.single, (
      'POST',
      '/api/v1/friends/acct-b/deny',
      'Bearer token',
    ));
  });

  for (final action in ['accept', 'deny']) {
    test(
      '$action on 401 never renews or replays and needs another call',
      () async {
        status = 401;
        final respond = action == 'accept' ? api.acceptFriend : api.denyFriend;
        final path = '/api/v1/friends/acct-b/$action';
        await expectLater(
          respond('acct-b'),
          throwsA(
            isA<HostRequestException>().having(
              (error) => error.failure.code,
              'code',
              FailureCode.unauthenticated,
            ),
          ),
        );
        expect(renewals, 0);
        expect(requests, [('POST', path, 'Bearer token')]);

        // A later authenticated context still has to explicitly submit again.
        connection.updateAccessToken('new-fixture-session');
        status = 200;
        expect(requests, hasLength(1));
        await respond('acct-b');
        expect(requests, [
          ('POST', path, 'Bearer token'),
          ('POST', path, 'Bearer new-fixture-session'),
        ]);
        expect(renewals, 0);
      },
    );
  }

  test('conflict response is surfaced as a typed failure', () async {
    status = 409;
    await expectLater(
      api.acceptFriend('acct-b'),
      throwsA(
        predicate(
          (e) =>
              e is HostRequestException &&
              e.failure.code == FailureCode.conflict,
        ),
      ),
    );
    expect(requests.length, 1);
  });

  test('503 fails safely without leaking details', () async {
    status = 503;
    errorBody = '{"error":"unavailable","detail":"secret-xyz"}';
    await expectLater(
      api.denyFriend('acct-b'),
      throwsA(
        predicate(
          (e) =>
              e is HostRequestException && !e.toString().contains('secret-xyz'),
        ),
      ),
    );
    expect(requests.length, 1);
  });

  test('invalid account id is rejected before any request', () async {
    await expectLater(
      api.acceptFriend('bad id!'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      api.denyFriend('bad id!'),
      throwsA(isA<FormatException>()),
    );
    expect(requests, isEmpty);
  });
}
