/// 1v1 通话状态机（M08，FR-32、AC-13）。
///
/// 覆盖三条硬约束：
/// * `call_id` 幂等：同一 id 重复发起不产生第二通；
/// * 30s 未接转未接来电；
/// * 打断边界：取消 LLM、清 TTS 队列、停播，被截断的话标「中途被打断」，
///   不写成完整发言。
///
/// 原始音视频不落盘；这里只维护状态与运行时句柄。
library;

import 'package:jingyu_core/jingyu_core.dart';

/// 通话状态。
enum CallState {
  /// 响铃中（未接）。
  ringing,

  /// 已接通。
  active,

  /// 30s 未接，转未接来电。
  missed,

  /// 正常结束。
  ended,
}

/// 一通通话的对外快照。
class CallSession {
  const CallSession({
    required this.callId,
    required this.aiId,
    required this.peerAccountId,
    required this.state,
    required this.startedAt,
    this.answeredAt,
    this.endedAt,
  });

  final String callId;
  final AiId aiId;
  final String peerAccountId;
  final CallState state;
  final DateTime startedAt;
  final DateTime? answeredAt;
  final DateTime? endedAt;

  CallSession copyWith({
    CallState? state,
    DateTime? answeredAt,
    DateTime? endedAt,
  }) => CallSession(
    callId: callId,
    aiId: aiId,
    peerAccountId: peerAccountId,
    state: state ?? this.state,
    startedAt: startedAt,
    answeredAt: answeredAt ?? this.answeredAt,
    endedAt: endedAt ?? this.endedAt,
  );

  Map<String, Object?> toJson() => {
    'callId': callId,
    'aiId': aiId.value,
    'peerAccountId': peerAccountId,
    'state': state.name,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (answeredAt != null) 'answeredAt': answeredAt!.toUtc().toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
  };
}

/// 被截断的一句话。`interrupted=true` 时不得计入完整发言。
class CallUtterance {
  const CallUtterance({
    required this.text,
    required this.interrupted,
    this.marker,
  });

  final String text;
  final bool interrupted;
  final String? marker;

  bool get complete => !interrupted;

  Map<String, Object?> toJson() => {
    'text': text,
    'interrupted': interrupted,
    if (marker != null) 'marker': marker,
  };
}

/// 打断结果：三项清理是否都完成 + 是否发生截断。
class InterruptionOutcome {
  const InterruptionOutcome({
    required this.llmCancelled,
    required this.ttsQueueEmpty,
    required this.playbackStopped,
    required this.truncated,
    required this.marker,
  });

  final bool llmCancelled;
  final bool ttsQueueEmpty;
  final bool playbackStopped;
  final bool truncated;
  final String marker;

  bool get clean => llmCancelled && ttsQueueEmpty && playbackStopped;

  Map<String, Object?> toJson() => {
    'llmCancelled': llmCancelled,
    'ttsQueueEmpty': ttsQueueEmpty,
    'playbackStopped': playbackStopped,
    'truncated': truncated,
    'marker': marker,
  };
}

/// 通话服务接口，登记到 [HostServices]。
abstract interface class CallService {
  /// 发起通话。`callId` 幂等：重复发起返回同一通话。
  Future<Result<CallSession>> start({
    required String callId,
    required AiId ai,
    required String peerAccountId,
  });

  Future<Result<CallSession>> answer({required String callId});

  Future<Result<CallSession>> end({required String callId});

  Future<Result<CallSession>> get({required String callId});

  /// 只读列表：按 startedAt 倒序，可按账号/状态过滤、按 startedAt 游标分页。
  ///
  /// [accountId] 限定为该账号发起（peer）的通话——路由创建时把发起账号写入
  /// `peer_account_id`，因此这是 owner 范围的真实过滤，且分页在过滤之后进行。
  /// 只返回会话状态元数据（无音频/转写）。
  Future<Result<List<CallSession>>> list({
    String? accountId,
    CallState? status,
    DateTime? before,
    int limit = 50,
  });

  /// 打断当前发言：取消 LLM、清 TTS 队列、停播，并标记被截断的话。
  Future<Result<InterruptionOutcome>> interrupt({required String callId});

  /// 把超时未接的响铃通话转为未接来电，返回本次转未接的 call_id 列表。
  Future<Result<List<String>>> sweepMissed();
}

/// 通话运行时驱动：仅供测试与宿主侧模拟打断边界（AC-13）。
///
/// 内存与 SQLite 实现都实现它，使「打断清理」契约可以被复用；
/// 它不影响对外 [CallService] 的持久化语义。
abstract interface class CallRuntimeDriver {
  void beginAssistantTurn(String callId, String text);
  void enqueueTts(String callId, String segment);
  void beginPlayback(String callId);
  List<String> ttsQueueOf(String callId);
  bool isPlaying(String callId);
  bool isLlmCancelled(String callId);
  List<CallUtterance> utterancesOf(String callId);
}

class _Runtime {
  _Runtime(this.session);

  CallSession session;
  bool llmCancelled = false;
  final List<String> ttsQueue = <String>[];
  bool playing = false;
  String? partialText;
  final List<CallUtterance> utterances = <CallUtterance>[];
}

/// 内存实现。
class InMemoryCallService implements CallService, CallRuntimeDriver {
  InMemoryCallService({
    Clock clock = const SystemClock(),
    this.ringTimeout = const Duration(seconds: 30),
  }) : _clock = clock;

  final Clock _clock;

  /// 响铃多久转未接，默认 30s。
  final Duration ringTimeout;

  final Map<String, _Runtime> _calls = <String, _Runtime>{};

  /// 实际创建的通话数，用于断言 call_id 幂等。
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
    final existing = _calls[callId];
    if (existing != null) {
      if (existing.session.aiId != ai ||
          existing.session.peerAccountId != peerAccountId) {
        return err<CallSession>(FailureCode.conflict, 'call_id 已用于另一通话');
      }
      return Ok<CallSession>(existing.session);
    }
    final session = CallSession(
      callId: callId,
      aiId: ai,
      peerAccountId: peerAccountId,
      state: CallState.ringing,
      startedAt: _clock.now(),
    );
    _calls[callId] = _Runtime(session);
    createdCount++;
    return Ok<CallSession>(session);
  }

  @override
  Future<Result<CallSession>> answer({required String callId}) async {
    final runtime = _calls[callId];
    if (runtime == null) {
      return err<CallSession>(FailureCode.notFound, '通话不存在');
    }
    switch (runtime.session.state) {
      case CallState.ringing:
        final now = _clock.now();
        // 接听时直接执行响铃期限，不等待下一次 sweepMissed。
        if (now.difference(runtime.session.startedAt) >= ringTimeout) {
          runtime.session = runtime.session.copyWith(
            state: CallState.missed,
            endedAt: now,
          );
          return err<CallSession>(FailureCode.conflict, '通话已结束');
        }
        runtime.session = runtime.session.copyWith(
          state: CallState.active,
          answeredAt: now,
        );
        return Ok<CallSession>(runtime.session);
      case CallState.active:
        return Ok<CallSession>(runtime.session);
      case CallState.missed:
      case CallState.ended:
        return err<CallSession>(FailureCode.conflict, '通话已结束');
    }
  }

  @override
  Future<Result<CallSession>> end({required String callId}) async {
    final runtime = _calls[callId];
    if (runtime == null) {
      return err<CallSession>(FailureCode.notFound, '通话不存在');
    }
    if (runtime.session.state == CallState.ended) {
      return Ok<CallSession>(runtime.session);
    }
    runtime.session = runtime.session.copyWith(
      state: CallState.ended,
      endedAt: _clock.now(),
    );
    return Ok<CallSession>(runtime.session);
  }

  @override
  Future<Result<CallSession>> get({required String callId}) async {
    final runtime = _calls[callId];
    if (runtime == null) {
      return err<CallSession>(FailureCode.notFound, '通话不存在');
    }
    return Ok<CallSession>(runtime.session);
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
    final beforeUtc = before?.toUtc();
    final sessions =
        _calls.values
            .map((runtime) => runtime.session)
            .where(
              (session) =>
                  accountId == null || session.peerAccountId == accountId,
            )
            .where((session) => status == null || session.state == status)
            .where(
              (session) =>
                  beforeUtc == null ||
                  session.startedAt.toUtc().isBefore(beforeUtc),
            )
            .toList()
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return Ok<List<CallSession>>(
      List<CallSession>.unmodifiable(sessions.take(limit)),
    );
  }

  @override
  Future<Result<InterruptionOutcome>> interrupt({
    required String callId,
  }) async {
    final runtime = _calls[callId];
    if (runtime == null) {
      return err<InterruptionOutcome>(FailureCode.notFound, '通话不存在');
    }
    if (runtime.session.state != CallState.active) {
      return err<InterruptionOutcome>(FailureCode.conflict, '通话未在进行');
    }
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
  Future<Result<List<String>>> sweepMissed() async {
    final now = _clock.now();
    final missed = <String>[];
    for (final runtime in _calls.values) {
      if (runtime.session.state != CallState.ringing) continue;
      if (now.difference(runtime.session.startedAt) >= ringTimeout) {
        runtime.session = runtime.session.copyWith(
          state: CallState.missed,
          endedAt: now,
        );
        missed.add(runtime.session.callId);
      }
    }
    return Ok<List<String>>(List<String>.unmodifiable(missed));
  }

  // ---- 测试/宿主侧模拟辅助（属于 [CallRuntimeDriver]） ----

  /// 开始一轮 AI 发言：重置 LLM 取消位，记录尚未说完的部分。
  @override
  void beginAssistantTurn(String callId, String text) {
    final runtime = _calls[callId]!;
    runtime.llmCancelled = false;
    runtime.partialText = text;
    runtime.ttsQueue.clear();
    runtime.playing = false;
  }

  /// 追加一段待播放的 TTS 音频。
  @override
  void enqueueTts(String callId, String segment) {
    _calls[callId]!.ttsQueue.add(segment);
  }

  /// 开始播放。
  @override
  void beginPlayback(String callId) {
    _calls[callId]!.playing = true;
  }

  @override
  List<String> ttsQueueOf(String callId) =>
      List<String>.unmodifiable(_calls[callId]?.ttsQueue ?? const <String>[]);

  @override
  bool isPlaying(String callId) => _calls[callId]?.playing ?? false;

  @override
  bool isLlmCancelled(String callId) => _calls[callId]?.llmCancelled ?? false;

  @override
  List<CallUtterance> utterancesOf(String callId) =>
      List<CallUtterance>.unmodifiable(
        _calls[callId]?.utterances ?? const <CallUtterance>[],
      );
}
