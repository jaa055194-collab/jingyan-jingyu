import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

enum PersonaHistoryKind { initialize, selfIterate, edit, revert, lock }

/// A disclosure-safe projection. Names, values, snapshots, reasons, actors and
/// evidence never leave the parser. Diff counts include removed fields.
final class PersonaHistoryEntry {
  PersonaHistoryEntry._({
    required this.version,
    required this.kind,
    required this.at,
    required this.lockedBefore,
    required this.lockedAfter,
    required Map<String, int> changedFields,
  }) : changedFields = Map.unmodifiable(changedFields);

  final int version;
  final PersonaHistoryKind kind;
  final DateTime at;
  final bool? lockedBefore;
  final bool lockedAfter;
  final Map<String, int> changedFields;
}

final class PersonaHistoryPage {
  PersonaHistoryPage._(List<PersonaHistoryEntry> entries, this.nextAfterVersion)
    : entries = List.unmodifiable(entries);

  final List<PersonaHistoryEntry> entries;
  final int? nextAfterVersion;
}

typedef PersonaHistoryLoader = Future<PersonaHistoryPage> Function(
  String profileId, {
  required int afterVersion,
  required HostReadCancellation cancellation,
});

/// Reads history for a profile already resolved by the owner-config editor.
/// The host revalidates ownership. There is no discovery, auth replay or write.
class PersonaHistoryApi {
  PersonaHistoryApi(this._connection);

  final HostConnection _connection;
  static const pageSize = 20;
  static const maxResponseBytes = 2 * 1024 * 1024;
  static const _layers = {'p0', 'p1', 'p2'};

  Future<PersonaHistoryPage> read(
    String profileId, {
    required int afterVersion,
    required HostReadCancellation cancellation,
  }) async {
    try {
      final id = AiId.parse(profileId).value;
      if (afterVersion < 0) _invalid();
      final body = await _connection.getBoundedJsonWithQuery(
        Routes.aiPersonaHistory.replaceFirst('{aiId}', Uri.encodeComponent(id)),
        query: {'afterVersion': '$afterVersion', 'limit': '$pageSize'},
        maxResponseBytes: maxResponseBytes,
        cancellation: cancellation,
      );
      _exact(body, const {'changes', 'nextAfterVersion'});
      final raw = body['changes'];
      if (raw is! List || raw.length > pageSize) _invalid();
      final entries = <PersonaHistoryEntry>[];
      var previous = afterVersion;
      for (final value in raw) {
        final row = _parseRow(_object(value));
        if (row.version <= previous) _invalid();
        entries.add(row);
        previous = row.version;
      }
      final next = body['nextAfterVersion'];
      if (next != null &&
          (next is! int || entries.length != pageSize || next != previous)) {
        _invalid();
      }
      return PersonaHistoryPage._(entries, next as int?);
    } on FormatException {
      // JSON/ID parser errors may carry source material. Never forward it.
      _invalid();
    }
  }

  static PersonaHistoryEntry _parseRow(Map<String, Object?> row) {
    _exact(row, const {
      'id',
      'version',
      'kind',
      'actorAccountId',
      'before',
      'after',
      'diff',
      'reason',
      'evidenceIds',
      'at',
      'lockedBefore',
      'lockedAfter',
      'revertsChangeId',
    });
    final version = row['version'];
    final kind = switch (row['kind']) {
      'initialize' => PersonaHistoryKind.initialize,
      'selfIterate' => PersonaHistoryKind.selfIterate,
      'edit' => PersonaHistoryKind.edit,
      'revert' => PersonaHistoryKind.revert,
      'lock' => PersonaHistoryKind.lock,
      _ => null,
    };
    final textAt = row['at'];
    final at = textAt is String ? DateTime.tryParse(textAt) : null;
    final before = row['lockedBefore'];
    final after = row['lockedAfter'];
    final evidence = row['evidenceIds'];
    final revert = row['revertsChangeId'];
    final initial = kind == PersonaHistoryKind.initialize;
    if (version is! int ||
        version < 1 ||
        kind == null ||
        (version == 1) != initial ||
        at == null ||
        !at.isUtc ||
        at.toIso8601String() != textAt ||
        after is! bool ||
        row['id'] is! String ||
        row['actorAccountId'] is! String ||
        row['reason'] is! String ||
        evidence is! List ||
        evidence.any((value) => value is! String) ||
        (kind == PersonaHistoryKind.revert
            ? revert is! String
            : revert != null) ||
        (initial
            ? before != null || row['before'] != null
            : before is! bool || row['before'] == null)) {
      _invalid();
    }
    if (!initial) _readLayers(row['before'], diff: false);
    _readLayers(row['after'], diff: false);
    final changed = _readLayers(row['diff'], diff: true);
    return PersonaHistoryEntry._(
      version: version,
      kind: kind,
      at: at,
      lockedBefore: before as bool?,
      lockedAfter: after,
      changedFields: changed,
    );
  }

  static Map<String, int> _readLayers(Object? value, {required bool diff}) {
    final layers = _object(value);
    _exact(layers, _layers);
    final counts = <String, int>{};
    for (final name in _layers) {
      final fields = _object(layers[name]);
      if ((!diff && fields.isEmpty) ||
          fields.values.any(
            (value) => value is! String && !(diff && value == null),
          )) {
        _invalid();
      }
      if (diff) counts[name] = fields.length;
    }
    return counts;
  }

  static Map<String, Object?> _object(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) _invalid();
    return value.cast<String, Object?>();
  }

  static void _exact(Map<String, Object?> body, Set<String> keys) {
    if (body.length != keys.length || !keys.every(body.containsKey)) _invalid();
  }

  static Never _invalid() => throw const FormatException('人格历史响应无法验证');
}
