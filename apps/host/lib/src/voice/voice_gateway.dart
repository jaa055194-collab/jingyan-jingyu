/// TTS/ASR 统一入口（M08，FR-30/31、NFR-06、AC-11/13）。
///
/// 客户端永不接触厂商 key：试听与合成都走宿主网关，客户端只拿 5 分钟有效的
/// 会话票据。厂商故障/限流只降文字，**绝不换音色、不跨厂商**。
library;

import 'package:jingyu_core/jingyu_core.dart';

import 'voice_profiles.dart';

/// 合成出的音频引用。原始音频不落盘，仅返回可播放句柄。
class SpeechArtifact {
  const SpeechArtifact({required this.ref, required this.duration});

  final String ref;
  final Duration duration;

  Map<String, Object?> toJson() => {
        'ref': ref,
        'durationMs': duration.inMilliseconds,
      };
}

/// 厂商 TTS 适配器。真实厂商接入不在本切片范围，用可控假适配器测试。
abstract interface class TtsAdapter {
  /// 厂商凭据；客户端票据绝不能包含它。
  String get vendorKey;

  Future<Result<SpeechArtifact>> synthesize({
    required String provider,
    required String model,
    required String voiceId,
    required String text,
    required Map<String, Object?> params,
  });
}

/// 转写结果。
class Transcript {
  const Transcript({required this.text, this.confidence});

  final String text;
  final double? confidence;

  Map<String, Object?> toJson() => {
        'text': text,
        if (confidence != null) 'confidence': confidence,
      };
}

/// 厂商 ASR 适配器。
abstract interface class AsrAdapter {
  Future<Result<Transcript>> transcribe({required List<int> audio});
}

/// 可控 TTS 假适配器：测试通过 [available] 模拟厂商故障。
class FakeTtsAdapter implements TtsAdapter {
  FakeTtsAdapter({this.available = true, this.vendorKey = 'vendor-secret'});

  /// false 时模拟厂商故障/限流。
  bool available;

  @override
  final String vendorKey;

  int calls = 0;

  /// 每次合成请求的实际参数，用于断言 voice_id 从未改变。
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  @override
  Future<Result<SpeechArtifact>> synthesize({
    required String provider,
    required String model,
    required String voiceId,
    required String text,
    required Map<String, Object?> params,
  }) async {
    calls++;
    requests.add(<String, Object?>{
      'provider': provider,
      'model': model,
      'voiceId': voiceId,
      'text': text,
      'params': params,
    });
    if (!available) {
      return err<SpeechArtifact>(
        FailureCode.modelUnavailable,
        '厂商 TTS 不可用',
      );
    }
    return Ok<SpeechArtifact>(
      SpeechArtifact(
        ref: 'audio-$calls',
        duration: Duration(milliseconds: text.length * 60),
      ),
    );
  }
}

/// 未配置真实 TTS 时的兜底：始终降级为文字，绝不悄悄换音色。
class UnavailableTtsAdapter implements TtsAdapter {
  const UnavailableTtsAdapter();

  @override
  String get vendorKey => '';

  @override
  Future<Result<SpeechArtifact>> synthesize({
    required String provider,
    required String model,
    required String voiceId,
    required String text,
    required Map<String, Object?> params,
  }) async =>
      err<SpeechArtifact>(FailureCode.modelUnavailable, 'TTS 适配器未配置');
}

/// 可控 ASR 假适配器。
class FakeAsrAdapter implements AsrAdapter {
  FakeAsrAdapter({this.available = true, this.text = 'hello'});

  bool available;
  String text;
  int calls = 0;

  @override
  Future<Result<Transcript>> transcribe({required List<int> audio}) async {
    calls++;
    if (!available) {
      return err<Transcript>(FailureCode.unavailable, 'ASR 不可用');
    }
    return Ok<Transcript>(Transcript(text: text));
  }
}

/// 未配置真实 ASR 时的兜底：转写降级但不阻塞播放。
class UnavailableAsrAdapter implements AsrAdapter {
  const UnavailableAsrAdapter();

  @override
  Future<Result<Transcript>> transcribe({required List<int> audio}) async =>
      err<Transcript>(FailureCode.unavailable, 'ASR 适配器未配置');
}

/// 一次语音回复的结果。
///
/// [spoken] 为 false 时表示厂商故障，已降级为文字；此时 [voiceId]/[provider]
/// 仍是档案原值，绝不改变。
class SpeechOutcome {
  const SpeechOutcome._({
    required this.text,
    required this.provider,
    required this.voiceId,
    this.audioRef,
    this.downgradeReason,
  });

  factory SpeechOutcome.spoken({
    required String text,
    required String provider,
    required String voiceId,
    required String audioRef,
  }) =>
      SpeechOutcome._(
        text: text,
        provider: provider,
        voiceId: voiceId,
        audioRef: audioRef,
      );

  factory SpeechOutcome.textOnly({
    required String text,
    required String provider,
    required String voiceId,
    required String downgradeReason,
  }) =>
      SpeechOutcome._(
        text: text,
        provider: provider,
        voiceId: voiceId,
        downgradeReason: downgradeReason,
      );

  final String text;
  final String provider;
  final String voiceId;
  final String? audioRef;
  final String? downgradeReason;

  bool get spoken => audioRef != null;
  bool get degraded => downgradeReason != null;

  Map<String, Object?> toJson() => {
        'text': text,
        'provider': provider,
        'voiceId': voiceId,
        'spoken': spoken,
        if (audioRef != null) 'audioRef': audioRef,
        if (downgradeReason != null) 'downgradeReason': downgradeReason,
      };
}

/// 一次转写结果。[degraded] 为 true 时不阻塞音频播放。
class AsrOutcome {
  const AsrOutcome.success(Transcript this.transcript) : degraded = false;
  const AsrOutcome.degraded()
      : transcript = null,
        degraded = true;

  final Transcript? transcript;
  final bool degraded;

  Map<String, Object?> toJson() => {
        'degraded': degraded,
        if (transcript != null) 'transcript': transcript!.toJson(),
      };
}

/// 客户端短期会话票据，5 分钟有效。不含任何厂商 key。
class VoiceTicket {
  const VoiceTicket({
    required this.token,
    required this.aiId,
    required this.expiresAt,
  });

  final String token;
  final AiId aiId;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => {
        'token': token,
        'aiId': aiId.value,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };
}

/// 语音网关：统一 TTS/ASR 入口 + 客户端短期票据。
class VoiceGateway {
  VoiceGateway({
    required VoiceProfiles profiles,
    required TtsAdapter tts,
    required AsrAdapter asr,
    Clock clock = const SystemClock(),
    Duration ticketTtl = const Duration(minutes: 5),
  })  : _profiles = profiles,
        _tts = tts,
        _asr = asr,
        _clock = clock,
        _ticketTtl = ticketTtl;

  final VoiceProfiles _profiles;
  final TtsAdapter _tts;
  final AsrAdapter _asr;
  final Clock _clock;
  final Duration _ticketTtl;
  final Map<String, VoiceTicket> _tickets = <String, VoiceTicket>{};
  int _ticketSeq = 0;

  /// 用某 AI 的音色档案合成一句话。
  ///
  /// 厂商故障/限流时返回 [SpeechOutcome.textOnly]（仍为 Ok），文字照常发出，
  /// `voice_id` 与 `provider` 保持档案原值，绝不静默换音色。
  Future<Result<SpeechOutcome>> speak({
    required AiId ai,
    required String text,
  }) async {
    final profileResult = await _profiles.get(ai: ai);
    if (profileResult.isErr) {
      final failure = profileResult.failureOrNull!;
      return err<SpeechOutcome>(failure.code, failure.message);
    }
    final profile = profileResult.value;
    if (text.trim().isEmpty) {
      return err<SpeechOutcome>(FailureCode.invalidArgument, 'text 不能为空');
    }
    try {
      final synthesized = await _tts.synthesize(
        provider: profile.provider,
        model: profile.model,
        voiceId: profile.voiceId,
        text: text,
        params: profile.params,
      );
      if (synthesized.isErr) {
        return Ok<SpeechOutcome>(
          SpeechOutcome.textOnly(
            text: text,
            provider: profile.provider,
            voiceId: profile.voiceId,
            downgradeReason: synthesized.failureOrNull!.code.name,
          ),
        );
      }
      return Ok<SpeechOutcome>(
        SpeechOutcome.spoken(
          text: text,
          provider: profile.provider,
          voiceId: profile.voiceId,
          audioRef: synthesized.value.ref,
        ),
      );
    } catch (_) {
      // 适配器抛错也按降级处理：只降文字，不换音色。
      return Ok<SpeechOutcome>(
        SpeechOutcome.textOnly(
          text: text,
          provider: profile.provider,
          voiceId: profile.voiceId,
          downgradeReason: FailureCode.modelUnavailable.name,
        ),
      );
    }
  }

  /// 转写一段音频。转写失败不阻塞通话/播放，返回降级结果（仍为 Ok）。
  Future<Result<AsrOutcome>> transcribe({
    required AiId ai,
    required List<int> audio,
  }) async {
    try {
      final result = await _asr.transcribe(audio: audio);
      if (result.isErr) {
        return Ok<AsrOutcome>(const AsrOutcome.degraded());
      }
      return Ok<AsrOutcome>(AsrOutcome.success(result.value));
    } catch (_) {
      return Ok<AsrOutcome>(const AsrOutcome.degraded());
    }
  }

  /// 为客户端签发短期会话票据；客户端凭票据试听/合成，永不接触厂商 key。
  Future<Result<VoiceTicket>> issueTicket({
    required AiId ai,
    required String ownerAccountId,
  }) async {
    final profileResult = await _profiles.get(ai: ai);
    if (profileResult.isErr) {
      final failure = profileResult.failureOrNull!;
      return err<VoiceTicket>(failure.code, failure.message);
    }
    final expiresAt = _clock.now().add(_ticketTtl);
    final token = 'vt_${ownerAccountId}_${ai.value}_${_ticketSeq++}';
    final ticket = VoiceTicket(token: token, aiId: ai, expiresAt: expiresAt);
    _tickets[token] = ticket;
    return Ok<VoiceTicket>(ticket);
  }

  /// 校验票据：无效、错配或过期都返回 unauthenticated。
  Future<Result<VoiceTicket>> redeemTicket({
    required String token,
    required AiId ai,
  }) async {
    final ticket = _tickets[token];
    if (ticket == null || ticket.aiId != ai) {
      return err<VoiceTicket>(FailureCode.unauthenticated, '票据无效');
    }
    if (!_clock.now().isBefore(ticket.expiresAt)) {
      return err<VoiceTicket>(FailureCode.unauthenticated, '票据已过期');
    }
    return Ok<VoiceTicket>(ticket);
  }
}
