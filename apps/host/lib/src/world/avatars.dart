/// FR-38/FR-39 形象登记：VRM 3D（默认，所有端可用）与 Live2D（仅宿主机端）。
///
/// 两套形象共用同一套语义表情参数（开口度、表情标签、valence/energy），
/// 由当前形象配置翻译成模型参数。登记/启用后广播 `model_id + profile_rev`，
/// 双端据此渲染一致的形象（AC-25）。缺参数映射禁止启用（不许猜参数）。
///
/// 这里只做登记与版本权威；`.moc3` 安全解包与校验（Zip Slip、扩展名白名单、
/// 条目数/体积/压缩比/JSON 深度、纹理魔数）在 `live2d_import.dart`（未在本切片）。
library;

import 'package:jingyu_core/jingyu_core.dart';

/// 形象轨道。
enum AvatarKind {
  vrm('vrm'),
  live2d('live2d');

  const AvatarKind(this.wire);
  final String wire;
  static AvatarKind? tryParse(String raw) {
    for (final kind in values) {
      if (kind.wire == raw) return kind;
    }
    return null;
  }
}

/// 两套形象共用的语义参数键（FR-38）。
abstract final class AvatarSemanticParam {
  static const String mouthOpen = 'mouthOpen';
  static const String expression = 'expression';
  static const String valence = 'valence';
  static const String energy = 'energy';

  /// 启用某个形象前必须齐全的语义参数。
  static const List<String> required = <String>[
    mouthOpen,
    expression,
    valence,
    energy,
  ];
}

/// 一个已登记的形象档案。
class AvatarProfile {
  const AvatarProfile({
    required this.avatarId,
    required this.ownerId,
    required this.kind,
    required this.modelId,
    required this.profileRev,
    required this.paramMap,
    required this.updatedAt,
  });

  final String avatarId;
  final String ownerId;
  final AvatarKind kind;

  /// 稳定的模型标识（导入内容指纹或素材 id），双端据此一致。
  final String modelId;

  /// 单调递增的档案版本号，变更即前进。
  final int profileRev;

  /// 语义参数 -> 模型参数名。Live2D 启用前必须覆盖 [AvatarSemanticParam.required]。
  final Map<String, Object?> paramMap;
  final DateTime updatedAt;

  bool get hasCompleteParamMap => AvatarSemanticParam.required.every((key) {
    final value = paramMap[key];
    return value is String && value.isNotEmpty;
  });

  Map<String, Object?> toJson() => {
    'avatarId': avatarId,
    'ownerId': ownerId,
    'kind': kind.wire,
    'modelId': modelId,
    'profileRev': profileRev,
    'paramMap': paramMap,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

/// 下发给客户端的形象广播：双端拿到的 `model_id + profile_rev` 必须一致。
class AvatarBroadcast {
  const AvatarBroadcast({
    required this.modelId,
    required this.profileRev,
    required this.kind,
  });

  final String modelId;
  final int profileRev;
  final AvatarKind kind;

  Map<String, Object?> toJson() => {
    'modelId': modelId,
    'profileRev': profileRev,
    'kind': kind.wire,
  };
}

/// 形象登记契约。ownerId 来自可信认证边界，绝不信请求 JSON。
abstract interface class AvatarRegistry {
  /// 登记一个形象。Live2D 可先无映射登记，待向导补齐后启用。
  Future<Result<AvatarProfile>> register({
    required String ownerId,
    required AvatarKind kind,
    required String modelId,
    Map<String, Object?> paramMap = const <String, Object?>{},
  });

  /// 写入/替换语义参数映射，profileRev 前进。
  Future<Result<AvatarProfile>> setParamMap({
    required String ownerId,
    required String avatarId,
    required Map<String, Object?> paramMap,
  });

  /// 启用某形象（切换），要求 revision 匹配且 Live2D 映射齐全。
  Future<Result<AvatarProfile>> enable({
    required String ownerId,
    required String avatarId,
    required int expectedRevision,
  });

  /// 停用某形象，profileRev 前进。
  Future<Result<AvatarProfile>> disable({
    required String ownerId,
    required String avatarId,
    required int expectedRevision,
  });

  Future<Result<AvatarProfile>> get({
    required String ownerId,
    required String avatarId,
  });

  Future<List<AvatarProfile>> list(String ownerId);

  /// 当前启用的形象广播；没有启用形象返回 notFound。
  Future<Result<AvatarBroadcast>> active(String ownerId);
}

/// 内存实现。owner 隔离：跨 owner 一律 notFound。
class InMemoryAvatarRegistry implements AvatarRegistry {
  InMemoryAvatarRegistry({
    this.clock = const SystemClock(),
    String Function()? newId,
  }) : _newId = newId ?? _counterIds();

  final Clock clock;
  final String Function() _newId;

  final Map<String, Map<String, AvatarProfile>> _byOwner =
      <String, Map<String, AvatarProfile>>{};
  final Map<String, String> _active = <String, String>{};

  static String Function() _counterIds() {
    var n = 0;
    return () => 'av${++n}';
  }

  Failure? _validateParamMap(Map<String, Object?> paramMap) {
    for (final entry in paramMap.entries) {
      if (entry.key.isEmpty || entry.key.length > 64) {
        return const Failure(FailureCode.invalidArgument, 'bad param key');
      }
      if (entry.value is! String || (entry.value as String).isEmpty) {
        return const Failure(FailureCode.invalidArgument, 'bad param value');
      }
    }
    return null;
  }

  AvatarProfile? _find(String ownerId, String avatarId) =>
      _byOwner[ownerId]?[avatarId];

  @override
  Future<Result<AvatarProfile>> register({
    required String ownerId,
    required AvatarKind kind,
    required String modelId,
    Map<String, Object?> paramMap = const <String, Object?>{},
  }) async {
    try {
      validateId(ownerId, kind: 'owner');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'bad owner id');
    }
    if (modelId.isEmpty || modelId.length > 128) {
      return err(FailureCode.invalidArgument, 'bad model id');
    }
    final invalid = _validateParamMap(paramMap);
    if (invalid != null) return Err<AvatarProfile>(invalid);
    final profile = AvatarProfile(
      avatarId: _newId(),
      ownerId: ownerId,
      kind: kind,
      modelId: modelId,
      profileRev: 1,
      paramMap: Map<String, Object?>.unmodifiable(paramMap),
      updatedAt: clock.now().toUtc(),
    );
    _byOwner.putIfAbsent(
      ownerId,
      () => <String, AvatarProfile>{},
    )[profile.avatarId] = profile;
    return Ok(profile);
  }

  @override
  Future<Result<AvatarProfile>> setParamMap({
    required String ownerId,
    required String avatarId,
    required Map<String, Object?> paramMap,
  }) async {
    final profile = _find(ownerId, avatarId);
    if (profile == null) return err(FailureCode.notFound, 'avatar not found');
    final invalid = _validateParamMap(paramMap);
    if (invalid != null) return Err<AvatarProfile>(invalid);
    final updated = AvatarProfile(
      avatarId: profile.avatarId,
      ownerId: profile.ownerId,
      kind: profile.kind,
      modelId: profile.modelId,
      profileRev: profile.profileRev + 1,
      paramMap: Map<String, Object?>.unmodifiable(paramMap),
      updatedAt: clock.now().toUtc(),
    );
    _byOwner[ownerId]![avatarId] = updated;
    return Ok(updated);
  }

  @override
  Future<Result<AvatarProfile>> enable({
    required String ownerId,
    required String avatarId,
    required int expectedRevision,
  }) async {
    final profile = _find(ownerId, avatarId);
    if (profile == null) return err(FailureCode.notFound, 'avatar not found');
    if (profile.profileRev != expectedRevision) {
      return err(FailureCode.conflict, 'profile revision mismatch');
    }
    if (profile.kind == AvatarKind.live2d && !profile.hasCompleteParamMap) {
      return err(FailureCode.conflict, 'missing semantic param map');
    }
    final updated = AvatarProfile(
      avatarId: profile.avatarId,
      ownerId: profile.ownerId,
      kind: profile.kind,
      modelId: profile.modelId,
      profileRev: profile.profileRev + 1,
      paramMap: profile.paramMap,
      updatedAt: clock.now().toUtc(),
    );
    _byOwner[ownerId]![avatarId] = updated;
    _active[ownerId] = avatarId;
    return Ok(updated);
  }

  @override
  Future<Result<AvatarProfile>> disable({
    required String ownerId,
    required String avatarId,
    required int expectedRevision,
  }) async {
    final profile = _find(ownerId, avatarId);
    if (profile == null) return err(FailureCode.notFound, 'avatar not found');
    if (profile.profileRev != expectedRevision) {
      return err(FailureCode.conflict, 'profile revision mismatch');
    }
    final updated = AvatarProfile(
      avatarId: profile.avatarId,
      ownerId: profile.ownerId,
      kind: profile.kind,
      modelId: profile.modelId,
      profileRev: profile.profileRev + 1,
      paramMap: profile.paramMap,
      updatedAt: clock.now().toUtc(),
    );
    _byOwner[ownerId]![avatarId] = updated;
    if (_active[ownerId] == avatarId) _active.remove(ownerId);
    return Ok(updated);
  }

  @override
  Future<Result<AvatarProfile>> get({
    required String ownerId,
    required String avatarId,
  }) async {
    final profile = _find(ownerId, avatarId);
    if (profile == null) return err(FailureCode.notFound, 'avatar not found');
    return Ok(profile);
  }

  @override
  Future<List<AvatarProfile>> list(String ownerId) async {
    final owned = _byOwner[ownerId];
    if (owned == null) return const <AvatarProfile>[];
    final list = owned.values.toList()
      ..sort((a, b) => a.avatarId.compareTo(b.avatarId));
    return List<AvatarProfile>.unmodifiable(list);
  }

  @override
  Future<Result<AvatarBroadcast>> active(String ownerId) async {
    final avatarId = _active[ownerId];
    if (avatarId == null) return err(FailureCode.notFound, 'no active avatar');
    final profile = _find(ownerId, avatarId);
    if (profile == null) return err(FailureCode.notFound, 'avatar not found');
    return Ok(
      AvatarBroadcast(
        modelId: profile.modelId,
        profileRev: profile.profileRev,
        kind: profile.kind,
      ),
    );
  }
}
