import 'package:jingyu_core/jingyu_core.dart';

import '../models/usage_meter.dart';
import '../storage/database.dart';

class GroupAiSettings {
  const GroupAiSettings({
    required this.dailyCap,
    this.minInterval = const Duration(seconds: 30),
    this.maxPerRound = 1,
    this.autonomousInterjection = false,
    this.interjectionGap = const Duration(minutes: 10),
    this.hosting = false,
  });

  final Duration minInterval;
  final int maxPerRound;
  final int dailyCap;
  final bool autonomousInterjection;
  final Duration interjectionGap;
  final bool hosting;
}

class GroupAiPolicy {
  GroupAiPolicy({
    required AccountId actorId,
    required Database database,
    required Clock clock,
    required BudgetDay Function(Clock) budgetDay,
  }) : _actor = actorId.value,
       _db = database,
       _clock = clock,
       _budgetDay = budgetDay;

  /// Configures group AI policy without granting posting admission.
  GroupAiPolicy.configuration({
    required AccountId actorId,
    required Database database,
    required Clock clock,
  }) : _actor = actorId.value,
       _db = database,
       _clock = clock,
       _budgetDay = null;

  final String _actor;
  final Database _db;
  final Clock _clock;
  final BudgetDay Function(Clock)? _budgetDay;
  static const _defaultIntervalMs = 30000;

  Result<void> _invalid() => err(FailureCode.invalidArgument, 'Invalid input');
  Result<void> _forbidden() => err(FailureCode.forbidden, 'Not authorized');
  Result<void> _notFound() => err(FailureCode.notFound, 'Not found');
  Result<void> _limited(String message) =>
      err(FailureCode.rateLimited, message);

  bool _validId(String value) {
    try {
      validateId(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  bool _validSettings(GroupAiSettings s) =>
      s.minInterval >= Duration.zero &&
      s.maxPerRound >= 1 &&
      s.dailyCap >= 0 &&
      s.interjectionGap >= Duration.zero;

  Future<bool> _member(Tx tx, String groupId, String accountId) async =>
      (await tx.query(
        'SELECT 1 FROM social_members WHERE conversation_id=? AND account_id=?',
        [groupId, accountId],
      )).isNotEmpty;

  Future<bool> _groupExists(Tx tx, String groupId) async => (await tx.query(
    'SELECT 1 FROM social_conversations WHERE id=?',
    [groupId],
  )).isNotEmpty;

  Future<bool> _groupOwner(Tx tx, String groupId) async =>
      (await tx.query(
        '''SELECT 1 FROM social_conversations c JOIN account a ON a.id=c.owner_account_id
        WHERE c.id=? AND c.owner_account_id=? AND a.disabled=0''',
        [groupId, _actor],
      )).isNotEmpty &&
      await _member(tx, groupId, _actor);

  Future<bool> _canonicalAi(Tx tx, String aiId) async => (await tx.query(
    '''SELECT 1 FROM account a JOIN ai_operator o ON o.ai_id=a.id
        JOIN account h ON h.id=o.operator_id WHERE a.id=? AND a.kind='ai' AND a.disabled=0
        AND h.kind='human' AND h.disabled=0 AND o.operator_id=?''',
    [aiId, _actor],
  )).isNotEmpty;

  Future<bool> _activeCanonicalAi(Tx tx, String aiId) async => (await tx.query(
    '''SELECT 1 FROM account a JOIN ai_operator o ON o.ai_id=a.id
        JOIN account h ON h.id=o.operator_id WHERE a.id=? AND a.kind='ai' AND a.disabled=0
        AND h.kind='human' AND h.disabled=0''',
    [aiId],
  )).isNotEmpty;

  GroupAiSettings _readSettings(Map<String, Object?> r) => GroupAiSettings(
    minInterval: Duration(milliseconds: r['min_interval_ms'] as int),
    maxPerRound: r['max_per_round'] as int,
    dailyCap: r['daily_cap'] as int,
    autonomousInterjection: r['autonomous_interjection'] == 1,
    interjectionGap: Duration(milliseconds: r['interjection_gap_ms'] as int),
    hosting: r['hosting'] == 1,
  );

  Future<Result<GroupAiSettings>> getSettings(ConversationId group) =>
      _db.transaction((tx) async {
        if (!_validId(group.value) ||
            !await _groupExists(tx, group.value) ||
            !await _member(tx, group.value, _actor)) {
          return err(FailureCode.notFound, 'Not found');
        }
        final actor = await tx.query(
          'SELECT kind FROM account WHERE id=? AND disabled=0',
          [_actor],
        );
        if (actor.isEmpty ||
            (actor.single['kind'] == 'ai' &&
                !await _activeCanonicalAi(tx, _actor))) {
          return err(FailureCode.notFound, 'Not found');
        }
        final rows = await tx.query(
          'SELECT * FROM group_ai_settings WHERE group_id=?',
          [group.value],
        );
        if (rows.isEmpty) return err(FailureCode.notFound, 'Not configured');
        return Ok(_readSettings(rows.single));
      });

  /// Group owner controls shared cap, round limit, hosting, and autonomous mode.
  /// AI-owner interval overrides are stored separately and preserved.
  Future<Result<void>> updateSettings(
    ConversationId group,
    GroupAiSettings settings,
  ) => _db.transaction((tx) async {
    // Group-owner updates cannot change the AI-owner interval field.
    if (!_validId(group.value) ||
        !_validSettings(settings) ||
        settings.minInterval != const Duration(seconds: 30)) {
      return _invalid();
    }
    if (!await _groupOwner(tx, group.value)) return _forbidden();
    final old = await tx.query(
      'SELECT min_interval_ms,hosting FROM group_ai_settings WHERE group_id=?',
      [group.value],
    );
    final interval = old.isEmpty
        ? _defaultIntervalMs
        : old.single['min_interval_ms'] as int;
    final turnedOff =
        old.isNotEmpty && old.single['hosting'] == 1 && !settings.hosting;
    final autonomous =
        settings.hosting || (!turnedOff && settings.autonomousInterjection);
    await tx.execute(
      '''INSERT INTO group_ai_settings
      (group_id,min_interval_ms,max_per_round,daily_cap,autonomous_interjection,interjection_gap_ms,hosting,updated_at)
      VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(group_id) DO UPDATE SET max_per_round=excluded.max_per_round,
      daily_cap=excluded.daily_cap,autonomous_interjection=excluded.autonomous_interjection,
      interjection_gap_ms=excluded.interjection_gap_ms,hosting=excluded.hosting,updated_at=excluded.updated_at''',
      [
        group.value,
        interval,
        settings.maxPerRound,
        settings.dailyCap,
        autonomous ? 1 : 0,
        settings.interjectionGap.inMilliseconds,
        settings.hosting ? 1 : 0,
        _clock.now().toUtc().millisecondsSinceEpoch,
      ],
    );
    return const Ok(null);
  });

  Future<Result<void>> updateMinInterval(
    AccountId ai,
    ConversationId group,
    Duration interval,
  ) => _db.transaction((tx) async {
    if (!_validId(ai.value) ||
        !_validId(group.value) ||
        interval < Duration.zero) {
      return _invalid();
    }
    if (!await _canonicalAi(tx, ai.value) ||
        !await _member(tx, group.value, ai.value)) {
      return _forbidden();
    }
    if ((await tx.query('SELECT 1 FROM group_ai_settings WHERE group_id=?', [
      group.value,
    ])).isEmpty) {
      return _notFound();
    }
    await tx.execute(
      '''INSERT INTO group_ai_intervals(group_id,ai_id,min_interval_ms) VALUES (?,?,?)
      ON CONFLICT(group_id,ai_id) DO UPDATE SET min_interval_ms=excluded.min_interval_ms''',
      [group.value, ai.value, interval.inMilliseconds],
    );
    return const Ok(null);
  });

  Future<Result<void>> setMuted(
    AccountId ai,
    ConversationId group, {
    required bool muted,
  }) => _db.transaction((tx) async {
    if (!_validId(ai.value) || !_validId(group.value)) return _invalid();
    if (!await _groupOwner(tx, group.value)) return _forbidden();
    if (!await _activeCanonicalAi(tx, ai.value) ||
        !await _member(tx, group.value, ai.value)) {
      return _notFound();
    }
    await tx.execute(
      '''INSERT INTO group_ai_mutes(group_id,ai_id,muted) VALUES (?,?,?)
      ON CONFLICT(group_id,ai_id) DO UPDATE SET muted=excluded.muted''',
      [group.value, ai.value, muted ? 1 : 0],
    );
    return const Ok(null);
  });

  Future<Result<void>> mayPost(
    ConversationId group, {
    required String roundId,
    required bool mentioned,
  }) async {
    final budgetDay = _budgetDay;
    if (budgetDay == null) return _invalid();
    return _db.transaction((tx) async {
      final now = _clock.now().toUtc();
      return _gate(
        tx,
        group.value,
        roundId: roundId,
        mentioned: mentioned,
        now: now,
        day: budgetDay(_SnapshotClock(now)),
      );
    });
  }

  Future<Result<void>> _gate(
    Tx tx,
    String groupId, {
    required String roundId,
    required bool mentioned,
    required DateTime now,
    required BudgetDay day,
  }) async {
    if (!_validId(groupId) || roundId.trim().isEmpty || roundId.length > 128) {
      return _invalid();
    }
    if (!await _groupExists(tx, groupId)) {
      return _notFound();
    }
    if (!await _activeCanonicalAi(tx, _actor) ||
        !await _member(tx, groupId, _actor)) {
      return _notFound();
    }
    final rows = await tx.query(
      'SELECT * FROM group_ai_settings WHERE group_id=?',
      [groupId],
    );
    if (rows.isEmpty) return _forbidden();
    final s = _readSettings(rows.single);
    final mute = await tx.query(
      'SELECT muted FROM group_ai_mutes WHERE group_id=? AND ai_id=?',
      [groupId, _actor],
    );
    if (mute.isNotEmpty && mute.single['muted'] == 1) return _forbidden();
    if (!mentioned && !s.autonomousInterjection) return _forbidden();
    final daily = await tx.query(
      'SELECT COUNT(*) AS n FROM group_ai_admissions WHERE group_id=? AND budget_day=?',
      [groupId, day.date],
    );
    if ((daily.single['n'] as int) >= s.dailyCap) {
      return _limited('Daily cap reached');
    }
    final rounds = await tx.query(
      'SELECT COUNT(*) AS n FROM group_ai_admissions WHERE group_id=? AND ai_id=? AND round_id=?',
      [groupId, _actor, roundId],
    );
    if ((rounds.single['n'] as int) >= s.maxPerRound) {
      return _limited('Round cap reached');
    }
    final lastRows = await tx.query(
      'SELECT MAX(posted_at) AS at FROM group_ai_admissions WHERE group_id=? AND ai_id=?',
      [groupId, _actor],
    );
    final override = await tx.query(
      'SELECT min_interval_ms FROM group_ai_intervals WHERE group_id=? AND ai_id=?',
      [groupId, _actor],
    );
    final interval = override.isEmpty
        ? s.minInterval.inMilliseconds
        : override.single['min_interval_ms'] as int;
    final nowMs = now.millisecondsSinceEpoch;
    final last = lastRows.single['at'] as int?;
    if (last != null && nowMs - last < interval) {
      return _limited('Minimum interval');
    }
    if (!mentioned) {
      final gapRows = await tx.query(
        'SELECT MAX(posted_at) AS at FROM group_ai_admissions WHERE group_id=? AND mentioned=0',
        [groupId],
      );
      final lastGap = gapRows.single['at'] as int?;
      if (lastGap != null &&
          nowMs - lastGap < s.interjectionGap.inMilliseconds) {
        return _limited('Interjection gap');
      }
    }
    return const Ok(null);
  }

  /// Atomically rechecks policy and consumes a slot. This is admission only;
  /// it does not promise a subsequent message write will commit.
  Future<Result<void>> tryConsumePost(
    ConversationId group, {
    required String roundId,
    required bool mentioned,
  }) async {
    final budgetDay = _budgetDay;
    if (budgetDay == null) return _invalid();
    return _db.transaction((tx) async {
      final now = _clock.now().toUtc();
      final day = budgetDay(_SnapshotClock(now));
      final gate = await _gate(
        tx,
        group.value,
        roundId: roundId,
        mentioned: mentioned,
        now: now,
        day: day,
      );
      if (gate.isErr) return gate;
      await tx.execute(
        '''INSERT INTO group_ai_admissions(group_id,ai_id,round_id,mentioned,posted_at,budget_day,offset_minutes)
        VALUES (?,?,?,?,?,?,?)''',
        [
          group.value,
          _actor,
          roundId,
          mentioned ? 1 : 0,
          now.millisecondsSinceEpoch,
          day.date,
          day.offsetMinutes,
        ],
      );
      return const Ok(null);
    });
  }
}

class _SnapshotClock extends Clock {
  const _SnapshotClock(this._moment);
  final DateTime _moment;
  @override
  DateTime now() => _moment;
}
