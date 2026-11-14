import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';

import '../../storage/database.dart';

enum LifeActivity {
  sleeping, waking, washing, cooking, eating, reading, writing, daydreaming,
  tidying, wateringPlants, lookingOutside, listeningToMusic, bathing,
  writingDiary, waitingForYou,
}
enum LifeLocation { home, neighborhood, friendsHome, villa }
enum LifeMood { calm, happy, sad, tired, focused, curious, neutral }
enum LifePresence { available, busy, away, offline }
enum LifeRecordKind { activity, gap }

final class LifeState {
  const LifeState({
    required this.activity,
    required this.location,
    required this.energy,
    required this.mood,
    required this.presence,
    required this.focus,
  });
  final LifeActivity activity;
  final LifeLocation location;
  final int energy;
  final LifeMood mood;
  final LifePresence presence;
  final int focus;
}

final class LifeRecord {
  const LifeRecord({
    required this.id,
    required this.ai,
    required this.kind,
    required this.at,
    this.state,
    this.gapStart,
  });
  final String id;
  final AiId ai;
  final LifeRecordKind kind;
  final DateTime at;
  final LifeState? state;
  final DateTime? gapStart;
}

typedef LifeRuleSelector = LifeState Function(
  AiId ai,
  DateTime now,
  LifeState? previous,
);

/// Durable rule-only 60-second heartbeat. No model, proactive, or timer calls.
final class LifeEngine {
  LifeEngine.forOwner({
    required String ownerId,
    required Database db,
    required Clock clock,
    required LifeRuleSelector ruleSelector,
    required Duration gapThreshold,
  }) : _ownerId = validateId(ownerId, kind: 'owner'),
       _db = db,
       _clock = clock,
       _ruleSelector = ruleSelector,
       _gapThreshold = _checkThreshold(gapThreshold);

  final String _ownerId;
  final Database _db;
  final Clock _clock;
  final LifeRuleSelector _ruleSelector;
  final Duration _gapThreshold;
  final Random _random = Random.secure();

  static Duration _checkThreshold(Duration value) {
    if (value < const Duration(seconds: 60)) {
      throw ArgumentError.value(value, 'gapThreshold', 'must be at least 60 seconds');
    }
    return value;
  }

  /// Runs one explicit heartbeat and appends at most one record.
  Future<Result<LifeRecord?>> tick(AiId ai) async {
    final now = _clock.now();
    try {
      return await _db.transaction((tx) async {
        if (!await _identity(tx, ai)) return err(FailureCode.notFound, 'AI not found');
        final row = (await tx.query(
          'SELECT * FROM life_state WHERE owner_id=? AND ai_profile_id=?',
          [_ownerId, ai.value],
        )).firstOrNull;
        final previous = row == null ? null : _state(row);
        if (row != null) {
          final lastHeartbeat = DateTime.parse(row['last_heartbeat_at'] as String);
          if (!now.isAfter(lastHeartbeat)) return const Ok(null);
          final elapsed = now.difference(lastHeartbeat);
          if (elapsed > _gapThreshold) {
            final gap = _recordId('gap');
            await tx.execute(
              '''INSERT INTO activity_log
(id,owner_id,ai_profile_id,kind,at,gap_start)
VALUES (?,?,?,?,?,?)''',
              [gap, _ownerId, ai.value, 'gap', now.toIso8601String(), lastHeartbeat.toIso8601String()],
            );
            await tx.execute(
              'UPDATE life_state SET last_heartbeat_at=?,last_activity_at=? WHERE owner_id=? AND ai_profile_id=?',
              [now.toIso8601String(), now.toIso8601String(), _ownerId, ai.value],
            );
            return Ok(LifeRecord(id: gap, ai: ai, kind: LifeRecordKind.gap,
              at: now, gapStart: lastHeartbeat));
          }
          final lastActivity = DateTime.parse(row['last_activity_at'] as String);
          if (now.difference(lastActivity) < const Duration(seconds: 60)) {
            await tx.execute(
              'UPDATE life_state SET last_heartbeat_at=? WHERE owner_id=? AND ai_profile_id=?',
              [now.toIso8601String(), _ownerId, ai.value],
            );
            return const Ok(null);
          }
        }
        final state = _ruleSelector(ai, now, previous);
        _validateState(state);
        final id = _recordId('activity');
        await tx.execute(
          '''INSERT INTO activity_log
(id,owner_id,ai_profile_id,kind,at,activity,location,energy,mood,presence,focus)
VALUES (?,?,?,?,?,?,?,?,?,?,?)''',
          [id, _ownerId, ai.value, 'activity', now.toIso8601String(), state.activity.name,
            state.location.name, state.energy, state.mood.name, state.presence.name, state.focus],
        );
        await tx.execute(
          '''INSERT INTO life_state
(owner_id,ai_profile_id,last_heartbeat_at,last_activity_at,activity,location,energy,mood,presence,focus)
VALUES (?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(owner_id,ai_profile_id) DO UPDATE SET
last_heartbeat_at=excluded.last_heartbeat_at,last_activity_at=excluded.last_activity_at,
activity=excluded.activity,location=excluded.location,energy=excluded.energy,
mood=excluded.mood,presence=excluded.presence,focus=excluded.focus''',
          [_ownerId, ai.value, now.toIso8601String(), now.toIso8601String(), state.activity.name,
            state.location.name, state.energy, state.mood.name, state.presence.name, state.focus],
        );
        return Ok(LifeRecord(id: id, ai: ai, kind: LifeRecordKind.activity, at: now, state: state));
      });
    } on FormatException {
      return err(FailureCode.internal, 'Invalid stored life state');
    } on ArgumentError {
      return err(FailureCode.invalidArgument, 'Invalid life state');
    }
  }

  Future<Result<List<LifeRecord>>> recentActivity(AiId ai, {int limit = 50}) async {
    if (limit < 1 || limit > 100) {
      return err(FailureCode.invalidArgument, 'limit must be between 1 and 100');
    }
    try {
      return await _db.transaction((tx) async {
        if (!await _identity(tx, ai)) return err(FailureCode.notFound, 'AI not found');
        final rows = await tx.query(
          '''SELECT * FROM activity_log
WHERE owner_id=? AND ai_profile_id=? ORDER BY at DESC,id DESC LIMIT ?''',
          [_ownerId, ai.value, limit],
        );
        return Ok(List.unmodifiable(rows.map(_record)));
      });
    } on FormatException {
      return err(FailureCode.internal, 'Invalid stored life state');
    }
  }

  Future<bool> _identity(Tx tx, AiId ai) async => (await tx.query(
    '''SELECT p.id FROM ai_profile p
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id
JOIN account owner ON owner.id=o.operator_id AND owner.kind='human' AND owner.disabled=0
WHERE p.id=? AND o.operator_id=?''',
    [ai.value, _ownerId],
  )).length == 1;

  LifeState _state(Map<String, Object?> row) => LifeState(
    activity: LifeActivity.values.byName(row['activity'] as String),
    location: LifeLocation.values.byName(row['location'] as String),
    energy: row['energy'] as int,
    mood: LifeMood.values.byName(row['mood'] as String),
    presence: LifePresence.values.byName(row['presence'] as String),
    focus: row['focus'] as int,
  );

  LifeRecord _record(Map<String, Object?> row) {
    final kind = LifeRecordKind.values.byName(row['kind'] as String);
    return LifeRecord(
      id: row['id'] as String,
      ai: AiId.parse(row['ai_profile_id'] as String),
      kind: kind,
      at: DateTime.parse(row['at'] as String),
      state: kind == LifeRecordKind.activity ? _state(row) : null,
      gapStart: kind == LifeRecordKind.gap ? DateTime.parse(row['gap_start'] as String) : null,
    );
  }

  void _validateState(LifeState state) {
    if (state.energy < 0 || state.energy > 100 || state.focus < 0 || state.focus > 100) {
      throw ArgumentError('Life state values must be between 0 and 100');
    }
  }

  String _recordId(String kind) =>
      '${kind}_${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}
