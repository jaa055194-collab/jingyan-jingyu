import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/message_reactions_api.dart';
import 'package:flutter_test/flutter_test.dart';

const _path = '/api/v1/conversations/c1/messages/m1/reactions';
const _row = {'accountId': 'actor-alice', 'emoji': '👍'};

void main() {
  late HttpServer server;
  late HostConnection connection;
  late StreamSubscription<HttpRequest> subscription;
  late MessageReactionsApi api;
  late Object? payload;
  late int status;
  final calls = <(String, String, String)>[];

  setUp(() async {
    calls.clear();
    status = 200;
    payload = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture-token',
      onUnauthorized: () async =>
          fail('read and toggle must never replay auth'),
    );
    api = MessageReactionsApi(connection);
    subscription = server.listen((request) async {
      calls.add((
        request.method,
        request.uri.path,
        await utf8.decoder.bind(request).join(),
      ));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(payload));
      await request.response.close();
    });
  });
  tearDown(() async {
    await connection.close();
    await subscription.cancel();
    await server.close(force: true);
  });

  Future<ReactionRead> read() =>
      api.read('c1', 'm1', ownAccountId: 'actor-alice');
  Future<ReactionWrite> toggle() =>
      api.toggle('c1', 'm1', ChatReaction.thumbsUp);

  test(
    'GET retains only fixed choices and aggregates ownership and counts',
    () async {
      payload = {
        'reactions': [
          _row,
          {'accountId': 'actor-bob', 'emoji': '👍'},
          {'accountId': 'actor-bob', 'emoji': '❤️'},
          {'accountId': 'actor-alice', 'emoji': 'legacy raw string'},
        ],
      };
      final loaded = (await read()) as ReactionsLoaded;
      expect(loaded.counts, {
        ChatReaction.thumbsUp: (count: 2, mine: true),
        ChatReaction.heart: (count: 1, mine: false),
      });
      expect(calls.single, ('GET', _path, ''));
    },
  );

  test(
    'none is distinct from malformed, duplicate, oversized or refused lists',
    () async {
      payload = {
        'reactions': [
          {'accountId': 'actor-alice', 'emoji': 'not a choice'},
        ],
      };
      expect(((await read()) as ReactionsLoaded).counts, isEmpty);
      for (final invalid in [
        {},
        {'reactions': [], 'extra': 1},
        {
          'reactions': [_row, _row],
        },
        {
          'reactions': [
            {..._row, 'emoji': true},
          ],
        },
        {
          'reactions': [
            {..._row, 'accountId': '../foreign'},
          ],
        },
        {
          'reactions': [
            {..._row, 'name': 'not in wire'},
          ],
        },
        {
          'reactions': [
            {..._row, 'emoji': 'x' * (130 * 1024)},
          ],
        },
      ]) {
        payload = invalid;
        expect(await read(), isA<ReactionsUnavailable>());
      }
      status = 404;
      payload = {'error': 'not_found'};
      expect(await read(), isA<ReactionsUnavailable>());
    },
  );

  test(
    'single POST toggles using the exact supported emoji and active receipt',
    () async {
      payload = {'emoji': '👍', 'active': true};
      expect(((await toggle()) as ReactionToggled).active, isTrue);
      payload = {'emoji': '👍', 'active': false};
      expect(((await toggle()) as ReactionToggled).active, isFalse);
      expect(calls, [
        ('POST', _path, '{"emoji":"👍"}'),
        ('POST', _path, '{"emoji":"👍"}'),
      ]);
    },
  );

  test(
    'ambiguous toggle results are not confirmed and never replayed',
    () async {
      for (final malformed in [
        {'emoji': '❤️', 'active': true},
        {'emoji': '👍', 'active': 1},
        {'emoji': '👍'},
        {'emoji': '👍', 'active': false, 'unexpected': 0},
      ]) {
        payload = malformed;
        expect(await toggle(), isA<ReactionUnknown>());
      }
      status = 500;
      expect(await toggle(), isA<ReactionUnknown>());
      for (final code in [400, 401, 403, 404]) {
        status = code;
        expect(await toggle(), isA<ReactionRefused>());
      }
      expect(calls.length, 9, reason: 'repeating a toggle would undo it');
    },
  );

  test(
    'invalid target or owner identifiers are refused before transport',
    () async {
      expect(
        await api.read('c1', 'm1', ownAccountId: '../other'),
        isA<ReactionsUnavailable>(),
      );
      expect(
        await api.read('c1', 'm/1', ownAccountId: 'actor-alice'),
        isA<ReactionsUnavailable>(),
      );
      expect(
        await api.toggle('../outside', 'm1', ChatReaction.heart),
        isA<ReactionRefused>(),
      );
      expect(calls, isEmpty);
    },
  );
}
