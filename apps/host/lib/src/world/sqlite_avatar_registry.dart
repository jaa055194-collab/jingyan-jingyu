/// FR-38/FR-39 形象登记的 SQLite 实现。与 `InMemoryAvatarRegistry` 共用同一组契约测试。
///
/// 仅保存模型引用与档案 revision；`model_id + profile_rev` 由
/// `world_avatar_active` 表按 `(owner_id, device_id)` 权威发布。形象选择是
/// 设备级而非账号级：同一 owner 的手机与 PC 各自独立。
library;

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'avatars.dart';

class SqliteAvatarRegistry implements AvatarRegistry {
  SqliteAvatarRegistry({
    required this.database,
    this.clock = const SystemClock(),
  });

  final Database database;
  final Clock clock;
  int _seq = 0;

  String _newAvatarId() =>
      'av_${clock.now().toUtc().microsecondsSinceEpoch}_${++_seq}';

  static bool _validModelId(String value) =>
      value.length <= 128 &&
      !value.toLowerCase().startsWith('legacy_') &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value);

  AvatarProfile? _toProfile(Map<String, Object?> row) {
    try {
      return AvatarProfile(
        avatarId: row['avatar_id'] as String,
        ownerId: row['owner_id'] as String,
        kind: AvatarKind.tryParse(row['kind'] as String) ?? AvatarKind.vrm,
        modelId: row['model_id'] as String,
        profileRev: row['profile_rev'] as int,
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  Future<AvatarProfile?> _find(
    String ownerId,
    String deviceId,
    String avatarId,
  ) async {
    final rows = await database.query(
      'SELECT * FROM world_avatars '
      'WHERE owner_id = ? AND device_id = ? AND avatar_id = ?',
      [ownerId, deviceId, avatarId],
    );
    if (rows.isEmpty) return null;
    return _toProfile(rows.single);
  }

  Future<Result<AvatarProfile>> _updateProfile(
    String ownerId,
    String deviceId,
    AvatarProfile profile,
  ) async {
    final rev = profile.profileRev + 1;
    final now = clock.now().toUtc();
    await database.execute(
      'UPDATE world_avatars SET profile_rev = ?, updated_at = ? '
      'WHERE owner_id = ? AND device_id = ? AND avatar_id = ?',
      [rev, now.toIso8601String(), ownerId, deviceId, profile.avatarId],
    );
    return Ok(
      AvatarProfile(
        avatarId: profile.avatarId,
        ownerId: profile.ownerId,
        kind: profile.kind,
        modelId: profile.modelId,
        profileRev: rev,
        updatedAt: now,
      ),
    );
  }

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
    final avatarId = _newAvatarId();
    final now = clock.now().toUtc();
    await database.execute(
      'INSERT INTO world_avatars('
      'avatar_id, owner_id, device_id, kind, model_id, profile_rev, updated_at'
      ') VALUES(?,?,?,?,?,?,?)',
      [
        avatarId,
        ownerId,
        deviceId,
        kind.wire,
        modelId,
        1,
        now.toIso8601String(),
      ],
    );
    return Ok(
      AvatarProfile(
        avatarId: avatarId,
        ownerId: ownerId,
        kind: kind,
        modelId: modelId,
        profileRev: 1,
        updatedAt: now,
      ),
    );
  }

  @override
  Future<Result<AvatarProfile>> enable({
    required String ownerId,
    required String deviceId,
    required String avatarId,
    required int expectedRevision,
  }) async {
    final profile = await _find(ownerId, deviceId, avatarId);
    if (profile == null) return err(FailureCode.notFound, 'avatar not found');
    if (profile.profileRev != expectedRevision) {
      return err(FailureCode.conflict, 'profile revision mismatch');
    }
    final result = await _updateProfile(ownerId, deviceId, profile);
    if (result.isErr) return result;
    final updated = result.value;
    await database.execute(
      'INSERT INTO world_avatar_active('
      'owner_id, device_id, avatar_id, profile_rev'
      ') VALUES(?,?,?,?) '
      'ON CONFLICT(owner_id, device_id) DO UPDATE SET '
      'avatar_id=excluded.avatar_id, profile_rev=excluded.profile_rev',
      [ownerId, deviceId, avatarId, updated.profileRev],
    );
    return Ok(updated);
  }

  @override
  Future<Result<AvatarProfile>> disable({
    required String ownerId,
    required String deviceId,
    required String avatarId,
    required int expectedRevision,
  }) async {
    final profile = await _find(ownerId, deviceId, avatarId);
    if (profile == null) return err(FailureCode.notFound, 'avatar not found');
    if (profile.profileRev != expectedRevision) {
      return err(FailureCode.conflict, 'profile revision mismatch');
    }
    final result = await _updateProfile(ownerId, deviceId, profile);
    if (result.isErr) return result;
    await database.execute(
      'DELETE FROM world_avatar_active '
      'WHERE owner_id = ? AND device_id = ? AND avatar_id = ?',
      [ownerId, deviceId, avatarId],
    );
    return result;
  }

  @override
  Future<Result<AvatarProfile>> get({
    required String ownerId,
    required String deviceId,
    required String avatarId,
  }) async {
    final profile = await _find(ownerId, deviceId, avatarId);
    if (profile == null) return err(FailureCode.notFound, 'avatar not found');
    return Ok(profile);
  }

  @override
  Future<List<AvatarProfile>> list(String ownerId, String deviceId) async {
    final rows = await database.query(
      'SELECT * FROM world_avatars '
      'WHERE owner_id = ? AND device_id = ? ORDER BY avatar_id',
      [ownerId, deviceId],
    );
    final profiles = <AvatarProfile>[];
    for (final row in rows) {
      final profile = _toProfile(row);
      if (profile != null) profiles.add(profile);
    }
    return List<AvatarProfile>.unmodifiable(profiles);
  }

  @override
  Future<Result<AvatarBroadcast>> active(
    String ownerId,
    String deviceId,
  ) async {
    final activeRows = await database.query(
      'SELECT avatar_id FROM world_avatar_active '
      'WHERE owner_id = ? AND device_id = ?',
      [ownerId, deviceId],
    );
    if (activeRows.isEmpty) {
      return err(FailureCode.notFound, 'no active avatar');
    }
    final avatarId = activeRows.single['avatar_id'] as String;
    final profile = await _find(ownerId, deviceId, avatarId);
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
