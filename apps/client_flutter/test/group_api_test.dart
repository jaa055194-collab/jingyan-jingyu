import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/group_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

void main() {
  late HttpServer server;
  late HostConnection connection;
  late GroupApi api;
  const validGroup = {
    'id': 'group-1',
    'name': 'Friends',
    'kind': 'group',
    'ownerAccountId': 'owner-1',
    'historyVisibility': 'all',
    'createdAt': '2026-11-16T00:00:00Z',
  };

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture-token',
    );
    api = GroupApi(connection);
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  test(
    'create uses authenticated existing group route and returns canonical DTO',
    () async {
      final received = <Map<String, Object?>>[];
      server.listen((request) async {
        received.add({
          'method': request.method,
          'path': request.uri.path,
          'bearer': request.headers[HttpHeaders.authorizationHeader]?.single,
          'body': jsonDecode(await utf8.decoder.bind(request).join()),
        });
        request.response.write(jsonEncode(validGroup));
        await request.response.close();
      });
      final group = await api.createGroup(' Friends ');
      expect(received, [
        {
          'method': 'POST',
          'path': Routes.conversations,
          'bearer': 'Bearer fixture-token',
          'body': {
            'name': 'Friends',
            'kind': 'group',
            'historyVisibility': 'all',
          },
        },
      ]);
      expect(group.id, 'group-1');
      expect(group.name, 'Friends');
      expect(group.ownerAccountId, 'owner-1');
      expect(group.historyVisibility, 'all');
    },
  );

  test('create rejects invalid raw names before issuing requests', () async {
    var calls = 0;
    server.listen((request) async {
      calls++;
      await request.drain<void>();
      request.response.write(jsonEncode(validGroup));
      await request.response.close();
    });
    for (final name in ['', '  ', 'x' * 101, '${'x' * 99}  ']) {
      await expectLater(api.createGroup(name), throwsFormatException);
    }
    expect(calls, 0);
  });

  test('create accepts exact hundred-character name boundary', () async {
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      request.response.write(jsonEncode({...validGroup, 'name': body['name']}));
      await request.response.close();
    });
    expect((await api.createGroup('x' * 100)).name, 'x' * 100);
  });

  test(
    'create rejects malformed canonical group response without phantom values',
    () async {
      final responses = <Object?>[
        {},
        {...validGroup, 'id': 'bad/id'},
        {...validGroup, 'id': 42},
        {...validGroup, 'name': ''},
        {...validGroup, 'name': 'x' * 101},
        {...validGroup, 'name': ' padded '},
        {...validGroup, 'ownerAccountId': 'bad/id'},
        {...validGroup, 'ownerAccountId': null},
        {...validGroup, 'historyVisibility': 'unknown'},
        {...validGroup, 'kind': 'direct'},
        null,
      ];
      var next = 0;
      server.listen((request) async {
        await request.drain<void>();
        request.response.write(jsonEncode(responses[next++]));
        await request.response.close();
      });
      for (var i = 0; i < responses.length; i++) {
        await expectLater(api.createGroup('Friends'), throwsFormatException);
      }
      expect(next, responses.length);
    },
  );

  test('create makes no automatic retry on host failure', () async {
    var calls = 0;
    server.listen((request) async {
      calls++;
      await request.drain<void>();
      request.response.statusCode = 503;
      request.response.write('{"error":"unavailable"}');
      await request.response.close();
    });
    await expectLater(
      api.createGroup('Friends'),
      throwsA(
        isA<HostRequestException>().having(
          (error) => error.failure.code,
          'failure',
          FailureCode.unavailable,
        ),
      ),
    );
    expect(calls, 1);
  });

  test(
    'add known member posts only account ID and accepts empty success',
    () async {
      final received = <Map<String, Object?>>[];
      server.listen((request) async {
        received.add({
          'method': request.method,
          'path': request.uri.path,
          'bearer': request.headers[HttpHeaders.authorizationHeader]?.single,
          'body': jsonDecode(await utf8.decoder.bind(request).join()),
        });
        await request.response.close();
      });
      await api.addMember('group-1', 'member-2');
      expect(received, [
        {
          'method': 'POST',
          'path': Routes.conversationMembers.replaceFirst(
            '{conversationId}',
            'group-1',
          ),
          'bearer': 'Bearer fixture-token',
          'body': {'accountId': 'member-2'},
        },
      ]);
    },
  );

  test('add member validates both canonical IDs before any request', () async {
    var calls = 0;
    server.listen((request) async {
      calls++;
      await request.drain<void>();
      await request.response.close();
    });
    for (final ids in [
      ('', 'member-2'),
      ('bad/id', 'member-2'),
      ('group-1', ''),
      ('group-1', 'bad/id'),
      ('group-1', 'x' * 65),
    ]) {
      await expectLater(api.addMember(ids.$1, ids.$2), throwsFormatException);
    }
    expect(calls, 0);
  });

  test(
    'add member preserves host owner-only rejection without retry',
    () async {
      var calls = 0;
      server.listen((request) async {
        calls++;
        await request.drain<void>();
        request.response.statusCode = 404;
        request.response.write('{"error":"not_found"}');
        await request.response.close();
      });
      await expectLater(
        api.addMember('group-1', 'member-2'),
        throwsA(
          isA<HostRequestException>().having(
            (error) => error.failure.code,
            'failure',
            FailureCode.notFound,
          ),
        ),
      );
      expect(calls, 1);
    },
  );
}
