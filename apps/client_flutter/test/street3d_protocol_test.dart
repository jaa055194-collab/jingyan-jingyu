import 'dart:convert';

import 'package:client_flutter/features/world/street3d_protocol.dart';
import 'package:client_flutter/net/world_api.dart';
import 'package:flutter_test/flutter_test.dart';

final _clock = DateTime.utc(2026, 11, 26, 8);

WorldSpaceLayout _layout(
  String id, {
  int rooms = 1,
  int furniture = 1,
  String? mainColor = '#4F8FBF',
}) => WorldSpaceLayout.fromJson({
  'spaceId': id,
  'version': 3,
  'style': 'seaside',
  'mainColor': mainColor,
  'rooms': [
    for (var r = 0; r < rooms; r++)
      {
        'roomId': 'room$r',
        'name': '房间$r',
        'furniture': [
          for (var f = 0; f < furniture; f++)
            {
              'itemId': 'item$f',
              'assetId': 'asset_$f',
              'x': 1,
              'y': 0,
              'z': 2,
              'rotation': 0.5,
            },
        ],
      },
  ],
  'updatedAt': '2026-11-25T08:00:00.000Z',
});

WorldPresenceRecord _record(
  String id, {
  String spaceId = 'alice',
  String updatedAt = '2026-11-25T08:00:01.000Z',
}) => WorldPresenceRecord.fromJson({
  'residentId': id,
  'spaceId': spaceId,
  'position': {'x': 1.5, 'y': 0, 'z': -3},
  'motion': 'walk',
  'updatedAt': updatedAt,
});

Map<String, Object?> _decode(String json) =>
    jsonDecode(json) as Map<String, Object?>;

String _page(String type, Object? payload, {Object? v = 1}) =>
    jsonEncode({'v': v, 'type': type, 'ts': 1764115200000, 'payload': payload});

Street3DPageMessage _parse(String type, Object? payload) =>
    Street3DPageMessage.parse(_page(type, payload));

void main() {
  group('ids and labels', () {
    test('ids follow the page pattern', () {
      expect(isStreet3DId('alice'), isTrue);
      expect(isStreet3DId('A-b_9'), isTrue);
      expect(isStreet3DId('a' * 64), isTrue);
      expect(isStreet3DId('a' * 65), isFalse);
      expect(isStreet3DId(''), isFalse);
      expect(isStreet3DId('a b'), isFalse);
      expect(isStreet3DId('鲸'), isFalse);
    });

    test('labels are trimmed and cut to 32 characters', () {
      expect(street3dLabel('  我的别墅 '), '我的别墅');
      expect(street3dLabel('   '), isNull);
      expect(street3dLabel(null), isNull);
      expect(street3dLabel('鲸' * 40), '鲸' * 32);
      expect(street3dLabel('😀' * 33), '😀' * 32);
    });

    test('relations and roles use the wire names', () {
      expect(
        [for (final r in Street3DRelation.values) r.wire],
        ['self', 'own_ai', 'friend', 'other'],
      );
      expect(
        [for (final r in Street3DRole.values) r.wire],
        ['self', 'own_ai', 'friend', 'visitor', 'other'],
      );
    });
  });

  group('host messages', () {
    test('hello-ack carries the config, clamped to the protocol ranges', () {
      final host = Street3DHostMessages(clock: () => _clock);
      expect(_decode(host.helloAck()), {
        'v': 1,
        'type': 'hello-ack',
        'id': 'h-1',
        'ts': _clock.millisecondsSinceEpoch,
        'payload': {
          'v': '1.0',
          'config': {
            'theme': 'light',
            'quality': 'high',
            'maxResidents': 8,
            'statsIntervalMs': 0,
          },
        },
      });
      final clamped = _decode(
        host.helloAck(
          theme: 'dark',
          quality: 'low',
          maxResidents: 20,
          statsIntervalMs: 300,
        ),
      );
      expect(clamped['id'], 'h-2');
      expect((clamped['payload'] as Map)['config'], {
        'theme': 'dark',
        'quality': 'low',
        'maxResidents': 8,
        'statsIntervalMs': 1000,
      });
      final fallback = _decode(
        host.helloAck(theme: 'sepia', quality: 'ultra', maxResidents: 0),
      );
      expect((fallback['payload'] as Map)['config'], {
        'theme': 'light',
        'quality': 'high',
        'maxResidents': 1,
        'statsIntervalMs': 0,
      });
    });

    test('a space is its host layout plus the street fields', () {
      final space = Street3DSpace(
        layout: _layout('alice'),
        slot: 0,
        label: ' 我的别墅 ',
        relation: Street3DRelation.self,
      );
      expect(space.toJson(), {
        'spaceId': 'alice',
        'version': 3,
        'style': 'seaside',
        'mainColor': '#4F8FBF',
        'rooms': [
          {
            'roomId': 'room0',
            'name': '房间0',
            'furniture': [
              {
                'itemId': 'item0',
                'assetId': 'asset_0',
                'x': 1.0,
                'y': 0.0,
                'z': 2.0,
                'rotation': 0.5,
              },
            ],
          },
        ],
        'updatedAt': '2026-11-25T08:00:00.000Z',
        'slot': 0,
        'label': '我的别墅',
        'relation': 'self',
      });
      final bare = Street3DSpace(
        layout: _layout('bob', mainColor: null),
        slot: 12,
        label: '  ',
      ).toJson();
      expect(bare.containsKey('slot'), isFalse);
      expect(bare.containsKey('label'), isFalse);
      expect(bare['mainColor'], isNull);
      expect(bare['relation'], 'other');
    });

    test('layout keeps the first 12 spaces with valid, unrepeated ids', () {
      final host = Street3DHostMessages(clock: () => _clock);
      final message = _decode(
        host.layout([
          Street3DSpace(layout: _layout('bad id')),
          for (var i = 0; i < 14; i++) Street3DSpace(layout: _layout('s$i')),
          Street3DSpace(layout: _layout('s0')),
        ]),
      );
      expect(message['type'], 'layout');
      final sent = (message['payload'] as Map)['spaces'] as List;
      expect(
        [for (final s in sent) (s as Map)['spaceId']],
        [for (var i = 0; i < 12; i++) 's$i'],
      );
    });

    test('a layout over 256 KiB is sent without furniture', () {
      final host = Street3DHostMessages(clock: () => _clock);
      final spaces = [
        for (var i = 0; i < 12; i++)
          Street3DSpace(layout: _layout('s$i', rooms: 4, furniture: 100)),
      ];
      final full = jsonEncode([for (final s in spaces) s.toJson()]);
      expect(utf8.encode(full).length, greaterThan(street3dMaxMessageBytes));
      final json = host.layout(spaces);
      expect(
        utf8.encode(json).length,
        lessThanOrEqualTo(street3dMaxMessageBytes),
      );
      final sent = (_decode(json)['payload'] as Map)['spaces'] as List;
      expect(sent, hasLength(12));
      final rooms = (sent.first as Map)['rooms'] as List;
      expect(rooms, hasLength(4));
      expect((rooms.first as Map)['name'], '房间0');
      expect((rooms.first as Map)['furniture'], isEmpty);
    });

    test('presence sends each resident with valid ids once', () {
      final host = Street3DHostMessages(clock: () => _clock);
      final one = _decode(
        host.presence(42, [
          Street3DResident(
            record: _record('ai1'),
            label: '小鲸',
            role: Street3DRole.ownAi,
          ),
        ]),
      );
      expect(one['type'], 'presence');
      expect(one['payload'], {
        't': 42,
        'residents': [
          {
            'residentId': 'ai1',
            'spaceId': 'alice',
            'x': 1.5,
            'y': 0.0,
            'z': -3.0,
            'motion': 'walk',
            'updatedAt': '2026-11-25T08:00:01.000Z',
            'label': '小鲸',
            'role': 'own_ai',
          },
        ],
      });
      final some = _decode(
        host.presence(43, [
          Street3DResident(record: _record('bad id')),
          Street3DResident(record: _record('r0', spaceId: 'bad space')),
          for (var i = 0; i < 5; i++) Street3DResident(record: _record('r$i')),
          Street3DResident(record: _record('r1')),
        ]),
      );
      final residents = (some['payload'] as Map)['residents'] as List;
      expect(
        [for (final r in residents) (r as Map)['residentId']],
        ['r0', 'r1', 'r2', 'r3', 'r4'],
      );
      expect((residents.first as Map).containsKey('label'), isFalse);
      expect((residents.first as Map)['role'], 'other');
    });

    test(
      'over 32 residents, presence keeps self, own AIs, then the newest',
      () {
        String other(int i) => 'o${i.toString().padLeft(2, '0')}';
        const older = '2026-11-25T07:00:00.000Z';
        final host = Street3DHostMessages(clock: () => _clock);
        final json = _decode(
          host.presence(44, [
            for (var i = 0; i < 40; i++)
              Street3DResident(record: _record(other(i))),
            Street3DResident(
              record: _record('new', updatedAt: '2026-11-25T08:01:00.000Z'),
            ),
            Street3DResident(
              record: _record('ai1', updatedAt: older),
              role: Street3DRole.ownAi,
            ),
            Street3DResident(
              record: _record('me', updatedAt: older),
              role: Street3DRole.self,
            ),
          ]),
        );
        final residents = (json['payload'] as Map)['residents'] as List;
        // Role first, then the newest; equal times go by residentId.
        expect(
          [for (final r in residents) (r as Map)['residentId']],
          ['me', 'ai1', 'new', for (var i = 0; i < 29; i++) other(i)],
        );
      },
    );

    test('pause, resume, theme and focus', () {
      final host = Street3DHostMessages(clock: () => _clock);
      Map<String, Object?> body(String json) {
        final m = _decode(json);
        return {'type': m['type'], 'payload': m['payload']};
      }

      expect(body(host.pause()), {'type': 'pause', 'payload': {}});
      expect(body(host.resume()), {'type': 'resume', 'payload': {}});
      expect(body(host.theme('dark')), {
        'type': 'theme',
        'payload': {'mode': 'dark'},
      });
      expect(body(host.theme('sepia')), {
        'type': 'theme',
        'payload': {'mode': 'light'},
      });
      expect(body(host.focusOverview()), {
        'type': 'focus',
        'payload': {'kind': 'overview'},
      });
      expect(body(host.focusVilla('alice')), {
        'type': 'focus',
        'payload': {'kind': 'villa', 'id': 'alice'},
      });
      expect(body(host.focusResident('ai1')), {
        'type': 'focus',
        'payload': {'kind': 'resident', 'id': 'ai1'},
      });
      expect(_decode(host.pause())['id'], 'h-8');
    });
  });

  group('page messages', () {
    test('hello says which protocol the page speaks', () {
      final hello = _parse('hello', {
        'v': '1.0',
        'caps': ['tap', 'camera', 'stats', 'focus', 'theme'],
        'limits': {
          'maxSpaces': 12,
          'maxResidents': 8,
          'maxResidentsPerMessage': 32,
        },
        'renderer': {'three': 'r160', 'webgl': 2},
      });
      expect(
        hello,
        isA<Street3DHello>()
            .having((h) => h.version, 'version', '1.0')
            .having((h) => h.webgl, 'webgl', 2)
            .having((h) => h.caps, 'caps', contains('focus'))
            .having((h) => h.compatible, 'compatible', isTrue),
      );
      expect(
        _parse('hello', {'v': '2.0'}),
        isA<Street3DHello>()
            .having((h) => h.compatible, 'compatible', isFalse)
            .having((h) => h.webgl, 'webgl', 0),
      );
    });

    test('ready, tap and camera', () {
      expect(
        _parse('ready', {'restored': true, 'spaces': 3, 'residents': 2}),
        isA<Street3DReady>().having(
          (r) => (r.restored, r.spaces, r.residents),
          'fields',
          (true, 3, 2),
        ),
      );
      expect(
        _parse('tap', {'kind': 'resident', 'id': 'ai1', 'spaceId': 'alice'}),
        isA<Street3DTap>().having((t) => (t.kind, t.id, t.spaceId), 'fields', (
          'resident',
          'ai1',
          'alice',
        )),
      );
      expect(
        _parse('tap', {'kind': 'villa', 'id': 'alice'}),
        isA<Street3DTap>().having((t) => t.spaceId, 'spaceId', isNull),
      );
      expect(
        _parse('camera', {'mode': 'villa', 'spaceId': 'alice'}),
        isA<Street3DCamera>().having((c) => (c.mode, c.spaceId), 'fields', (
          'villa',
          'alice',
        )),
      );
      expect(
        _parse('camera', {'mode': 'overview'}),
        isA<Street3DCamera>().having((c) => c.spaceId, 'spaceId', isNull),
      );
    });

    test('errors and stats', () {
      expect(
        _parse('error', {
          'code': 'bad_payload',
          'message': 'presence.residents[3].x is not a finite number',
          'fatal': false,
          'ref': 'p-42',
        }),
        isA<Street3DPageError>().having(
          (e) => (e.code, e.fatal, e.ref),
          'fields',
          ('bad_payload', false, 'p-42'),
        ),
      );
      // protocol_mismatch and webgl_unavailable are always fatal.
      expect(
        _parse('error', {
          'code': 'protocol_mismatch',
          'message': 'host is 2.0',
          'fatal': false,
        }),
        isA<Street3DPageError>().having((e) => e.fatal, 'fatal', isTrue),
      );
      expect(
        _parse('stats', {
          'fps': 29.5,
          'frameMs': 4.25,
          'calls': 41,
          'mode': 'running',
          'residents': {'shown': 3, 'culled': 1, 'unplaced': 0},
        }),
        isA<Street3DStats>().having(
          (s) => (
            s.fps,
            s.frameMs,
            s.calls,
            s.mode,
            s.shown,
            s.culled,
            s.unplaced,
          ),
          'fields',
          (29.5, 4.25, 41, 'running', 3, 1, 0),
        ),
      );
    });

    test('a missing or null payload is read as {}, as PROTOCOL.md says', () {
      for (final raw in [
        jsonEncode({'v': 1, 'type': 'ready'}),
        jsonEncode({'v': 1, 'type': 'ready', 'payload': null}),
      ]) {
        final message = Street3DPageMessage.parse(raw);
        expect(message, isA<Street3DInvalidMessage>(), reason: raw);
        expect(
          (message as Street3DInvalidMessage).reason,
          'ready.restored is invalid',
          reason: raw,
        );
      }
    });

    test('anything malformed, unknown or oversized is invalid', () {
      final raws = [
        'not json',
        '[]',
        '"hello"',
        jsonEncode({'v': 2, 'type': 'ready', 'payload': {}}),
        jsonEncode({'v': 1, 'payload': {}}),
        jsonEncode({'v': 1, 'type': 'ready', 'payload': []}),
        _page('teleport', {}),
        _page('hello', {'v': 1}),
        _page('ready', {'restored': 'yes', 'spaces': 1, 'residents': 0}),
        _page('tap', {'kind': 'ground', 'id': 'alice'}),
        _page('tap', {'kind': 'villa', 'id': 'bad id'}),
        _page('camera', {'mode': 'free'}),
        _page('error', {'code': 'internal'}),
        _page('stats', {
          'fps': 30,
          'frameMs': 1,
          'calls': -1,
          'mode': 'idle',
          'residents': {'shown': 0, 'culled': 0, 'unplaced': 0},
        }),
      ];
      for (final raw in raws) {
        expect(
          Street3DPageMessage.parse(raw),
          isA<Street3DInvalidMessage>(),
          reason: raw,
        );
      }
      final big = _page('error', {
        'code': 'internal',
        'message': 'x' * (street3dMaxMessageBytes + 1),
        'fatal': false,
      });
      expect(
        Street3DPageMessage.parse(big),
        isA<Street3DInvalidMessage>().having(
          (m) => m.reason,
          'reason',
          contains('256 KiB'),
        ),
      );
    });
  });
}
