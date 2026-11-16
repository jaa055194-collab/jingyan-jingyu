/// 音色档案（M08，FR-30/31、AC-11）。
///
/// 每个 AI 固定一份 `provider + model + voice_id + 参数` 档案；不做本地 TTS，
/// 厂商故障只降文字，绝不换音色、不跨厂商（FR-30）。
///
/// 这里只定义对外接口与内存实现：持久化实现（SQLite）以后按同一份
/// [VoiceProfiles] 契约实现并在装配处替换，调用方零改动。
library;

import 'package:jingyu_core/jingyu_core.dart';

/// 音色档案：某 AI 当前生效的音色配置。
class VoiceProfile {
  const VoiceProfile({
    required this.aiId,
    required this.provider,
    required this.model,
    required this.voiceId,
    required this.params,
    required this.revision,
    required this.consentRef,
    required this.activatedAt,
    this.pendingParams,
    this.pendingRevision,
  });

  final AiId aiId;

  /// 固定厂商；不跨厂商自动切换。
  final String provider;

  /// 厂商内固定模型。
  final String model;

  /// 厂商音色标识；故障时保持不变。
  final String voiceId;

  /// 语速、音调、音量、情绪/风格 instruction 等参数（当前生效 revision）。
  final Map<String, Object?> params;

  /// 当前生效 revision 号，从 1 起。
  final int revision;

  /// 同意声明引用；删除档案后仍保留同意记录。
  final String consentRef;

  final DateTime activatedAt;

  /// 已登记但尚未在句边界生效的参数。
  final Map<String, Object?>? pendingParams;

  /// 待生效参数将产生的 revision 号。
  final int? pendingRevision;

  bool get hasPendingRevision => pendingRevision != null;

  VoiceProfile copyWith({
    Map<String, Object?>? params,
    int? revision,
    int? pendingRevision,
    Map<String, Object?>? pendingParams,
    bool clearPending = false,
  }) =>
      VoiceProfile(
        aiId: aiId,
        provider: provider,
        model: model,
        voiceId: voiceId,
        params: params ?? this.params,
        revision: revision ?? this.revision,
        consentRef: consentRef,
        activatedAt: activatedAt,
        pendingParams:
            clearPending ? null : (pendingParams ?? this.pendingParams),
        pendingRevision:
            clearPending ? null : (pendingRevision ?? this.pendingRevision),
      );

  Map<String, Object?> toJson() => {
        'aiId': aiId.value,
        'provider': provider,
        'model': model,
        'voiceId': voiceId,
        'params': params,
        'revision': revision,
        'consentRef': consentRef,
        'activatedAt': activatedAt.toUtc().toIso8601String(),
        if (pendingRevision != null) 'pendingRevision': pendingRevision,
        if (pendingParams != null) 'pendingParams': pendingParams,
      };
}

/// 一次历史 revision 快照。
class VoiceRevision {
  const VoiceRevision({
    required this.revision,
    required this.params,
    required this.createdAt,
  });

  final int revision;
  final Map<String, Object?> params;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'revision': revision,
        'params': params,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };
}

/// 同意声明记录；删除档案时保留，不保留音频明文（FR-31）。
class VoiceConsent {
  const VoiceConsent({
    required this.consentRef,
    required this.aiId,
    required this.grantedBy,
    required this.grantedAt,
    this.scope = '本人或已授权声音；禁第三方、未成年人',
  });

  final String consentRef;
  final AiId aiId;
  final String grantedBy;
  final DateTime grantedAt;
  final String scope;

  Map<String, Object?> toJson() => {
        'consentRef': consentRef,
        'aiId': aiId.value,
        'grantedBy': grantedBy,
        'grantedAt': grantedAt.toUtc().toIso8601String(),
        'scope': scope,
      };
}

/// 上传样本的元数据。真实音频处理不在本模块范围，只校验质检门槛。
class VoiceSampleMeta {
  const VoiceSampleMeta({
    required this.duration,
    required this.sampleRateHz,
    required this.channels,
    this.hasBgm = false,
    this.hasReverb = false,
    this.silenceRatio = 0,
    this.clippingRatio = 0,
    this.snrDb = 30,
    this.multiVoice = false,
  });

  final Duration duration;
  final int sampleRateHz;
  final int channels;
  final bool hasBgm;
  final bool hasReverb;

  /// 静音占比（0–1）。
  final double silenceRatio;

  /// 削波占比（0–1）。
  final double clippingRatio;

  /// 信噪比（dB）。
  final double snrDb;
  final bool multiVoice;
}

/// 校验上传样本是否满足 FR-31 质检门槛；返回 null 表示通过。
///
/// 内存与 SQLite 实现共用同一份校验，避免两套规则漂移。
Failure? validateVoiceSample(VoiceSampleMeta sample, String consentRef) {
  if (consentRef.trim().isEmpty) {
    return const Failure(FailureCode.invalidArgument, '必须提供 consent_ref');
  }
  final seconds = sample.duration.inMilliseconds / 1000.0;
  if (seconds < 10 || seconds > 30) {
    return const Failure(FailureCode.invalidArgument, '样本时长必须在 10–30s');
  }
  if (sample.channels != 1) {
    return const Failure(FailureCode.invalidArgument, '样本必须单声道');
  }
  if (sample.sampleRateHz < 16000) {
    return const Failure(FailureCode.invalidArgument, '采样率必须 ≥16kHz');
  }
  if (sample.hasBgm || sample.hasReverb) {
    return const Failure(FailureCode.invalidArgument, '样本不能含 BGM 或混响');
  }
  if (sample.multiVoice) {
    return const Failure(FailureCode.invalidArgument, '样本不能含多人声');
  }
  if (sample.silenceRatio > 0.5) {
    return const Failure(FailureCode.invalidArgument, '静音比例过高');
  }
  if (sample.clippingRatio > 0.01) {
    return const Failure(FailureCode.invalidArgument, '削波比例过高');
  }
  if (sample.snrDb < 15) {
    return const Failure(FailureCode.invalidArgument, '信噪比过低');
  }
  return null;
}

/// 校验创建档案的必填字段；返回 null 表示通过。
Failure? validateVoiceCreation({
  required String provider,
  required String model,
  required String voiceId,
  required String consentRef,
}) {
  if (provider.trim().isEmpty) {
    return const Failure(FailureCode.invalidArgument, 'provider 不能为空');
  }
  if (model.trim().isEmpty) {
    return const Failure(FailureCode.invalidArgument, 'model 不能为空');
  }
  if (voiceId.trim().isEmpty) {
    return const Failure(FailureCode.invalidArgument, 'voice_id 不能为空');
  }
  if (consentRef.trim().isEmpty) {
    return const Failure(FailureCode.invalidArgument, '必须提供 consent_ref');
  }
  return null;
}

/// 音色档案服务接口，登记到 [HostServices]。
abstract interface class VoiceProfiles {
  /// 创建档案并立即激活。同一 AI 只允许一个档案，重复创建返回 conflict。
  Future<Result<VoiceProfile>> create({
    required AiId ai,
    required String provider,
    required String model,
    required String voiceId,
    required String consentRef,
    required String grantedBy,
    Map<String, Object?> params = const <String, Object?>{},
  });

  Future<Result<VoiceProfile>> get({required AiId ai});

  /// 登记新参数；在 [applyAtSentenceBoundary] 之前不生效。
  Future<Result<VoiceProfile>> stageParams({
    required AiId ai,
    required Map<String, Object?> params,
  });

  /// 回滚到指定历史 revision，同样只在句边界生效。
  Future<Result<VoiceProfile>> rollback({
    required AiId ai,
    required int revision,
  });

  /// 句边界：把待生效参数提升为当前 revision。
  Future<Result<VoiceProfile>> applyAtSentenceBoundary({required AiId ai});

  Future<Result<List<VoiceRevision>>> history({required AiId ai});

  /// 同意记录在删除档案后仍可查询。
  Future<Result<List<VoiceConsent>>> consents({required AiId ai});

  /// 删除档案与音频引用，保留同意记录。
  Future<Result<bool>> delete({required AiId ai});

  /// 校验并登记导入样本；返回样本引用（不含音频明文）。
  Future<Result<String>> importSample({
    required AiId ai,
    required VoiceSampleMeta sample,
    required String consentRef,
  });
}

/// 内存实现。
class InMemoryVoiceProfiles implements VoiceProfiles {
  InMemoryVoiceProfiles({Clock clock = const SystemClock()}) : _clock = clock;

  final Clock _clock;
  final Map<String, VoiceProfile> _current = <String, VoiceProfile>{};
  final Map<String, List<VoiceRevision>> _revisions =
      <String, List<VoiceRevision>>{};
  final Map<String, List<VoiceConsent>> _consents =
      <String, List<VoiceConsent>>{};
  final Map<String, List<String>> _samples = <String, List<String>>{};
  int _sampleSeq = 0;

  @override
  Future<Result<VoiceProfile>> create({
    required AiId ai,
    required String provider,
    required String model,
    required String voiceId,
    required String consentRef,
    required String grantedBy,
    Map<String, Object?> params = const <String, Object?>{},
  }) async {
    final key = ai.value;
    if (_current.containsKey(key)) {
      return err<VoiceProfile>(
        FailureCode.conflict,
        '该 AI 已有音色档案',
      );
    }
    final invalid = validateVoiceCreation(
      provider: provider,
      model: model,
      voiceId: voiceId,
      consentRef: consentRef,
    );
    if (invalid != null) return Err<VoiceProfile>(invalid);

    final now = _clock.now();
    final profile = VoiceProfile(
      aiId: ai,
      provider: provider,
      model: model,
      voiceId: voiceId,
      params: _freeze(params),
      revision: 1,
      consentRef: consentRef,
      activatedAt: now,
    );
    _current[key] = profile;
    _revisions[key] = <VoiceRevision>[
      VoiceRevision(revision: 1, params: _freeze(params), createdAt: now),
    ];
    _recordConsent(
      ai: ai,
      consentRef: consentRef,
      grantedBy: grantedBy.isEmpty ? 'unknown' : grantedBy,
      grantedAt: now,
    );
    return Ok<VoiceProfile>(profile);
  }

  @override
  Future<Result<VoiceProfile>> get({required AiId ai}) async {
    final profile = _current[ai.value];
    if (profile == null) {
      return err<VoiceProfile>(FailureCode.notFound, '音色档案不存在');
    }
    return Ok<VoiceProfile>(profile);
  }

  @override
  Future<Result<VoiceProfile>> stageParams({
    required AiId ai,
    required Map<String, Object?> params,
  }) async {
    final profile = _current[ai.value];
    if (profile == null) {
      return err<VoiceProfile>(FailureCode.notFound, '音色档案不存在');
    }
    final nextRevision =
        (profile.pendingRevision ?? profile.revision) + 1;
    final staged = profile.copyWith(
      pendingParams: _freeze(params),
      pendingRevision: nextRevision,
    );
    _current[ai.value] = staged;
    return Ok<VoiceProfile>(staged);
  }

  @override
  Future<Result<VoiceProfile>> rollback({
    required AiId ai,
    required int revision,
  }) async {
    final profile = _current[ai.value];
    if (profile == null) {
      return err<VoiceProfile>(FailureCode.notFound, '音色档案不存在');
    }
    final snapshots = _revisions[ai.value] ?? const <VoiceRevision>[];
    VoiceRevision? target;
    for (final snapshot in snapshots) {
      if (snapshot.revision == revision) {
        target = snapshot;
        break;
      }
    }
    if (target == null) {
      return err<VoiceProfile>(FailureCode.notFound, '目标 revision 不存在');
    }
    final nextRevision =
        (profile.pendingRevision ?? profile.revision) + 1;
    final staged = profile.copyWith(
      pendingParams: _freeze(target.params),
      pendingRevision: nextRevision,
    );
    _current[ai.value] = staged;
    return Ok<VoiceProfile>(staged);
  }

  @override
  Future<Result<VoiceProfile>> applyAtSentenceBoundary({
    required AiId ai,
  }) async {
    final profile = _current[ai.value];
    if (profile == null) {
      return err<VoiceProfile>(FailureCode.notFound, '音色档案不存在');
    }
    final pendingParams = profile.pendingParams;
    final pendingRevision = profile.pendingRevision;
    if (pendingParams == null || pendingRevision == null) {
      return Ok<VoiceProfile>(profile);
    }
    final applied = profile.copyWith(
      params: _freeze(pendingParams),
      revision: pendingRevision,
      clearPending: true,
    );
    _current[ai.value] = applied;
    _revisions.putIfAbsent(
      ai.value,
      () => <VoiceRevision>[],
    ).add(
      VoiceRevision(
        revision: pendingRevision,
        params: _freeze(pendingParams),
        createdAt: _clock.now(),
      ),
    );
    return Ok<VoiceProfile>(applied);
  }

  @override
  Future<Result<List<VoiceRevision>>> history({required AiId ai}) async {
    final snapshots = _revisions[ai.value];
    if (_current[ai.value] == null) {
      return err<List<VoiceRevision>>(FailureCode.notFound, '音色档案不存在');
    }
    return Ok<List<VoiceRevision>>(
      List<VoiceRevision>.unmodifiable(
        snapshots ?? const <VoiceRevision>[],
      ),
    );
  }

  @override
  Future<Result<List<VoiceConsent>>> consents({required AiId ai}) async {
    return Ok<List<VoiceConsent>>(
      List<VoiceConsent>.unmodifiable(
        _consents[ai.value] ?? const <VoiceConsent>[],
      ),
    );
  }

  @override
  Future<Result<bool>> delete({required AiId ai}) async {
    final key = ai.value;
    if (!_current.containsKey(key)) {
      return err<bool>(FailureCode.notFound, '音色档案不存在');
    }
    // 只删档案与音频引用；同意记录保留（FR-31）。
    _current.remove(key);
    _revisions.remove(key);
    _samples.remove(key);
    return Ok<bool>(true);
  }

  @override
  Future<Result<String>> importSample({
    required AiId ai,
    required VoiceSampleMeta sample,
    required String consentRef,
  }) async {
    final failure = validateVoiceSample(sample, consentRef);
    if (failure != null) {
      return Err<String>(failure);
    }
    final sampleId = 'sample-${_sampleSeq++}';
    _samples.putIfAbsent(ai.value, () => <String>[]).add(sampleId);
    _recordConsent(
      ai: ai,
      consentRef: consentRef,
      grantedBy: 'self',
      grantedAt: _clock.now(),
    );
    return Ok<String>(sampleId);
  }

  void _recordConsent({
    required AiId ai,
    required String consentRef,
    required String grantedBy,
    required DateTime grantedAt,
  }) {
    final list = _consents.putIfAbsent(ai.value, () => <VoiceConsent>[]);
    if (list.any((consent) => consent.consentRef == consentRef)) return;
    list.add(
      VoiceConsent(
        consentRef: consentRef,
        aiId: ai,
        grantedBy: grantedBy,
        grantedAt: grantedAt,
      ),
    );
  }

  Map<String, Object?> _freeze(Map<String, Object?> params) =>
      Map<String, Object?>.unmodifiable(params);
}
