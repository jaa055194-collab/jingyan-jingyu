/// CallService 的 SQLite 持久化实现（M08，FR-32、AC-13）。
///
/// 持久化的是会话状态（call_id/ai/peer/state/时间戳）；TTS 队列、播放与
/// LLM 取消位属于进程内运行时，不落库。表结构见 [voiceCallMigrations]。
library;

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'calls.dart';

class _Runtime {
  bool llmCancelled = false;
  final List<String> ttsQueue = <String>[];
  bool playing = false;
  String? partialText;
  final List<CallUtterance> utterances = <CallUtterance>[];
}

/// SQLite 版通话服务。
class SqliteCallService implements CallService, CallRuntimeDriver {
  SqliteCallService({
    required this.database,
    required this.clock,
    this.ringTimeout = const Duration(seconds: 30),
  });

  final Database database;
  final Clock clock;
  final Duration ringTimeout;
  final Map<String, _Runtime> _runtime = <String, _Runtime>{};

  /// 实际新建的通话数（call_id 幂等时不再增加）。
  int createdCount = 0;

  @override
  Future<Result<CallSession>> start({
    required String callId,
    required AiId ai,
    required String peerAccountId,
  }) async {
    try {
      validateId(callId, kind: 'call');
    } on FormatException {
      return err<CallSession>(FailureCode.invalidArgument, 'call_id 非法');
    }
    return database.transaction((tx) async {
      final rows = await tx.query('SELECT * FROM voice_calls WHERE call_id=?', [
        callId,
      ]);
      if (rows.isNotEmpty) {
        final existing = _sessionFromRow(rows.single);
        if (existing.aiId != ai || existing.peerAccountId != peerAccountId) {
          return err<CallSession>(FailureCode.conflict, 'call_id 已用于另一通话');
        }
        return Ok<CallSession>(existing);
      }
      final now = clock.now().toUtc();
      await tx.execute(
        'INSERT INTO voice_calls(call_id,ai_id,peer_account_id,state,started_at) VALUES(?,?,?,?,?)',
        [
          callId,
          ai.value,
          peerAccountId,
          CallState.ringing.name,
          now.toIso8601String(),
        ],
      );
      createdCount++;
      return Ok<CallSession>(
        CallSession(
          callId: callId,
          aiId: ai,
          peerAccountId: peerAccountId,
          state: CallState.ringing,
          startedAt: now,
        ),
      );
    });
  }

  @override
  Future<Result<CallSession>> answer({required String callId}) =>
      database.transaction((tx) async {
        final rows = await tx.query(
          'SELECT * FROM voice_calls WHERE call_id=?',
          [callId],
        );
        if (rows.isEmpty) {
          return err<CallSession>(FailureCode.notFound, '通话不存在');
        }
        final session = _sessionFromRow(rows.single);
        switch (session.state) {
          case CallState.ringing:
            final now = clock.now().toUtc();
            await tx.execute(
              'UPDATE voice_calls SET state=?,answered_at=? WHERE call_id=?',
              [CallState.active.name, now.toIso8601String(), callId],
            );
            return Ok<CallSession>(
              session.copyWith(state: CallState.active, answeredAt: now),
            );
          case CallState.active:
            return Ok<CallSession>(session);
          case CallState.missed:
          case CallState.ended:
            return err<CallSession>(FailureCode.conflict, '通话已结束');
        }
      });

  @override
  Future<Result<CallSession>> end({required String callId}) =>
      database.transaction((tx) async {
        final rows = await tx.query(
          'SELECT * FROM voice_calls WHERE call_id=?',
          [callId],
        );
        if (rows.isEmpty) {
          return err<CallSession>(FailureCode.notFound, '通话不存在');
        }
        final session = _sessionFromRow(rows.single);
        if (session.state == CallState.ended) {
          return Ok<CallSession>(session);
        }
        final now = clock.now().toUtc();
        await tx.execute(
          'UPDATE voice_calls SET state=?,ended_at=? WHERE call_id=?',
          [CallState.ended.name, now.toIso8601String(), callId],
        );
        return Ok<CallSession>(
          session.copyWith(state: CallState.ended, endedAt: now),
        );
      });

  @override
  Future<Result<CallSession>> get({required String callId}) async {
    final rows = await database.query(
      'SELECT * FROM voice_calls WHERE call_id=?',
      [callId],
    );
    if (rows.isEmpty) {
      return err<CallSession>(FailureCode.notFound, '通话不存在');
    }
    return Ok<CallSession>(_sessionFromRow(rows.single));
  }

  @override
  Future<Result<List<CallSession>>> list({
    String? accountId,
    CallState? status,
    DateTime? before,
    int limit = 50,
  }) async {
    if (limit < 1 || limit > 100) {
      return err<List<CallSession>>(FailureCode.invalidArgument, 'limit 非法');
    }
    final conditions = <String>[];
    final args = <Object?>[];
    if (accountId != null) {
      conditions.add('peer_account_id=?');
      args.add(accountId);
    }
    if (status != null) {
      conditions.add('state=?');
      args.add(status.name);
    }
    if (before != null) {
      conditions.add('started_at<?');
      args.add(before.toUtc().toIso8601String());
    }
    final where = conditions.isEmpty
        ? ''
        : ' WHERE ${conditions.join(' AND ')}';
    final rows = await database.query(
      'SELECT * FROM voice_calls$where ORDER BY started_at DESC LIMIT ?',
      [...args, limit],
    );
    return Ok<List<CallSession>>(
      List<CallSession>.unmodifiable([
        for (final row in rows) _sessionFromRow(row),
      ]),
    );
  }

  @override
  Future<Result<InterruptionOutcome>> interrupt({
    required String callId,
  }) async {
    final rows = await database.query(
      'SELECT * FROM voice_calls WHERE call_id=?',
      [callId],
    );
    if (rows.isEmpty) {
      return err<InterruptionOutcome>(FailureCode.notFound, '通话不存在');
    }
    if (_sessionFromRow(rows.single).state != CallState.active) {
      return err<InterruptionOutcome>(FailureCode.conflict, '通话未在进行');
    }
    final runtime = _runtimeFor(callId);
    runtime.llmCancelled = true;
    runtime.ttsQueue.clear();
    runtime.playing = false;
    final partial = runtime.partialText;
    final truncated = partial != null && partial.isNotEmpty;
    if (truncated) {
      runtime.utterances.add(
        CallUtterance(text: partial, interrupted: true, marker: '中途被打断'),
      );
      runtime.partialText = null;
    }
    return Ok<InterruptionOutcome>(
      InterruptionOutcome(
        llmCancelled: true,
        ttsQueueEmpty: runtime.ttsQueue.isEmpty,
        playbackStopped: !runtime.playing,
        truncated: truncated,
        marker: '中途被打断',
      ),
    );
  }

  @override
  Future<Result<List<String>>> sweepMissed() =>
      database.transaction((tx) async {
        final rows = await tx.query(
          'SELECT call_id,started_at FROM voice_calls WHERE state=?',
          [CallState.ringing.name],
        );
        final now = clock.now().toUtc();
        final missed = <String>[];
        for (final row in rows) {
          final started = DateTime.parse(row['started_at']! as String);
          if (now.difference(started) >= ringTimeout) {
            final callId = row['call_id']! as String;
            await tx.execute(
              'UPDATE voice_calls SET state=?,ended_at=? WHERE call_id=?',
              [CallState.missed.name, now.toIso8601String(), callId],
            );
            missed.add(callId);
          }
        }
        return Ok<List<String>>(List<String>.unmodifiable(missed));
      });

  // ---- CallRuntimeDriver ----

  @override
  void beginAssistantTurn(String callId, String text) {
    final runtime = _runtimeFor(callId);
    runtime.llmCancelled = false;
    runtime.partialText = text;
    runtime.ttsQueue.clear();
    runtime.playing = false;
  }

  @override
  void enqueueTts(String callId, String segment) {
    _runtimeFor(callId).ttsQueue.add(segment);
  }

  @override
  void beginPlayback(String callId) {
    _runtimeFor(callId).playing = true;
  }

  @override
  List<String> ttsQueueOf(String callId) =>
      List<String>.unmodifiable(_runtimeFor(callId).ttsQueue);

  @override
  bool isPlaying(String callId) => _runtimeFor(callId).playing;

  @override
  bool isLlmCancelled(String callId) => _runtimeFor(callId).llmCancelled;

  @override
  List<CallUtterance> utterancesOf(String callId) =>
      List<CallUtterance>.unmodifiable(_runtimeFor(callId).utterances);

  _Runtime _runtimeFor(String callId) =>
      _runtime.putIfAbsent(callId, _Runtime.new);

  CallSession _sessionFromRow(Map<String, Object?> row) {
    final stateName = row['state']! as String;
    var state = CallState.ended;
    for (final candidate in CallState.values) {
      if (candidate.name == stateName) {
        state = candidate;
        break;
      }
    }
    final answeredAt = row['answered_at'];
    final endedAt = row['ended_at'];
    return CallSession(
      callId: row['call_id']! as String,
      aiId: AiId.parse(row['ai_id']! as String),
      peerAccountId: row['peer_account_id']! as String,
      state: state,
      startedAt: DateTime.parse(row['started_at']! as String),
      answeredAt: answeredAt is String ? DateTime.parse(answeredAt) : null,
      endedAt: endedAt is String ? DateTime.parse(endedAt) : null,
    );
  }
}
