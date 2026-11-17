import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/world_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

String _layoutJson() => jsonEncode({
  'spaceId': 'villa',
  'version': 2,
  'style': 'seaside',
  'mainColor': '#11aa33',
  'rooms': [
    {
      'roomId': 'living',
      'name': 'Living',
      'furniture': [
        {
          'itemId': 'sofa',
          'assetId': 'sofa_01',
          'x': 1,
          'y': 0,
          'z': 2,
          'rotation': 0.5,
        },
      ],
    },
  ],
  'updatedAt': '2026-11-17T00:00:00.000Z',
});

String _presenceJson() => jsonEncode({
  'positions': [
    {
      'residentId': 'ai',
      'spaceId': 'villa',
      'position': {'x': 1.5, 'y': 0, 'z': 2},
      'motion': 'walk',
      'updatedAt': '2026-11-17T00:00:00.000Z',
    },
  ],
});

String _avatarsJson() => jsonEncode({
  'avatars': [
    {
      'avatarId': 'av1',
      'ownerId': 'owner',
      'kind': 'live2d',
      'modelId': 'model_a',
      'profileRev': 3,
      'updatedAt': '2026-11-17T00:00:00.000Z',
    },
  ],
});

String _activeJson() =>
    jsonEncode({'modelId': 'model_a', 'profileRev': 3, 'kind': 'live2d'});

void main() {
  late HttpServer server;
  late HostConnection connection;
  late WorldApi api;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture',
    );
    api = WorldApi(connection);
  });

  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  test(
    'read adapters use exact GET paths, bearer header and parse DTOs',
    () async {
      final requests = <(String, String, String?)>[];
      server.listen((r) async {
        await r.drain<void>();
        requests.add((
          r.method,
          r.uri.path,
          r.headers[HttpHeaders.authorizationHeader]?.single,
        ));
        final path = r.uri.path;
        if (path ==
            Routes.worldSpaceLayout.replaceFirst('{spaceId}', 'villa')) {
          r.response.write(_layoutJson());
        } else if (path ==
            Routes.worldSpacePresence.replaceFirst('{spaceId}', 'villa')) {
          r.response.write(_presenceJson());
        } else if (path == Routes.worldAvatars) {
          r.response.write(_avatarsJson());
        } else if (path == Routes.worldAvatarActive) {
          r.response.write(_activeJson());
        } else {
          r.response.statusCode = 404;
          r.response.write('{"error":"not_found"}');
        }
        await r.response.close();
      });

      final layout = await api.layout('villa');
      expect(layout.spaceId, 'villa');
      expect(layout.version, 2);
      expect(layout.style, 'seaside');
      expect(layout.mainColor, '#11aa33');
      expect(layout.rooms.single.roomId, 'living');
      expect(layout.rooms.single.furniture.single.assetId, 'sofa_01');
      expect(layout.rooms.single.furniture.single.rotation, 0.5);
      expect(layout.updatedAt, DateTime.utc(2026, 11, 17));

      final presence = await api.presence('villa');
      expect(presence.single.residentId, 'ai');
      expect(presence.single.motion, 'walk');
      expect(presence.single.x, 1.5);

      final avatars = await api.avatars();
      expect(avatars.single.avatarId, 'av1');
      expect(avatars.single.kind, 'live2d');
      expect(avatars.single.profileRev, 3);

      final active = await api.activeAvatar();
      expect(active.modelId, 'model_a');
      expect(active.profileRev, 3);
      expect(active.kind, 'live2d');

      expect(requests, hasLength(4));
      expect(requests.every((r) => r.$1 == 'GET'), isTrue);
      expect(requests.every((r) => r.$3 == 'Bearer fixture'), isTrue);
      expect(requests.map((r) => r.$2), [
        Routes.worldSpaceLayout.replaceFirst('{spaceId}', 'villa'),
        Routes.worldSpacePresence.replaceFirst('{spaceId}', 'villa'),
        Routes.worldAvatars,
        Routes.worldAvatarActive,
      ]);
    },
  );

  test('invalid space id is rejected locally without any request', () async {
    var requests = 0;
    server.listen((r) async {
      requests++;
      await r.drain<void>();
      r.response.write(_layoutJson());
      await r.response.close();
    });
    await expectLater(api.layout('bad/id'), throwsFormatException);
    await expectLater(api.presence('bad/id'), throwsFormatException);
    expect(requests, 0);
  });

  test('malformed DTOs are rejected and never leak raw payload', () async {
    final payloads = <String>[
      jsonEncode({
        'spaceId': 'villa',
        'version': 0,
        'style': 'x',
        'rooms': [],
        'updatedAt': '2026-11-17T00:00:00.000Z',
      }),
      jsonEncode({
        'spaceId': 'villa',
        'version': 1,
        'style': 'x',
        'rooms': [],
        'updatedAt': '2026-11-17T00:00:00',
      }),
      jsonEncode({
        'spaceId': 'villa',
        'version': 1,
        'style': 'x',
        'rooms': [
          {
            'roomId': 'r',
            'name': 'R',
            'furniture': [
              {'itemId': 'i'},
            ],
          },
        ],
        'updatedAt': '2026-11-17T00:00:00.000Z',
      }),
    ];
    final badPresence = [
      '{"positions":{}}',
      jsonEncode({
        'positions': [
          {
            'residentId': 'ai',
            'spaceId': 'v',
            'position': {'x': 0, 'y': 0, 'z': 0},
            'motion': 'fly',
            'updatedAt': '2026-11-17T00:00:00.000Z',
          },
        ],
      }),
    ];
    var nextLayout = 0;
    var nextPresence = 0;
    server.listen((r) async {
      final path = r.uri.path;
      await r.drain<void>();
      if (path.endsWith('/layout')) {
        r.response.write(payloads[nextLayout++]);
      } else {
        r.response.write(badPresence[nextPresence++]);
      }
      await r.response.close();
    });
    for (var i = 0; i < 3; i++) {
      try {
        await api.layout('villa');
        fail('must reject malformed layout');
      } catch (error) {
        expect(error.toString(), isNot(contains('spaceId')));
      }
    }
    for (var i = 0; i < 2; i++) {
      await expectLater(api.presence('villa'), throwsFormatException);
    }
  });

  test(
    'bounded inherited 401 replays at most once via onUnauthorized',
    () async {
      await connection.close();
      var requests = 0;
      server.listen((r) async {
        await r.drain<void>();
        requests++;
        if (requests == 1) {
          r.response.statusCode = 401;
          r.response.write('{"error":"unauthenticated"}');
        } else {
          r.response.write(_layoutJson());
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
        final layout = await WorldApi(renewed).layout('villa');
        expect(layout.spaceId, 'villa');
        expect(requests, 2);
        expect(renewals, 1);
      } finally {
        await renewed.close();
      }
    },
  );
}
