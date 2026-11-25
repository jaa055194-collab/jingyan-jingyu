import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/favorites_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

void main() {
  late HttpServer server;
  late StreamSubscription<HttpRequest> subscription;
  late HostConnection connection;
  late FavoritesApi api;
  Object? payload;
  int status = 200;
  final requests = <(String, String, String, String?)>[];
  final postBodies = <Object?>[];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture-owner-token',
      onUnauthorized: () async => fail('Favorites must not replay auth'),
    );
    api = FavoritesApi(connection);
    payload = null;
    status = 200;
    requests.clear();
    postBodies.clear();
    subscription = server.listen((request) async {
      if (request.method == 'POST') {
        postBodies.add(jsonDecode(await utf8.decoder.bind(request).join()));
      } else {
        await request.drain<void>();
      }
      requests.add((
        request.method,
        request.uri.path,
        request.uri.query,
        request.headers.value(HttpHeaders.authorizationHeader),
      ));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(payload));
      await request.response.close();
    });
  });

  tearDown(() async {
    await subscription.cancel();
    await connection.close();
    await server.close(force: true);
  });

  Map<String, Object?> row({
    String id = 'fav-1',
    String kind = 'text',
    Object? messageId,
    Object? conversationId,
    Object? title = 'Capture rules',
    String content = 'A private but authorized summary.',
    Object? tags = const ['review'],
    Object? note = 'private note must not be rendered',
    String createdAt = '2026-11-20T10:11:12.000Z',
  }) => {
    'id': id,
    'kind': kind,
    'messageId': messageId,
    'conversationId': conversationId,
    'title': title,
    'content': content,
    'tags': tags,
    'note': note,
    'createdAt': createdAt,
  };

  test('saves only the canonical message reference fields', () async {
    payload = const {'id': 'favorite-1', 'kind': 'message', 'title': null};
    final result = await api.saveMessage(
      conversationId: 'conv-1',
      messageId: 'msg-2',
    );
    expect(result, FavoriteSaveOutcome.saved);
    expect(requests.single, (
      'POST',
      Routes.favorites,
      '',
      'Bearer fixture-owner-token',
    ));
    expect(postBodies.single, {
      'kind': 'message',
      'conversationId': 'conv-1',
      'messageId': 'msg-2',
    });
  });

  test('invalid message and conversation ids never reach transport', () async {
    for (final (conversation, message) in [
      ('bad/id', 'm1'),
      ('c1', '../bad'),
    ]) {
      expect(
        await api.saveMessage(conversationId: conversation, messageId: message),
        FavoriteSaveOutcome.rejected,
      );
    }
    expect(requests, isEmpty);
  });

  test('definitive host refusals do not replay a favorite write', () async {
    for (final (code, label) in [
      (401, 'unauthenticated'),
      (403, 'forbidden'),
      (404, 'not_found'),
    ]) {
      status = code;
      payload = {'error': label, 'detail': 'fixture private detail'};
      expect(
        await api.saveMessage(conversationId: 'c1', messageId: 'm1'),
        FavoriteSaveOutcome.rejected,
      );
    }
    expect(requests.map((request) => request.$1), ['POST', 'POST', 'POST']);
  });

  test(
    'an ambiguous failure or malformed success is not a confirmed save',
    () async {
      for (final (code, body) in <(int, Object?)>[
        (503, {'error': 'unavailable'}),
        (200, {'id': 'favorite-1', 'kind': 'file', 'title': null}),
        (200, {'id': 123, 'kind': 'message', 'title': null}),
        (200, {'id': '../bad', 'kind': 'message', 'title': null}),
        (
          200,
          {'id': 'favorite-1', 'kind': 'message', 'title': 'guessed title'},
        ),
        (
          200,
          {
            'id': 'favorite-1',
            'kind': 'message',
            'title': null,
            'extra': 'private',
          },
        ),
        (200, null),
      ]) {
        status = code;
        payload = body;
        expect(
          await api.saveMessage(conversationId: 'c1', messageId: 'm1'),
          FavoriteSaveOutcome.unknown,
        );
      }
      expect(requests, hasLength(7));
    },
  );

  test('reads only GET /favorites and projects safe text fields', () async {
    payload = {
      'favorites': [
        row(),
        row(
          id: 'fav-2',
          kind: 'message',
          messageId: 'msg-1',
          conversationId: 'conv-1',
          title: 'Source excerpt',
          content: jsonEncode({
            'text': 'Only this authorized source text is shown.',
            'attachmentId': 'hidden-attachment-path',
            'api_key': 'hidden-secret',
            'localPath': 'C:\\private\\secret.txt',
          }),
          tags: null,
          note: null,
        ),
        row(
          id: 'fav-3',
          kind: 'link',
          title: 'Do not open this URL',
          content: 'https://fixture.invalid/private',
        ),
        row(
          id: 'fav-4',
          kind: 'file',
          title: 'C:\\private\\secret.txt',
          content: 'C:\\private\\secret.txt',
        ),
      ],
    };

    final result = await api.readFavorites();
    expect(result, isA<FavoritesLoaded>());
    final favorites = (result as FavoritesLoaded).favorites;
    expect(favorites, hasLength(4));
    expect(favorites[0].kind, FavoriteKind.text);
    expect(favorites[0].title, 'Capture rules');
    expect(favorites[0].preview, 'A private but authorized summary.');
    expect(favorites[0].createdAt, DateTime.utc(2026, 11, 20, 10, 11, 12));
    expect(favorites[1].kind, FavoriteKind.message);
    expect(favorites[1].preview, 'Only this authorized source text is shown.');
    expect(favorites[2].preview, isNull);
    expect(favorites[3].title, isNull);
    expect(favorites[3].preview, isNull);
    for (final favorite in favorites) {
      expect(favorite.toString(), isNot(contains('hidden-secret')));
      expect(favorite.toString(), isNot(contains('attachment')));
      expect(favorite.toString(), isNot(contains('private note')));
      expect(favorite.toString(), isNot(contains('private\\secret')));
    }
    expect(requests.single, (
      'GET',
      Routes.favorites,
      '',
      'Bearer fixture-owner-token',
    ));
  });

  test('an empty owner list is a loaded empty state', () async {
    payload = const {'favorites': <Object?>[]};
    final result = await api.readFavorites();
    expect(result, isA<FavoritesLoaded>());
    expect((result as FavoritesLoaded).favorites, isEmpty);
  });

  test('401 and 403 are denied without auth replay', () async {
    for (final code in [401, 403]) {
      status = code;
      payload = {'error': code == 401 ? 'unauthenticated' : 'forbidden'};
      expect(await api.readFavorites(), isA<FavoritesDenied>());
    }
    expect(requests, hasLength(2));
  });

  test('transport failures do not expose host response details', () async {
    status = 503;
    payload = const {'error': 'unavailable', 'detail': 'private-host-detail'};
    final result = await api.readFavorites();
    expect(result, isA<FavoritesUnavailable>());
    expect(result.toString(), isNot(contains('private-host-detail')));
    expect(requests, hasLength(1));
  });

  test('a closed connection reports unavailable without a request', () async {
    await connection.close();
    expect(await api.readFavorites(), isA<FavoritesUnavailable>());
    expect(requests, isEmpty);
  });

  test(
    'opaque content is withheld rather than shown as a text preview',
    () async {
      payload = {
        'favorites': [
          row(content: '{"api_key":"secret"}'),
          row(id: 'fav-2', content: 'Read /home/fixture/private.txt'),
          row(id: 'fav-3', content: 'Read C:\\private\\secret.txt'),
          row(id: 'fav-4', content: 'Visit https://fixture.invalid/private'),
          row(id: 'fav-5', content: 'api_key: fixture-secret'),
          row(
            id: 'fav-6',
            kind: 'message',
            messageId: 'msg-1',
            conversationId: 'conv-1',
            content: '{"attachmentId":"hidden-attachment","token":"secret"}',
          ),
        ],
      };
      final result = await api.readFavorites();
      expect(result, isA<FavoritesLoaded>());
      expect((result as FavoritesLoaded).favorites, hasLength(6));
      expect(
        result.favorites.map((item) => item.preview),
        everyElement(isNull),
      );
    },
  );

  test(
    'malformed envelope or any malformed row rejects the whole list',
    () async {
      final invalidPayloads = <Object?>[
        {'favorites': <Object?>[], 'secret': 'must-not-leak'},
        {'favorites': 'not-a-list'},
        {
          'favorites': [
            row(),
            {...row(id: 'fav-2'), 'secret': 'token'},
          ],
        },
        {
          'favorites': [
            {...row(), 'id': 4},
          ],
        },
        {
          'favorites': [
            {...row(), 'kind': 'dynamic'},
          ],
        },
        {
          'favorites': [
            {...row(kind: 'message'), 'messageId': null},
          ],
        },
        {
          'favorites': [
            {...row(kind: 'text'), 'messageId': 'msg-1'},
          ],
        },
        {
          'favorites': [
            {
              ...row(
                kind: 'message',
                messageId: 'bad id',
                conversationId: 'conv-1',
              ),
            },
          ],
        },
        {
          'favorites': [
            {
              ...row(
                kind: 'message',
                messageId: 'msg-1',
                conversationId: 'conv-1',
              ),
              'content': '[1,2]',
            },
          ],
        },
        {
          'favorites': [
            {
              ...row(),
              'tags': ['ok', 3],
            },
          ],
        },
        {
          'favorites': [
            {...row(), 'note': 7},
          ],
        },
        {
          'favorites': [
            {...row(), 'createdAt': 'not-a-time'},
          ],
        },
        {
          'favorites': [
            {...row(), 'createdAt': '2026-11-20T10:11:12'},
          ],
        },
        <Object?>[],
      ];
      for (final invalid in invalidPayloads) {
        payload = invalid;
        final result = await api.readFavorites();
        expect(result, isA<FavoritesMalformed>(), reason: '$invalid');
        expect(result.toString(), isNot(contains('secret')));
      }
      expect(requests, hasLength(invalidPayloads.length));
    },
  );

  test(
    'response size bound is enforced before the adapter consumes a body',
    () async {
      payload = {
        'favorites': [row(content: 'x' * (3 * 1024 * 1024))],
      };
      final result = await api.readFavorites();
      expect(result, isA<FavoritesMalformed>());
      expect(requests, hasLength(1));
    },
  );
}
