/// FR-38/FR-39 avatar references for VRM and device-local Live2D models.
///
/// Model-specific parameters, model files and their safe import belong to each
/// device. This registry publishes only modelId/profileRev/kind references;
/// reference activation does not prove a device can load or render that model.
///
/// Avatar selection is per DEVICE, not per account: the same owner may keep
/// independent active models on their phone and PC. Every read/write is scoped
/// to `(ownerId, deviceId)`; a lookup from another device (or another owner)
/// returns notFound.
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

/// 一个已登记的形象档案。
class AvatarProfile {
  const AvatarProfile({
    required this.avatarId,
    required this.ownerId,
    required this.kind,
    required this.modelId,
    required this.profileRev,
    required this.updatedAt,
  });

  final String avatarId;
  final String ownerId;
  final AvatarKind kind;

  /// 稳定的模型标识（导入内容指纹或素材 id），设备本地据此加载。
  final String modelId;

  /// 单调递增的档案版本号，变更即前进。
  final int profileRev;

  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'avatarId': avatarId,
    'ownerId': ownerId,
    'kind': kind.wire,
    'modelId': modelId,
    'profileRev': profileRev,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

/// 下发给客户端的形象广播：单设备拿到的 `model_id + profile_rev` 必须一致。
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

/// 形象登记契约。
///
/// `ownerId` 与 `deviceId` 都来自可信认证边界，绝不信请求 JSON。所有操作都
/// 以 `(ownerId, deviceId)` 为隔离维度：跨设备或跨 owner 一律 notFound。
abstract interface class AvatarRegistry {
  /// 登记一个设备本地可解析的模型引用。
  Future<Result<AvatarProfile>> register({
    required String ownerId,
    required String deviceId,
    required AvatarKind kind,
    required String modelId,
  });

  /// 启用某形象（切换），要求 revision 匹配。
  Future<Result<AvatarProfile>> enable({
    required String ownerId,
    required String deviceId,
    required String avatarId,
    required int expectedRevision,
  });

  /// 停用某形象，profileRev 前进。
  Future<Result<AvatarProfile>> disable({
    required String ownerId,
    required String deviceId,
    required String avatarId,
    required int expectedRevision,
  });

  Future<Result<AvatarProfile>> get({
    required String ownerId,
    required String deviceId,
    required String avatarId,
  });

  Future<List<AvatarProfile>> list(String ownerId, String deviceId);

  /// 当前启用设备的形象广播；没有启用形象返回 notFound。
  Future<Result<AvatarBroadcast>> active(String ownerId, String deviceId);
}

/// 内存实现。`(owner, device)` 隔离：跨 owner 或跨设备一律 notFound。
class InMemoryAvatarRegistry implements AvatarRegistry {
  InMemoryAvatarRegistry({
    this.clock = const SystemClock(),
    String Function()? newId,
  }) : _newId = newId ?? _counterIds();

  final Clock clock;
  final String Function() _newId;

  final Map<(String, String), Map<String, AvatarProfile>> _byOwnerDevice =
      <(String, String), Map<String, AvatarProfile>>{};
  final Map<(String, String), String> _active =
      <(String, String), String>{};

  static String Function() _counterIds() {
    var n = 0;
    return () => 'av${++n}';
  }

  static bool _validModelId(String value) =>
      value.length <= 128 &&
      !value.toLowerCase().startsWith('legacy_') &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value);

  AvatarProfile? _find(String ownerId, String deviceId, String avatarId) =>
      _byOwnerDevice[(ownerId, deviceId)]?[avatarId];

  @override
  Future<Result<AvatarProfile>> register({
    required String ownerId,
    required String deviceId,
    required AvatarKind kind,
    required String modelId,
  }) async {
    try {
      validateId(ownerId, kind: 'owner');
      validateId(deviceId, kind: 'device');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'bad owner or device id');
    }
    if (!_validModelId(modelId)) {
      return err(FailureCode.invalidArgument, 'bad model id');
    }
    final profile = AvatarProfile(
      avatarId: _newId(),
      ownerId: ownerId,
      kind: kind,
      modelId: modelId,
      profileRev: 1,
      updatedAt: clock.now().toUtc(),
    );
    _byOwnerDevice.putIfAbsent(
      (ownerId, deviceId),
      () => <String, AvatarProfile>{},
    )[profile.avatarId] = profile;
    return Ok(profile);
  }

  @override
  Future<Result<AvatarProfile>> enable({
    required String ownerId,
    required String deviceId,
    required String avatarId,
    required int expectedRevision,
  }) async {
    final profile = _find(ownerId, deviceId, avatarId);
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
      updatedAt: clock.now().toUtc(),
    );
    _byOwnerDevice[(ownerId, deviceId)]![avatarId] = updated;
    _active[(ownerId, deviceId)] = avatarId;
    return Ok(updated);
  }

  @override
  Future<Result<AvatarProfile>> disable({
    required String ownerId,
    required String deviceId,
    required String avatarId,
    required int expectedRevision,
  }) async {
    final profile = _find(ownerId, deviceId, avatarId);
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
      updatedAt: clock.now().toUtc(),
    );
    _byOwnerDevice[(ownerId, deviceId)]![avatarId] = updated;
    if (_active[(ownerId, deviceId)] == avatarId) {
      _active.remove((ownerId, deviceId));
    }
    return Ok(updated);
  }

  @override
  Future<Result<AvatarProfile>> get({
    required String ownerId,
    required String deviceId,
    required String avatarId,
  }) async {
    final profile = _find(ownerId, deviceId, avatarId);
    if (profile == null) return err(FailureCode.notFound, 'avatar not found');
    return Ok(profile);
  }

  @override
  Future<List<AvatarProfile>> list(String ownerId, String deviceId) async {
    final owned = _byOwnerDevice[(ownerId, deviceId)];
    if (owned == null) return const <AvatarProfile>[];
    final list = owned.values.toList()
      ..sort((a, b) => a.avatarId.compareTo(b.avatarId));
    return List<AvatarProfile>.unmodifiable(list);
  }

  @override
  Future<Result<AvatarBroadcast>> active(
    String ownerId,
    String deviceId,
  ) async {
    final avatarId = _active[(ownerId, deviceId)];
    if (avatarId == null) return err(FailureCode.notFound, 'no active avatar');
    final profile = _find(ownerId, deviceId, avatarId);
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
