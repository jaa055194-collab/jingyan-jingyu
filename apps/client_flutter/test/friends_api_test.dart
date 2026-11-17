import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/friends_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

void main() {
  late HttpServer server;
  late HostConnection connection;
  late FriendsApi api;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture',
    );
    api = FriendsApi(connection);
  });

  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  test(
    'state uses exact GET path and bearer then parses canonical enum',
    () async {
      final requests = <(String, String, String?)>[];
      server.listen((r) async {
        await r.drain<void>();
        requests.add((
          r.method,
          r.uri.path,
          r.headers[HttpHeaders.authorizationHeader]?.single,
        ));
        r.response.write('{"state":"friends"}');
        await r.response.close();
      });
      final state = await api.state('owner');
      expect(state, FriendState.friends);
      expect(requests.single.$1, 'GET');
      expect(
        requests.single.$2,
        Routes.friendState.replaceFirst('{accountId}', 'owner'),
      );
      expect(requests.single.$3, 'Bearer fixture');
    },
  );

  test('invalid account id never issues a request', () async {
    var requests = 0;
    server.listen((r) async {
      requests++;
      await r.drain<void>();
      r.response.write('{"state":"none"}');
      await r.response.close();
    });
    await expectLater(api.state('bad/id'), throwsFormatException);
    await expectLater(api.state(''), throwsFormatException);
    expect(requests, 0);
  });

  test(
    'malformed or unknown state is rejected without leaking payload',
    () async {
      final payloads = [
        '{"state":"weird"}',
        '{}',
        '{"state":1}',
        'raw-private',
      ];
      var index = 0;
      server.listen((r) async {
        await r.drain<void>();
        r.response.write(payloads[index++]);
        await r.response.close();
      });
      for (var i = 0; i < payloads.length; i++) {
        try {
          await api.state('owner');
          fail('must reject malformed friendship response');
        } catch (error) {
          expect(error.toString(), isNot(contains('raw-private')));
          expect(error.toString(), isNot(contains('weird')));
        }
      }
    },
  );

  test(
    'list uses exact GET /friends with bearer and parses contacts',
    () async {
      final requests = <(String, String, String?)>[];
      server.listen((r) async {
        await r.drain<void>();
        requests.add((
          r.method,
          r.uri.path,
          r.headers[HttpHeaders.authorizationHeader]?.single,
        ));
        r.response.headers.contentType = ContentType.json;
        r.response.write(
          jsonEncode([
            {'accountId': 'alice', 'displayName': 'Alice', 'state': 'friends'},
            {
              'accountId': 'bob',
              'displayName': 'Bob',
              'state': 'incomingPending',
            },
          ]),
        );
        await r.response.close();
      });
      final contacts = await api.list();
      expect(contacts.map((c) => c.accountId).toList(), ['alice', 'bob']);
      expect(contacts.first.displayName, 'Alice');
      expect(contacts.first.state, FriendState.friends);
      expect(contacts.last.state, FriendState.incomingPending);
      expect(requests.single.$1, 'GET');
      expect(requests.single.$2, Routes.friends);
      expect(requests.single.$3, 'Bearer fixture');
    },
  );

  test('list accepts an empty array', () async {
    server.listen((r) async {
      await r.drain<void>();
      r.response.headers.contentType = ContentType.json;
      r.response.write('[]');
      await r.response.close();
    });
    expect(await api.list(), isEmpty);
  });

  test('list rejects malformed DTOs without leaking payload', () async {
    final payloads = <String>[
      '{}', // object, not a list
      '[{"accountId":"alice","displayName":"Alice"}]', // missing state
      '[{"accountId":"alice","displayName":"Alice","state":"friends","extra":1}]',
      '[{"accountId":"bad/id","displayName":"Alice","state":"friends"}]',
      '[{"accountId":"alice","displayName":"","state":"friends"}]',
      '[{"accountId":"alice","displayName":"Alice","state":"weird-secret"}]',
      '[{"accountId":"alice","displayName":"Alice","state":"none"}]',
      'raw-private-payload',
    ];
    var index = 0;
    server.listen((r) async {
      await r.drain<void>();
      r.response.headers.contentType = ContentType.json;
      r.response.write(payloads[index++]);
      await r.response.close();
    });
    for (var i = 0; i < payloads.length; i++) {
      try {
        await api.list();
        fail('must reject malformed friends list');
      } catch (error) {
        expect(error.toString(), isNot(contains('raw-private-payload')));
        expect(error.toString(), isNot(contains('weird-secret')));
      }
    }
  });

  test('list maps HTTP denials to safe failures', () async {
    server.listen((r) async {
      await r.drain<void>();
      r.response.statusCode = 403;
      r.response.headers.contentType = ContentType.json;
      r.response.write('{"error":"forbidden"}');
      await r.response.close();
    });
    await expectLater(
      api.list(),
      throwsA(
        isA<HostRequestException>().having(
          (e) => e.failure.code,
          'code',
          FailureCode.forbidden,
        ),
      ),
    );
  });

  test('list inherits bounded one-shot 401 replay', () async {
    var requests = 0;
    server.listen((r) async {
      await r.drain<void>();
      requests++;
      r.response.headers.contentType = ContentType.json;
      if (requests == 1) {
        r.response.statusCode = 401;
        r.response.write('{"error":"unauthenticated"}');
      } else {
        r.response.write(
          jsonEncode([
            {'accountId': 'alice', 'displayName': 'Alice', 'state': 'friends'},
          ]),
        );
      }
      await r.response.close();
    });
    var renewals = 0;
    final renewed = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'stale',
      onUnauthorized: () async {
        renewals++;
        return true;
      },
    );
    try {
      final contacts = await FriendsApi(renewed).list();
      expect(contacts.single.accountId, 'alice');
      expect(requests, 2);
      expect(renewals, 1);
    } finally {
      await renewed.close();
    }
  });
}
