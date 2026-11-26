/// The app's half of the 3D street bridge, PROTOCOL.md v1.0 in
/// packages/jingyu_street3d_web: builds the envelopes the page expects and
/// reads the ones it posts. Pure Dart; web/src/protocol.js is the page's half.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../../net/world_api.dart';

const street3dProtocolVersion = '1.0';
const street3dMaxSpaces = 12;
const street3dMaxResidents = 8;
const street3dMaxResidentsPerMessage = 32;
const street3dMaxMessageBytes = 256 * 1024;

/// The page cuts longer name tags, so they are cut here first.
const street3dMaxLabelLength = 32;

/// Plots on the street. A space without a slot in 0..11 gets one from the page.
const street3dSlotCount = 12;

final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Whether [id] can name a space or a resident on the page.
bool isStreet3DId(String id) => _idPattern.hasMatch(id);

/// [text] trimmed and cut to [street3dMaxLabelLength] characters; null when
/// nothing is left.
String? street3dLabel(String? text) {
  final trimmed = text?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final runes = trimmed.runes.toList();
  if (runes.length <= street3dMaxLabelLength) return trimmed;
  return String.fromCharCodes(runes.take(street3dMaxLabelLength));
}

/// How a villa's owner relates to the signed-in account.
enum Street3DRelation {
  self('self'),
  ownAi('own_ai'),
  friend('friend'),
  other('other');

  const Street3DRelation(this.wire);
  final String wire;
}

/// How a resident relates to the signed-in account. It decides who stays on
/// screen when more than the page's limit are around.
enum Street3DRole {
  self('self'),
  ownAi('own_ai'),
  friend('friend'),
  visitor('visitor'),
  other('other');

  const Street3DRole(this.wire);
  final String wire;
}

/// How much of a layout goes into a layout message.
enum _Detail { full, rooms, count }

/// One villa: the host's layout of a space plus where and how the street
/// shows it.
class Street3DSpace {
  const Street3DSpace({
    required this.layout,
    this.slot,
    this.label,
    this.relation = Street3DRelation.other,
  });

  final WorldSpaceLayout layout;
  final int? slot;
  final String? label;
  final Street3DRelation relation;

  /// The layout as GET /world/spaces/{spaceId}/layout serves it, plus the
  /// street fields slot, label and relation.
  Map<String, Object?> toJson() => _json(_Detail.full);

  Map<String, Object?> _json(_Detail detail) {
    final slot = this.slot;
    final label = street3dLabel(this.label);
    return {
      'spaceId': layout.spaceId,
      'version': layout.version,
      'style': layout.style,
      'mainColor': layout.mainColor,
      'rooms': [
        for (final room in layout.rooms)
          if (detail == _Detail.count)
            {'roomId': room.roomId}
          else
            {
              'roomId': room.roomId,
              'name': room.name,
              'furniture': [
                if (detail == _Detail.full)
                  for (final item in room.furniture)
                    {
                      'itemId': item.itemId,
                      'assetId': item.assetId,
                      'x': item.x,
                      'y': item.y,
                      'z': item.z,
                      'rotation': item.rotation,
                    },
              ],
            },
      ],
      'updatedAt': layout.updatedAt.toUtc().toIso8601String(),
      if (slot != null && slot >= 0 && slot < street3dSlotCount) 'slot': slot,
      'label': ?label,
      'relation': relation.wire,
    };
  }
}

/// One resident's position, in the plot coordinates of its space.
class Street3DResident {
  const Street3DResident({
    required this.record,
    this.label,
    this.role = Street3DRole.other,
  });

  final WorldPresenceRecord record;
  final String? label;
  final Street3DRole role;

  Map<String, Object?> toJson() {
    final label = street3dLabel(this.label);
    return {
      'residentId': record.residentId,
      'spaceId': record.spaceId,
      'x': record.x,
      'y': record.y,
      'z': record.z,
      'motion': record.motion,
      'updatedAt': record.updatedAt.toUtc().toIso8601String(),
      'label': ?label,
      'role': role.wire,
    };
  }
}

/// Builds host -> page envelopes {v: 1, type, id, ts, payload} as JSON text.
class Street3DHostMessages {
  Street3DHostMessages({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  int _sequence = 0;

  /// Answers the page's hello. Values outside the protocol's ranges become
  /// the nearest allowed one.
  String helloAck({
    String theme = 'light',
    String quality = 'high',
    int maxResidents = street3dMaxResidents,
    int statsIntervalMs = 0,
  }) => _encode('hello-ack', {
    'v': street3dProtocolVersion,
    'config': {
      'theme': _mode(theme),
      'quality': quality == 'low' ? 'low' : 'high',
      'maxResidents': math.min(math.max(maxResidents, 1), street3dMaxResidents),
      'statsIntervalMs': statsIntervalMs <= 0
          ? 0
          : math.max(statsIntervalMs, 1000),
    },
  });

  /// The whole street; the page removes villas missing from it. The first
  /// [street3dMaxSpaces] spaces with a valid, unrepeated id go out. A message
  /// over [street3dMaxMessageBytes] is sent without furniture (v1 pages only
  /// count rooms), and if it is still too large, with bare room ids.
  String layout(List<Street3DSpace> spaces) {
    final seen = <String>{};
    final kept = [
      for (final space in spaces)
        if (isStreet3DId(space.layout.spaceId) &&
            seen.add(space.layout.spaceId))
          space,
    ].take(street3dMaxSpaces).toList();
    final envelope = _envelope('layout');
    var json = '';
    for (final detail in _Detail.values) {
      envelope['payload'] = {
        'spaces': [for (final space in kept) space._json(detail)],
      };
      json = jsonEncode(envelope);
      if (utf8.encode(json).length <= street3dMaxMessageBytes) break;
    }
    return json;
  }

  /// A full snapshot of the residents in the street's spaces; the page
  /// removes the ones missing from it. [t] must grow with every presence
  /// message of a page session. The first [street3dMaxResidentsPerMessage]
  /// residents with valid, unrepeated ids go out.
  String presence(int t, List<Street3DResident> residents) {
    final seen = <String>{};
    final kept = [
      for (final resident in residents)
        if (isStreet3DId(resident.record.residentId) &&
            isStreet3DId(resident.record.spaceId) &&
            seen.add(resident.record.residentId))
          resident,
    ].take(street3dMaxResidentsPerMessage);
    return _encode('presence', {
      't': t,
      'residents': [for (final resident in kept) resident.toJson()],
    });
  }

  /// Stop drawing, for example while the app is in the background.
  String pause() => _encode('pause', const {});

  String resume() => _encode('resume', const {});

  String theme(String mode) => _encode('theme', {'mode': _mode(mode)});

  String focusOverview() => _encode('focus', const {'kind': 'overview'});

  String focusVilla(String spaceId) =>
      _encode('focus', {'kind': 'villa', 'id': spaceId});

  String focusResident(String residentId) =>
      _encode('focus', {'kind': 'resident', 'id': residentId});

  static String _mode(String mode) => mode == 'dark' ? 'dark' : 'light';

  String _encode(String type, Map<String, Object?> payload) =>
      jsonEncode(_envelope(type, payload));

  Map<String, Object?> _envelope(
    String type, [
    Map<String, Object?> payload = const {},
  ]) {
    _sequence += 1;
    return {
      'v': 1,
      'type': type,
      'id': 'h-$_sequence',
      'ts': _clock().millisecondsSinceEpoch,
      'payload': payload,
    };
  }
}

/// A message the page posted.
sealed class Street3DPageMessage {
  const Street3DPageMessage();

  /// Reads one page -> host envelope. Never throws: anything malformed,
  /// unknown or larger than [street3dMaxMessageBytes] becomes a
  /// [Street3DInvalidMessage].
  static Street3DPageMessage parse(String raw) {
    if (raw.length > street3dMaxMessageBytes ||
        utf8.encode(raw).length > street3dMaxMessageBytes) {
      return const Street3DInvalidMessage('message is larger than 256 KiB');
    }
    Object? envelope;
    try {
      envelope = jsonDecode(raw);
    } on FormatException {
      return const Street3DInvalidMessage('message is not JSON');
    }
    if (envelope is! Map<String, Object?>) {
      return const Street3DInvalidMessage('message is not an object');
    }
    final v = envelope['v'];
    final type = envelope['type'];
    final payload = envelope['payload'];
    if (v is! num || v != 1) {
      return const Street3DInvalidMessage('envelope v is not 1');
    }
    if (type is! String) {
      return const Street3DInvalidMessage('envelope type is not a string');
    }
    if (payload is! Map<String, Object?>) {
      return Street3DInvalidMessage('$type payload is not an object');
    }
    try {
      return switch (type) {
        'hello' => Street3DHello._fromPayload(payload),
        'ready' => Street3DReady._fromPayload(payload),
        'tap' => Street3DTap._fromPayload(payload),
        'camera' => Street3DCamera._fromPayload(payload),
        'error' => Street3DPageError._fromPayload(payload),
        'stats' => Street3DStats._fromPayload(payload),
        _ => Street3DInvalidMessage('unknown type $type'),
      };
    } on _BadField catch (bad) {
      return Street3DInvalidMessage('$type.${bad.field} is invalid');
    }
  }
}

/// The page has loaded, has a WebGL context and waits for hello-ack.
final class Street3DHello extends Street3DPageMessage {
  const Street3DHello({
    required this.version,
    required this.caps,
    required this.webgl,
  });

  factory Street3DHello._fromPayload(Map<String, Object?> payload) {
    final caps = payload['caps'];
    final renderer = payload['renderer'];
    final webgl = renderer is Map<String, Object?> ? renderer['webgl'] : null;
    return Street3DHello(
      version: _field<String>(payload, 'v'),
      caps: {
        if (caps is List<Object?>)
          for (final cap in caps)
            if (cap is String) cap,
      },
      webgl: webgl is int ? webgl : 0,
    );
  }

  /// The page's protocol version, such as '1.0'.
  final String version;
  final Set<String> caps;

  /// The WebGL version, 1 or 2; 0 when the page did not say.
  final int webgl;

  /// The page speaks protocol 1.x.
  bool get compatible => version.split('.').first == '1';
}

/// The page has drawn its first frame of the street, or redrawn it after
/// its WebGL context came back ([restored]).
final class Street3DReady extends Street3DPageMessage {
  const Street3DReady({
    required this.restored,
    required this.spaces,
    required this.residents,
  });

  factory Street3DReady._fromPayload(Map<String, Object?> payload) =>
      Street3DReady(
        restored: _field<bool>(payload, 'restored'),
        spaces: _countField(payload, 'spaces'),
        residents: _countField(payload, 'residents'),
      );

  final bool restored;
  final int spaces;
  final int residents;
}

/// A villa or a resident was tapped.
final class Street3DTap extends Street3DPageMessage {
  const Street3DTap({required this.kind, required this.id, this.spaceId});

  factory Street3DTap._fromPayload(Map<String, Object?> payload) {
    final kind = _field<String>(payload, 'kind');
    if (kind != 'villa' && kind != 'resident') throw const _BadField('kind');
    return Street3DTap(
      kind: kind,
      id: _idField(payload, 'id'),
      spaceId: _optionalIdField(payload, 'spaceId'),
    );
  }

  /// 'villa', where [id] is the spaceId, or 'resident'.
  final String kind;
  final String id;

  /// The space a tapped resident is in.
  final String? spaceId;
}

/// The camera finished flying to the overview or to one villa.
final class Street3DCamera extends Street3DPageMessage {
  const Street3DCamera({required this.mode, this.spaceId});

  factory Street3DCamera._fromPayload(Map<String, Object?> payload) {
    final mode = _field<String>(payload, 'mode');
    if (mode != 'overview' && mode != 'villa') throw const _BadField('mode');
    return Street3DCamera(
      mode: mode,
      spaceId: _optionalIdField(payload, 'spaceId'),
    );
  }

  /// 'overview' or 'villa'.
  final String mode;
  final String? spaceId;
}

/// Something went wrong in the page. A [fatal] error ends the page session.
final class Street3DPageError extends Street3DPageMessage {
  const Street3DPageError({
    required this.code,
    required this.message,
    required this.fatal,
    this.ref,
  });

  factory Street3DPageError._fromPayload(Map<String, Object?> payload) {
    final code = _field<String>(payload, 'code');
    final ref = payload['ref'];
    return Street3DPageError(
      code: code,
      message: _field<String>(payload, 'message'),
      // These two are fatal by definition, whatever the page says.
      fatal:
          payload['fatal'] == true ||
          code == 'protocol_mismatch' ||
          code == 'webgl_unavailable',
      ref: ref is String ? ref : null,
    );
  }

  final String code;
  final String message;
  final bool fatal;

  /// The id of the host message the error is about.
  final String? ref;
}

/// Rendering statistics, sent when hello-ack asked for them.
final class Street3DStats extends Street3DPageMessage {
  const Street3DStats({
    required this.fps,
    required this.frameMs,
    required this.calls,
    required this.mode,
    required this.shown,
    required this.culled,
    required this.unplaced,
  });

  factory Street3DStats._fromPayload(Map<String, Object?> payload) {
    final residents = _field<Map<String, Object?>>(payload, 'residents');
    return Street3DStats(
      fps: _numberField(payload, 'fps'),
      frameMs: _numberField(payload, 'frameMs'),
      calls: _countField(payload, 'calls'),
      mode: _field<String>(payload, 'mode'),
      shown: _countField(residents, 'shown'),
      culled: _countField(residents, 'culled'),
      unplaced: _countField(residents, 'unplaced'),
    );
  }

  final double fps;
  final double frameMs;
  final int calls;

  /// 'running', 'idle', 'paused' or 'hidden'.
  final String mode;
  final int shown;
  final int culled;
  final int unplaced;
}

/// A message that could not be used; [reason] says why.
final class Street3DInvalidMessage extends Street3DPageMessage {
  const Street3DInvalidMessage(this.reason);

  final String reason;
}

class _BadField implements Exception {
  const _BadField(this.field);

  final String field;
}

T _field<T>(Map<String, Object?> payload, String field) {
  final value = payload[field];
  if (value is T) return value;
  throw _BadField(field);
}

String _idField(Map<String, Object?> payload, String field) {
  final value = _field<String>(payload, field);
  if (!isStreet3DId(value)) throw _BadField(field);
  return value;
}

String? _optionalIdField(Map<String, Object?> payload, String field) =>
    payload[field] == null ? null : _idField(payload, field);

double _numberField(Map<String, Object?> payload, String field) {
  final value = payload[field];
  if (value is num && value.isFinite) return value.toDouble();
  throw _BadField(field);
}

int _countField(Map<String, Object?> payload, String field) {
  final value = payload[field];
  if (value is num && value.isFinite && value >= 0 && value == value.floor()) {
    return value.toInt();
  }
  throw _BadField(field);
}
