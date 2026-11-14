import 'dart:convert';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';

import '../../storage/cipher.dart';
import '../../storage/database.dart';

/// Explicit initial values for all three layers. Keys belong to their declared
/// layer; this internal service accepts no chat text or model tool arguments.
final class PersonaLayers {
  PersonaLayers({
    required Map<String, String> p0,
    required Map<String, String> p1,
    required Map<String, String> p2,
  }) : p0 = Map.unmodifiable(p0),
       p1 = Map.unmodifiable(p1),
       p2 = Map.unmodifiable(p2);

  final Map<String, String> p0;
  final Map<String, String> p1;
  final Map<String, String> p2;

  Map<String, Object?> toJson() => {'p0': p0, 'p1': p1, 'p2': p2};
}

/// Field patches: an absent key preserves its value; null explicitly removes it.
/// Each layer must remain nonempty. Actual changes, not a chat transcript, are
/// stored in history. Layer classification is the trusted caller's duty.
final class PersonaDiff {
  PersonaDiff({
    Map<String, String?> p0 = const {},
    Map<String, String?> p1 = const {},
    Map<String, String?> p2 = const {},
  }) : p0 = Map.unmodifiable(p0),
       p1 = Map.unmodifiable(p1),
       p2 = Map.unmodifiable(p2);

  final Map<String, String?> p0;
  final Map<String, String?> p1;
  final Map<String, String?> p2;

  Map<String, Object?> toJson() => {'p0': p0, 'p1': p1, 'p2': p2};
}

enum PersonaChangeKind { initialize, selfIterate, edit, revert, lock }

final class PersonaCard {
  const PersonaCard({
    required this.ai,
    required this.version,
    required this.locked,
    required this.layers,
  });

  final AiId ai;
  final int version;
  final bool locked;
  final PersonaLayers layers;
}

final class PersonaChange {
  PersonaChange({
    required this.id,
    required this.version,
    required this.kind,
    required this.actorAccountId,
    required this.before,
    required this.after,
    required this.diff,
    required this.reason,
    required List<String> evidenceIds,
    required this.at,
    required this.lockedBefore,
    required this.lockedAfter,
    this.revertsChangeId,
  }) : evidenceIds = List.unmodifiable(evidenceIds);

  final String id;
  final int version;
  final PersonaChangeKind kind;
  final AccountId actorAccountId;
  final PersonaLayers? before;
  final PersonaLayers after;
  final PersonaDiff diff;
  final String reason;
  final List<String> evidenceIds;
  final DateTime at;
  final bool? lockedBefore;
  final bool lockedAfter;
  final String? revertsChangeId;
}

/// Pure internal service. Execution identity and owner scope must be supplied
/// by a trusted authenticated boundary, never by model output or HTTP payloads.
abstract interface class PersonaService {
  Future<Result<PersonaCard>> initialize(
    AiId ai, {
    required PersonaLayers initial,
  });
  Future<Result<PersonaCard>> current(AiId ai);
  Future<Result<List<PersonaChange>>> history(AiId ai);
  Future<Result<PersonaChange>> selfIterate(
    AiId ai,
    PersonaDiff diff, {
    required int expectedVersion,
    required String reason,
    required List<String> evidenceIds,
  });
  Future<Result<PersonaChange>> edit(
    AiId ai,
    PersonaDiff diff, {
    required int expectedVersion,
    required String reason,
  });
  Future<Result<PersonaChange>> lock(
    AiId ai, {
    required bool locked,
    required int expectedVersion,
  });

  /// Append the selected content change's before-snapshot as a new version.
  /// Later content edits are also undone; the current operator lock is retained.
  /// Initialization and lock records are not content changes and cannot revert.
  Future<Result<PersonaChange>> revert(
    AiId ai,
    String changeId, {
    required int expectedVersion,
    required String reason,
  });
}

/// A1 supersedes FR-04/FR-41's P0 approval prohibition: unlocked P0/P1 may
/// self-iterate, P2 is always autonomous. M06's blanket locked-selfIterate
/// comment/acceptance conflicts with its own rule 1 and A1; only P0/P1 are locked.
/// No evaluation frequency or magnitude threshold is invented here.
final class SqlitePersonaService implements PersonaService {
  SqlitePersonaService.forOwner({
    required String ownerId,
    required String actorAccountId,
    required Database database,
    required ColumnCipher cipher,
    required Clock clock,
  }) : _ownerId = validateId(ownerId, kind: 'owner'),
       _actorId = validateId(actorAccountId, kind: 'actor'),
       _db = database,
       _cipher = cipher,
       _clock = clock;

  final String _ownerId;
  final String _actorId;
  final Database _db;
  final ColumnCipher _cipher;
  final Clock _clock;
  final _random = Random.secure();
  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  // Body/reason text may contain tabs and ordinary line breaks; keys may not.
  static final _control = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]');
  static final _keyControl = RegExp(r'[\x00-\x1f\x7f-\x9f]');

  Future<Result<T>> _withAi<T>(
    AiId ai,
    Future<Result<T>> Function(Tx tx, bool isOwner) operation,
  ) async {
    try {
      return await _db.transaction((tx) async {
        // Recheck canonical identity in the same transaction as every read/CAS.
        // No admin flag and no stale cached operator relationship is trusted.
        final identity = await tx.query(
          '''
SELECT a.id AS ai_account_id
FROM ai_profile p
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id
JOIN account owner ON owner.id=o.operator_id AND owner.kind='human' AND owner.disabled=0
WHERE p.id=? AND o.operator_id=? AND (?=owner.id OR ?=a.id)
''',
          [ai.value, _ownerId, _actorId, _actorId],
        );
        if (identity.length != 1) {
          return err<T>(FailureCode.notFound, 'Persona not found');
        }
        return operation(tx, _actorId == _ownerId);
      });
    } on _InvalidStoredPersona {
      return err(FailureCode.internal, 'Persona authentication failed');
    } on FormatException {
      return err(FailureCode.internal, 'Invalid stored persona');
    }
  }

  bool _text(String text) => text.trim().isNotEmpty && !_control.hasMatch(text);
  bool _key(String key) =>
      _text(key) && key.trim() == key && !_keyControl.hasMatch(key);
  bool _validLayers(PersonaLayers layers) =>
      [layers.p0, layers.p1, layers.p2].every(
        (layer) =>
            layer.isNotEmpty &&
            layer.entries.every(
              (entry) => _key(entry.key) && _text(entry.value),
            ),
      );
  bool _validDiff(PersonaDiff diff) => [diff.p0, diff.p1, diff.p2].every(
    (layer) => layer.entries.every(
      (entry) =>
          _key(entry.key) && (entry.value == null || _text(entry.value!)),
    ),
  );

  String _aad(AiId ai, int version, String field) =>
      jsonEncode([_ownerId, ai.value, version, field]);

  String _seal(AiId ai, int version, String field, Object? value) =>
      _cipher.encrypt(jsonEncode(value), aad: _aad(ai, version, field));

  Object? _open(AiId ai, int version, String field, Object? sealed) {
    if (sealed is! String) throw const _InvalidStoredPersona();
    final result = _cipher.decrypt(sealed, aad: _aad(ai, version, field));
    if (result case Err<String>()) throw const _InvalidStoredPersona();
    return jsonDecode(result.value);
  }

  Map<String, String?> _map(Object? value, {required bool nullable}) {
    if (value is! Map<String, dynamic>) throw const _InvalidStoredPersona();
    final result = <String, String?>{};
    for (final entry in value.entries) {
      if (entry.value is! String && !(nullable && entry.value == null)) {
        throw const _InvalidStoredPersona();
      }
      result[entry.key] = entry.value as String?;
    }
    return result;
  }

  PersonaLayers _layers(Object? value) {
    if (value is! Map<String, dynamic> || value.length != 3) {
      throw const _InvalidStoredPersona();
    }
    Map<String, String> layer(String name) =>
        _map(value[name], nullable: false).cast<String, String>();
    final result = PersonaLayers(
      p0: layer('p0'),
      p1: layer('p1'),
      p2: layer('p2'),
    );
    if (!_validLayers(result)) throw const _InvalidStoredPersona();
    return result;
  }

  PersonaDiff _diff(Object? value) {
    if (value is! Map<String, dynamic> || value.length != 3) {
      throw const _InvalidStoredPersona();
    }
    return PersonaDiff(
      p0: _map(value['p0'], nullable: true),
      p1: _map(value['p1'], nullable: true),
      p2: _map(value['p2'], nullable: true),
    );
  }

  Future<PersonaCard?> _current(Tx tx, AiId ai) async {
    final rows = await tx.query(
      '''
SELECT version,locked,encrypted_card FROM persona_cards
WHERE owner_id=? AND ai_profile_id=?''',
      [_ownerId, ai.value],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final version = row['version'] as int;
    return PersonaCard(
      ai: ai,
      version: version,
      locked: row['locked'] == 1,
      layers: _layers(_open(ai, version, 'card', row['encrypted_card'])),
    );
  }

  @override
  Future<Result<PersonaCard>> current(AiId ai) => _withAi(ai, (tx, _) async {
    final card = await _current(tx, ai);
    return card == null
        ? err(FailureCode.notFound, 'Persona not found')
        : Ok(card);
  });

  PersonaChange _change(AiId ai, Map<String, Object?> row) {
    final version = row['version'] as int;
    final before = _open(ai, version, 'before', row['encrypted_before']);
    final evidence = _open(ai, version, 'evidence', row['encrypted_evidence']);
    final reason = _open(ai, version, 'reason', row['encrypted_reason']);
    if (reason is! String ||
        evidence is! List ||
        evidence.any((id) => id is! String)) {
      throw const _InvalidStoredPersona();
    }
    return PersonaChange(
      id: row['id'] as String,
      version: version,
      kind: PersonaChangeKind.values.byName(row['kind'] as String),
      actorAccountId: AccountId.parse(row['actor_id'] as String),
      before: before == null ? null : _layers(before),
      after: _layers(_open(ai, version, 'after', row['encrypted_after'])),
      diff: _diff(_open(ai, version, 'diff', row['encrypted_diff'])),
      reason: reason,
      evidenceIds: evidence.cast<String>(),
      at: DateTime.parse(row['at'] as String),
      lockedBefore: row['locked_before'] == null
          ? null
          : row['locked_before'] == 1,
      lockedAfter: row['locked_after'] == 1,
      revertsChangeId: row['reverts_change_id'] as String?,
    );
  }

  @override
  Future<Result<List<PersonaChange>>> history(AiId ai) =>
      _withAi(ai, (tx, _) async {
        final rows = await tx.query(
          '''
SELECT * FROM persona_history WHERE owner_id=? AND ai_profile_id=? ORDER BY version
''',
          [_ownerId, ai.value],
        );
        if (rows.isEmpty) return err(FailureCode.notFound, 'Persona not found');
        return Ok(List.unmodifiable(rows.map((row) => _change(ai, row))));
      });

  String _changeId() =>
      'persona_${List.generate(24, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<PersonaChange> _append(
    Tx tx,
    AiId ai, {
    required int version,
    required PersonaChangeKind kind,
    required PersonaLayers? before,
    required PersonaLayers after,
    required PersonaDiff diff,
    required String reason,
    required List<String> evidenceIds,
    required bool? lockedBefore,
    required bool lockedAfter,
    String? revertsChangeId,
  }) async {
    final id = _changeId();
    final at = _clock.now().toUtc();
    await tx.execute(
      '''
INSERT INTO persona_history
(id,owner_id,ai_profile_id,version,kind,actor_id,at,locked_before,locked_after,
 reverts_change_id,encrypted_before,encrypted_after,encrypted_diff,encrypted_reason,encrypted_evidence)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        id,
        _ownerId,
        ai.value,
        version,
        kind.name,
        _actorId,
        at.toIso8601String(),
        lockedBefore == null ? null : (lockedBefore ? 1 : 0),
        lockedAfter ? 1 : 0,
        revertsChangeId,
        _seal(ai, version, 'before', before?.toJson()),
        _seal(ai, version, 'after', after.toJson()),
        _seal(ai, version, 'diff', diff.toJson()),
        _seal(ai, version, 'reason', reason),
        _seal(ai, version, 'evidence', evidenceIds),
      ],
    );
    return PersonaChange(
      id: id,
      version: version,
      kind: kind,
      actorAccountId: AccountId.parse(_actorId),
      before: before,
      after: after,
      diff: diff,
      reason: reason,
      evidenceIds: evidenceIds,
      at: at,
      lockedBefore: lockedBefore,
      lockedAfter: lockedAfter,
      revertsChangeId: revertsChangeId,
    );
  }

  @override
  Future<Result<PersonaCard>> initialize(
    AiId ai, {
    required PersonaLayers initial,
  }) => _withAi(ai, (tx, isOwner) async {
    if (!isOwner) return err(FailureCode.forbidden, 'Owner operation required');
    if (!_validLayers(initial)) {
      return err(
        FailureCode.invalidArgument,
        'All persona layers are required',
      );
    }
    // Global profile uniqueness denies silent overwrite after operator transfer.
    if ((await tx.query('SELECT 1 FROM persona_cards WHERE ai_profile_id=?', [
      ai.value,
    ])).isNotEmpty) {
      return err(FailureCode.conflict, 'Persona already initialized');
    }
    await tx.execute(
      '''
INSERT INTO persona_cards (owner_id,ai_profile_id,version,locked,encrypted_card)
VALUES (?,?,1,0,?)''',
      [_ownerId, ai.value, _seal(ai, 1, 'card', initial.toJson())],
    );
    await _append(
      tx,
      ai,
      version: 1,
      kind: PersonaChangeKind.initialize,
      before: null,
      after: initial,
      diff: PersonaDiff(p0: initial.p0, p1: initial.p1, p2: initial.p2),
      reason: 'Explicit owner initialization',
      evidenceIds: const [],
      lockedBefore: null,
      lockedAfter: false,
    );
    return Ok(PersonaCard(ai: ai, version: 1, locked: false, layers: initial));
  });

  Map<String, String> _patch(
    Map<String, String> source,
    Map<String, String?> patch,
  ) {
    final next = {...source};
    for (final entry in patch.entries) {
      final value = entry.value;
      if (value == null) {
        next.remove(entry.key);
      } else {
        next[entry.key] = value;
      }
    }
    return next;
  }

  Map<String, String?> _delta(
    Map<String, String> before,
    Map<String, String> after,
  ) => {
    for (final key in {...before.keys, ...after.keys})
      if (before[key] != after[key]) key: after[key],
  };

  PersonaDiff _difference(PersonaLayers before, PersonaLayers after) =>
      PersonaDiff(
        p0: _delta(before.p0, after.p0),
        p1: _delta(before.p1, after.p1),
        p2: _delta(before.p2, after.p2),
      );
  bool _empty(PersonaDiff diff) =>
      diff.p0.isEmpty && diff.p1.isEmpty && diff.p2.isEmpty;

  Future<Result<PersonaChange>> _write(
    Tx tx,
    PersonaCard before, {
    required PersonaLayers after,
    required PersonaDiff diff,
    required PersonaChangeKind kind,
    required bool locked,
    required String reason,
    required List<String> evidenceIds,
    String? revertsChangeId,
  }) async {
    final version = before.version + 1;
    final changed = await tx.execute(
      '''
UPDATE persona_cards SET version=?,locked=?,encrypted_card=?
WHERE owner_id=? AND ai_profile_id=? AND version=?''',
      [
        version,
        locked ? 1 : 0,
        _seal(before.ai, version, 'card', after.toJson()),
        _ownerId,
        before.ai.value,
        before.version,
      ],
    );
    if (changed != 1) {
      return err(FailureCode.conflict, 'Persona version conflict');
    }
    // A database/cipher failure must throw so the entire transaction rolls back.
    final change = await _append(
      tx,
      before.ai,
      version: version,
      kind: kind,
      before: before.layers,
      after: after,
      diff: diff,
      reason: reason,
      evidenceIds: evidenceIds,
      lockedBefore: before.locked,
      lockedAfter: locked,
      revertsChangeId: revertsChangeId,
    );
    return Ok(change);
  }

  Future<Result<PersonaChange>> _mutate(
    AiId ai,
    PersonaDiff diff, {
    required bool self,
    required int expectedVersion,
    required String reason,
    required List<String> evidenceIds,
  }) => _withAi(ai, (tx, isOwner) async {
    if (self == isOwner) {
      return err(FailureCode.forbidden, 'Invalid persona actor');
    }
    if (expectedVersion < 1 ||
        !_text(reason) ||
        !_validDiff(diff) ||
        (self && evidenceIds.isEmpty) ||
        !evidenceIds.every(_id.hasMatch)) {
      return err(FailureCode.invalidArgument, 'Invalid persona change');
    }
    final before = await _current(tx, ai);
    if (before == null) return err(FailureCode.notFound, 'Persona not found');
    if (before.version != expectedVersion) {
      return err(FailureCode.conflict, 'Persona version conflict');
    }
    // Reject a mixed patch atomically, leaving its P2 changes unapplied.
    if (self && before.locked && (diff.p0.isNotEmpty || diff.p1.isNotEmpty)) {
      return err(FailureCode.forbidden, 'Persona is locked');
    }
    final after = PersonaLayers(
      p0: _patch(before.layers.p0, diff.p0),
      p1: _patch(before.layers.p1, diff.p1),
      p2: _patch(before.layers.p2, diff.p2),
    );
    final actual = _difference(before.layers, after);
    if (!_validLayers(after) || _empty(actual)) {
      return err(
        FailureCode.invalidArgument,
        'Empty or invalid persona change',
      );
    }
    return _write(
      tx,
      before,
      after: after,
      diff: actual,
      kind: self ? PersonaChangeKind.selfIterate : PersonaChangeKind.edit,
      locked: before.locked,
      reason: reason,
      evidenceIds: evidenceIds,
    );
  });

  @override
  Future<Result<PersonaChange>> selfIterate(
    AiId ai,
    PersonaDiff diff, {
    required int expectedVersion,
    required String reason,
    required List<String> evidenceIds,
  }) => _mutate(
    ai,
    diff,
    self: true,
    expectedVersion: expectedVersion,
    reason: reason,
    evidenceIds: List.unmodifiable(evidenceIds),
  );

  @override
  Future<Result<PersonaChange>> edit(
    AiId ai,
    PersonaDiff diff, {
    required int expectedVersion,
    required String reason,
  }) => _mutate(
    ai,
    diff,
    self: false,
    expectedVersion: expectedVersion,
    reason: reason,
    evidenceIds: const [],
  );

  @override
  Future<Result<PersonaChange>> lock(
    AiId ai, {
    required bool locked,
    required int expectedVersion,
  }) => _withAi(ai, (tx, isOwner) async {
    if (!isOwner) return err(FailureCode.forbidden, 'Owner operation required');
    if (expectedVersion < 1) {
      return err(FailureCode.invalidArgument, 'Invalid version');
    }
    final before = await _current(tx, ai);
    if (before == null) return err(FailureCode.notFound, 'Persona not found');
    if (before.version != expectedVersion || before.locked == locked) {
      return err(FailureCode.conflict, 'Persona lock or version conflict');
    }
    return _write(
      tx,
      before,
      after: before.layers,
      diff: PersonaDiff(),
      kind: PersonaChangeKind.lock,
      locked: locked,
      reason: locked ? 'Owner locked P0/P1' : 'Owner unlocked P0/P1',
      evidenceIds: const [],
    );
  });

  @override
  Future<Result<PersonaChange>> revert(
    AiId ai,
    String changeId, {
    required int expectedVersion,
    required String reason,
  }) => _withAi(ai, (tx, isOwner) async {
    if (!isOwner) return err(FailureCode.forbidden, 'Owner operation required');
    if (expectedVersion < 1 || !_id.hasMatch(changeId) || !_text(reason)) {
      return err(FailureCode.invalidArgument, 'Invalid persona revert');
    }
    final before = await _current(tx, ai);
    if (before == null) return err(FailureCode.notFound, 'Persona not found');
    if (before.version != expectedVersion) {
      return err(FailureCode.conflict, 'Persona version conflict');
    }
    final rows = await tx.query(
      '''
SELECT * FROM persona_history WHERE owner_id=? AND ai_profile_id=? AND id=?
''',
      [_ownerId, ai.value, changeId],
    );
    if (rows.isEmpty) {
      return err(FailureCode.notFound, 'Persona change not found');
    }
    final selected = _change(ai, rows.single);
    final after = selected.before;
    if (after == null || selected.kind == PersonaChangeKind.lock) {
      return err(
        FailureCode.invalidArgument,
        'Not a revertible content change',
      );
    }
    final diff = _difference(before.layers, after);
    if (_empty(diff)) {
      return err(FailureCode.conflict, 'Persona already restored');
    }
    return _write(
      tx,
      before,
      after: after,
      diff: diff,
      kind: PersonaChangeKind.revert,
      locked: before.locked,
      reason: reason,
      evidenceIds: const [],
      revertsChangeId: selected.id,
    );
  });
}

final class _InvalidStoredPersona implements Exception {
  const _InvalidStoredPersona();
}
