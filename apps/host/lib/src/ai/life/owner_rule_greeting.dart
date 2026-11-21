import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../../creative/creative_time.dart';
import '../../messages/sqlite_message_store.dart';
import '../../models/usage_meter.dart';
import '../../social/owner_ai_direct_consent.dart';
import '../../storage/database.dart';

/// Trusted route context; the caller's bearer, account and device are checked
/// together against current storage inside each settings transaction.
typedef GreetingCaller = ({String owner, String device, String bearer});

typedef GreetingUpdate = ({
  int expectedRevision,
  bool enabled,
  int localMinute,
  int? offsetMinutes,
  int quietStartMinute,
  int quietEndMinute,
  int? expectedChatRevision,
  int? expectedGlobalRevision,
});

typedef _Slot = ({DateTime nominal, DateTime due});
typedef _ConsumedSlot = ({
  String owner,
  AiId ai,
  int revision,
  _Slot slot,
  int observedThrough,
  int nextDueAt,
});

/// Fixed, local, owner-only greeting. It receives no inbound events, reads no
/// conversational context and performs no model work. Only the live module
/// controls polling; no settings route dispatches a message.
final class OwnerRuleGreeting {
  OwnerRuleGreeting({
    required this.database,
    required this.messages,
    required this.clock,
  });

  final Database database;
  final SqliteMessageStore messages;
  final Clock clock;
  static const pollInterval = Duration(seconds: 10);
  static const _maxObservationGap = Duration(seconds: 30);
  static const _day = Duration(days: 1);
  static const _text = '【规则问候】你好，愿你今天顺利。';

  DateTime? _lastPoll;
  DateTime? _observationStart;
  DateTime? _highWater;
  Future<int>? _running;

  /// Do not inherit an earlier host's pending delivery window on restart.
  void beginObservation() {
    final boot = clock.now().toUtc();
    _lastPoll = _observationStart = _highWater = boot;
  }

  Future<Result<Map<String, Object?>>> settings(
    GreetingCaller caller,
    AiId ai, {
    GreetingUpdate? update,
  }) => database.transaction((tx) async {
    final denied = await _callerFailure(tx, caller);
    if (denied != null) return Err(denied);
    final owner = caller.owner;
    final account = await _ownedAi(tx, owner, ai);
    if (account == null) return _hidden();
    final now = clock.now().toUtc();
    final global = await _stop(tx, owner);
    final grant = await _pair(tx, owner, ai, account);
    final level = await _level(tx, owner, ai);
    final budgetReady = await _budget(tx, owner, ai, now) != null;
    final row = await _settingsRow(tx, owner, ai);
    final delivery = await _delivery(tx, owner, account);
    final revision = row?['revision'] as int? ?? 0;
    if (update != null) {
      if (!_valid(update)) return _invalid();
      if (update.expectedRevision != revision ||
          (update.enabled &&
              (global.blocked ||
                  !budgetReady ||
                  !_eligible(level) ||
                  grant == null ||
                  update.expectedChatRevision != grant.revision ||
                  update.expectedGlobalRevision != global.revision))) {
        return _changed();
      }
      final cutoff = _later(
        _later(now, _highWater ?? now),
        _at(row?['observed_through']) ?? now,
      );
      final _Slot? next = update.enabled
          ? _nextAfter(
              cutoff,
              localMinute: update.localMinute,
              offset: update.offsetMinutes!,
              quietStart: update.quietStartMinute,
              quietEnd: update.quietEndMinute,
            )
          : null;
      await tx.execute(
        '''
INSERT INTO owner_rule_greetings
(owner_id,ai_profile_id,revision,local_minute,offset_minutes,quiet_start,quiet_end,conversation_id,chat_revision,nominal_at,due_at,observed_through)
VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(owner_id,ai_profile_id) DO UPDATE SET
revision=excluded.revision,local_minute=excluded.local_minute,offset_minutes=excluded.offset_minutes,
quiet_start=excluded.quiet_start,quiet_end=excluded.quiet_end,conversation_id=excluded.conversation_id,
chat_revision=excluded.chat_revision,nominal_at=excluded.nominal_at,due_at=excluded.due_at,
observed_through=excluded.observed_through''',
        [
          owner,
          ai.value,
          revision + 1,
          update.localMinute,
          update.offsetMinutes,
          update.quietStartMinute,
          update.quietEndMinute,
          update.enabled ? grant?.conversationId : null,
          update.enabled ? grant?.revision : null,
          next?.nominal.millisecondsSinceEpoch,
          next?.due.millisecondsSinceEpoch,
          cutoff.millisecondsSinceEpoch,
        ],
      );
      await _audit(
        tx,
        now,
        owner,
        'owner_rule_greeting.configure',
        'ai_profile',
        ai.value,
        {'revision': revision + 1, 'enabled': update.enabled},
      );
    }
    final effective = update == null ? row : await _settingsRow(tx, owner, ai);
    return Ok({
      'revision': effective?['revision'] as int? ?? 0,
      'enabled':
          !global.blocked && _eligible(level) && _matches(effective, grant),
      'localMinute': effective?['local_minute'] as int? ?? 540,
      'offsetMinutes': effective?['offset_minutes'],
      'quietStartMinute': effective?['quiet_start'] as int? ?? 1380,
      'quietEndMinute': effective?['quiet_end'] as int? ?? 480,
      'globalBlocked': global.blocked,
      'globalRevision': global.revision,
      'socialLevel': level,
      'chatRevision': grant?.revision,
      'budgetReady': budgetReady,
      'lastSentAt': _at(delivery?['last_sent_at'])?.toIso8601String(),
    });
  });

  Future<Result<Map<String, Object?>>> stopSettings(
    GreetingCaller caller, {
    ({int expectedRevision, bool blocked})? update,
  }) => database.transaction((tx) async {
    final denied = await _callerFailure(tx, caller);
    if (denied != null) return Err(denied);
    final owner = caller.owner;
    final current = await _stop(tx, owner);
    if (update == null) {
      return Ok({'revision': current.revision, 'blocked': current.blocked});
    }
    if (update.expectedRevision < 0) return _invalid();
    if (current.revision != update.expectedRevision) return _changed();
    final revision = current.revision + 1;
    await tx.execute(
      '''
INSERT INTO owner_rule_greeting_stops(owner_id,revision,blocked) VALUES(?,?,?)
ON CONFLICT(owner_id) DO UPDATE SET revision=excluded.revision,blocked=excluded.blocked''',
      [owner, revision, update.blocked ? 1 : 0],
    );
    if (update.blocked) {
      await tx.execute(
        '$_revoke WHERE owner_id=? AND chat_revision IS NOT NULL',
        [owner],
      );
    }
    await _audit(
      tx,
      clock.now().toUtc(),
      owner,
      'owner_rule_greeting.stop',
      'account',
      owner,
      {'revision': revision, 'blocked': update.blocked},
    );
    return Ok({'revision': revision, 'blocked': update.blocked});
  });

  /// Coalesce timer overlap. A missed deadline is skipped, not retried or
  /// backfilled. Each due row owns its own bounded write transaction.
  Future<int> poll() {
    final running = _running;
    if (running != null) return running;
    final next = _poll().whenComplete(() => _running = null);
    _running = next;
    return next;
  }

  Future<int> _poll() async {
    final now = clock.now().toUtc();
    final previous = _lastPoll;
    final priorHigh = _highWater ?? now;
    final high = _later(now, priorHigh);
    _highWater = high;
    _lastPoll = now;
    final forward =
        previous != null &&
        now.isAfter(previous) &&
        now.difference(previous) <= _maxObservationGap &&
        !now.isBefore(priorHigh);
    if (!forward && (previous == null || now != previous)) {
      _observationStart = high;
    }
    final since = _observationStart ?? high;
    final all = await database.query(
      '''
SELECT owner_id,ai_profile_id,revision,due_at FROM owner_rule_greetings
WHERE due_at<=? ORDER BY due_at,owner_id,ai_profile_id LIMIT 32''',
      [high.millisecondsSinceEpoch],
    );
    var sent = 0;
    for (final candidate in all) {
      try {
        final consumed = await database.transaction(
          (tx) => _consume(tx, candidate, high),
        );
        if (consumed != null &&
            forward &&
            consumed.slot.due.isAfter(previous) &&
            !consumed.slot.due.isAfter(now) &&
            consumed.slot.nominal.isAfter(since) &&
            await database.transaction((tx) => _deliver(tx, consumed, now))) {
          sent++;
        }
      } catch (_) {
        // Transaction rolls back append, receipt and audit together. No source
        // or SQL diagnostics are emitted, and the next poll cannot replay this
        // already observed slot. Other due rows can still proceed.
      }
    }
    return sent;
  }

  /// Advance the cursor durably before attempting delivery. This survives a
  /// failed delivery/audit plus a wall-clock rewind and a process restart.
  Future<_ConsumedSlot?> _consume(
    Tx tx,
    Map<String, Object?> candidate,
    DateTime high,
  ) async {
    final owner = candidate['owner_id']! as String;
    final ai = AiId.parse(candidate['ai_profile_id']! as String);
    final row = await _settingsRow(tx, owner, ai);
    if (row == null ||
        row['revision'] != candidate['revision'] ||
        row['due_at'] != candidate['due_at']) {
      return null;
    }
    final now = clock.now().toUtc();
    final offset = row['offset_minutes']! as int;
    final slot = (nominal: _at(row['nominal_at'])!, due: _at(row['due_at'])!);
    final priorCutoff = _at(row['observed_through'])!;
    final cutoff = _later(_later(now, high), priorCutoff);
    final next = _nextAfter(
      cutoff,
      localMinute: row['local_minute']! as int,
      offset: offset,
      quietStart: row['quiet_start']! as int,
      quietEnd: row['quiet_end']! as int,
    );
    final nextDueAt = next.due.millisecondsSinceEpoch;
    final observedThrough = cutoff.millisecondsSinceEpoch;
    await tx.execute(
      '''
UPDATE owner_rule_greetings SET nominal_at=?,due_at=?,observed_through=? WHERE owner_id=? AND ai_profile_id=?''',
      [
        next.nominal.millisecondsSinceEpoch,
        nextDueAt,
        observedThrough,
        owner,
        ai.value,
      ],
    );
    if (!slot.nominal.isAfter(priorCutoff) || now.isBefore(high)) return null;
    return (
      owner: owner,
      ai: ai,
      revision: row['revision']! as int,
      slot: slot,
      observedThrough: observedThrough,
      nextDueAt: nextDueAt,
    );
  }

  Future<bool> _deliver(
    Tx tx,
    _ConsumedSlot consumed,
    DateTime observed,
  ) async {
    final (:owner, :ai, :revision, :slot, :observedThrough, :nextDueAt) =
        consumed;
    final row = await _settingsRow(tx, owner, ai);
    if (row == null ||
        row['revision'] != revision ||
        row['due_at'] != nextDueAt ||
        row['observed_through'] != observedThrough) {
      return false;
    }
    final account = await _ownedAi(tx, owner, ai);
    final grant = account == null ? null : await _pair(tx, owner, ai, account);
    final global = await _stop(tx, owner);
    if (global.blocked ||
        !_eligible(await _level(tx, owner, ai)) ||
        !_matches(row, grant)) {
      return false;
    }
    final now = clock.now().toUtc();
    final quiet = _quiet(row['quiet_start']! as int, row['quiet_end']! as int);
    final zone = UserTimeZone(Duration(minutes: row['offset_minutes']! as int));
    final day = dayKey(zone.toLocalWall(now));
    if (now.isBefore(observed) ||
        now.isBefore(_at(observedThrough)!) ||
        now.difference(slot.due) > _maxObservationGap ||
        quiet.containsWall(zone.toLocalWall(now))) {
      return false;
    }
    final delivery = await _delivery(tx, owner, account!);
    final lastAt = _at(delivery?['last_sent_at']);
    final lastDay = delivery?['last_day'] as String?;
    if ((lastAt != null && now.difference(lastAt) < _day) ||
        (lastDay != null && day.compareTo(lastDay) <= 0)) {
      return false;
    }
    final budgetDay = await _budget(tx, owner, ai, now);
    if (budgetDay == null) return false;
    // A queued/slow gate check cannot push the actual append outside the
    // observed finite slot or into a different civil (or budget) day.
    final publishing = clock.now().toUtc();
    final wall = zone.toLocalWall(publishing);
    if (publishing.isBefore(now) ||
        publishing.difference(slot.due) > _maxObservationGap ||
        dayKey(wall) != day ||
        quiet.containsWall(wall) ||
        dayKey(publishing.add(Duration(minutes: budgetDay.offsetMinutes))) !=
            budgetDay.date) {
      return false;
    }
    final key = sha256
        .convert(utf8.encode(jsonEncode([owner, account, day])))
        .toString()
        .substring(0, 48);
    final appended = await messages.appendInTransaction(
      tx,
      conversationId: grant!.conversationId,
      senderId: account,
      clientMsgId: 'rg_$key',
      kind: MessageKind.text,
      body: const {'text': _text, 'source': 'owner_rule_greeting'},
    );
    if (appended.isErr || appended.value.duplicate) {
      throw const _DeliveryRollback();
    }
    final message = appended.value.message;
    final sentAt = message.sentAt;
    final sentWall = zone.toLocalWall(sentAt);
    if (sentAt.isBefore(publishing) ||
        sentAt.difference(slot.due) > _maxObservationGap ||
        dayKey(sentWall) != day ||
        quiet.containsWall(sentWall) ||
        dayKey(sentAt.add(Duration(minutes: budgetDay.offsetMinutes))) !=
            budgetDay.date) {
      throw const _DeliveryRollback();
    }
    await tx.execute(
      '''
INSERT INTO owner_rule_greeting_delivery(owner_id,ai_account_id,last_day,last_sent_at)
VALUES(?,?,?,?) ON CONFLICT(owner_id,ai_account_id) DO UPDATE SET
last_day=excluded.last_day,last_sent_at=excluded.last_sent_at''',
      [owner, account, day, sentAt.millisecondsSinceEpoch],
    );
    await _audit(
      tx,
      sentAt,
      account,
      'owner_rule_greeting.sent',
      'ai_profile',
      ai.value,
      {'messageId': message.messageId, 'day': day},
    );
    return true;
  }

  bool _eligible(String? level) => level == 'L3' || level == 'L4';

  static const _revoke = '''UPDATE owner_rule_greetings
SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL''';

  bool _matches(Map<String, Object?>? row, OwnerAiDirectGrant? grant) =>
      grant != null &&
      row?['chat_revision'] == grant.revision &&
      row?['conversation_id'] == grant.conversationId;

  Future<String?> _ownedAi(Tx tx, String owner, AiId ai) async =>
      (await tx.query(
            '''
SELECT p.account_id FROM ai_profile p
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id AND o.operator_id=?
JOIN account h ON h.id=o.operator_id AND h.kind='human' AND h.disabled=0
WHERE p.id=?''',
            [owner, ai.value],
          )).singleOrNull?['account_id']
          as String?;

  Future<OwnerAiDirectGrant?> _pair(
    Tx tx,
    String owner,
    AiId ai,
    String account,
  ) async {
    final candidate = (await tx.query(
      '''
SELECT conversation_id FROM owner_ai_direct_grants g WHERE owner_account_id=? AND ai_profile_id=?
 AND NOT EXISTS(SELECT 1 FROM social_conversations s WHERE s.id=g.conversation_id)''',
      [owner, ai.value],
    )).singleOrNull;
    if (candidate == null) return null;
    final valid = await OwnerAiDirectConsent.resolveInTx(
      tx,
      ownerAccountId: owner,
      conversationId: candidate['conversation_id']! as String,
    );
    if (valid?.aiAccountId != account || valid?.aiProfileId != ai.value) {
      return null;
    }
    return valid;
  }

  Future<String?> _level(Tx tx, String owner, AiId ai) async =>
      (await tx.query(
            'SELECT level FROM ai_social_levels WHERE owner_id=? AND ai_profile_id=?',
            [owner, ai.value],
          )).singleOrNull?['level']
          as String?;

  Future<BudgetDay?> _budget(Tx tx, String owner, AiId ai, DateTime now) =>
      UsageMeter.forOwner(
        ownerId: owner,
        db: database,
        clock: clock,
        dayForClock: (_) =>
            throw StateError('Greeting must use the persisted budget offset'),
      ).ruleGreetingDayInTx(tx, ai, now);

  Future<({bool blocked, int revision})> _stop(Tx tx, String owner) async {
    final row = (await tx.query(
      'SELECT revision,blocked FROM owner_rule_greeting_stops WHERE owner_id=?',
      [owner],
    )).singleOrNull;
    return (
      blocked: row?['blocked'] == 1,
      revision: row?['revision'] as int? ?? 0,
    );
  }

  Future<Map<String, Object?>?> _settingsRow(
    Tx tx,
    String owner,
    AiId ai,
  ) async => (await tx.query(
    'SELECT * FROM owner_rule_greetings WHERE owner_id=? AND ai_profile_id=?',
    [owner, ai.value],
  )).singleOrNull;
  Future<Map<String, Object?>?> _delivery(
    Tx tx,
    String owner,
    String aiAccount,
  ) async => (await tx.query(
    'SELECT last_sent_at,last_day FROM owner_rule_greeting_delivery WHERE owner_id=? AND ai_account_id=?',
    [owner, aiAccount],
  )).singleOrNull;

  Future<Failure?> _callerFailure(Tx tx, GreetingCaller caller) async {
    if (caller.bearer.length != 22) {
      return const Failure(FailureCode.unauthenticated, 'Invalid credentials');
    }
    final rows = await tx.query(
      '''
SELECT a.kind FROM device d JOIN refresh_token r ON r.device_id=d.id
JOIN account a ON a.id=d.account_id AND a.disabled=0
WHERE d.id=? AND d.account_id=? AND d.access_hash=? AND d.access_expires>?''',
      [
        caller.device,
        caller.owner,
        sha256.convert(utf8.encode(caller.bearer)).toString(),
        clock.now().toUtc().millisecondsSinceEpoch,
      ],
    );
    if (rows.length != 1) {
      return const Failure(FailureCode.unauthenticated, 'Invalid credentials');
    }
    return rows.single['kind'] == 'human'
        ? null
        : const Failure(FailureCode.notFound, 'No rule greeting settings');
  }

  Future<void> _audit(
    Tx tx,
    DateTime now,
    String actor,
    String action,
    String kind,
    String id,
    Map<String, Object?> meta,
  ) async {
    await tx.execute(
      'INSERT INTO audit_log (at,actor_id,action,target_kind,target_id,meta) VALUES(?,?,?,?,?,?)',
      [now.toIso8601String(), actor, action, kind, id, jsonEncode(meta)],
    );
  }
}

bool _valid(GreetingUpdate update) {
  bool minute(int value) => value >= 0 && value < 1440;
  final offset = update.offsetMinutes;
  return update.expectedRevision >= 0 &&
      minute(update.localMinute) &&
      minute(update.quietStartMinute) &&
      minute(update.quietEndMinute) &&
      update.quietStartMinute != update.quietEndMinute &&
      (offset == null || (offset >= -840 && offset <= 840)) &&
      (update.enabled
          ? offset != null &&
                (update.expectedChatRevision ?? -1) >= 0 &&
                (update.expectedGlobalRevision ?? -1) >= 0
          : update.expectedChatRevision == null &&
                update.expectedGlobalRevision == null);
}

DateTime? _at(Object? ms) =>
    ms is int ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true) : null;
DateTime _later(DateTime a, DateTime b) => a.isAfter(b) ? a : b;
SilentWindow _quiet(int start, int end) => SilentWindow(
  start: LocalTime(start ~/ 60, start % 60),
  end: LocalTime(end ~/ 60, end % 60),
);

_Slot _nextAfter(
  DateTime cutoff, {
  required int localMinute,
  required int offset,
  required int quietStart,
  required int quietEnd,
}) {
  final zone = UserTimeZone(Duration(minutes: offset));
  final wall = zone.toLocalWall(cutoff);
  var nominal = DateTime.utc(
    wall.year,
    wall.month,
    wall.day,
  ).add(Duration(minutes: localMinute));
  if (!nominal.isAfter(wall)) nominal = nominal.add(OwnerRuleGreeting._day);
  return (
    nominal: zone.toInstant(nominal),
    due: zone.toInstant(_quiet(quietStart, quietEnd).deferToEnd(nominal)),
  );
}

Result<Map<String, Object?>> _hidden() =>
    err(FailureCode.notFound, 'AI not found');
Result<Map<String, Object?>> _changed() =>
    err(FailureCode.conflict, 'Rule greeting consent or eligibility changed');
Result<Map<String, Object?>> _invalid() =>
    err(FailureCode.invalidArgument, 'Invalid rule greeting settings');

final class _DeliveryRollback implements Exception {
  const _DeliveryRollback();
}
