/// FR-38/FR-39 形象登记的 SQLite 实现。与 `InMemoryAvatarRegistry` 共用同一组契约测试。
///
/// `param_map` 以 JSON 文本存储；启用 Live2D 前校验语义参数齐全；
/// `model_id + profile_rev` 由 `world_avatar_active` 表权威发布。
library;

import 'dart:convert';

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

  bool _complete(Map<String, Object?> paramMap) =>
      AvatarSemanticParam.required.every((key) {
        final value = paramMap[key];
        return value is String && value.isNotEmpty;
      });

  AvatarProfile? _toProfile(Map<String, Object?> row) {
    try {
      final paramRaw = row['param_map'] as String;
      final decoded = jsonDecode(paramRaw);
      if (decoded is! Map<String, dynamic>) return null;
      return AvatarProfile(
        avatarId: row['avatar_id'] as String,
        ownerId: row['owner_id'] as String,
        kind: AvatarKind.tryParse(row['kind'] as String) ?? AvatarKind.vrm,
        modelId: row['model_id'] as String,
        profileRev: row['profile_rev'] as int,
        paramMap: Map<String, Object?>.unmodifiable(
          decoded.cast<String, Object?>(),
        ),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  Future<AvatarProfile?> _find(String ownerId, String avatarId) async {
    final rows = await database.query(
      'SELECT * FROM world_avatars WHERE owner_id = ? AND avatar_id = ?',
      [ownerId, avatarId],
    );
    if (rows.isEmpty) return null;
    return _toProfile(rows.single);
  }

  Future<Result<AvatarProfile>> _updateProfile(
    AvatarProfile profile,
    Map<String, Object?> paramMap,
  ) async {
    final rev = profile.profileRev + 1;
    final now = clock.now().toUtc();
    await database.execute(
      'UPDATE world_avatars SET profile_rev = ?, param_map = ?, updated_at = ? '
      'WHERE owner_id = ? AND avatar_id = ?',
      [
        rev,
        jsonEncode(paramMap),
        now.toIso8601String(),
        profile.ownerId,
        profile.avatarId,
      ],
    );
    return Ok(
      AvatarProfile(
        avatarId: profile.avatarId,
        ownerId: profile.ownerId,
        kind: profile.kind,
        modelId: profile.modelId,
        profileRev: rev,
        paramMap: Map<String, Object?>.unmodifiable(paramMap),
        updatedAt: now,
      ),
    );
  }

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
    final avatarId = _newAvatarId();
    final now = clock.now().toUtc();
    await database.execute(
      'INSERT INTO world_avatars('
      'avatar_id, owner_id, kind, model_id, profile_rev, param_map, updated_at'
      ') VALUES(?,?,?,?,?,?,?)',
      [
        avatarId,
        ownerId,
        kind.wire,
        modelId,
        1,
        jsonEncode(paramMap),
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
        paramMap: Map<String, Object?>.unmodifiable(paramMap),
        updatedAt: now,
      ),
    );
  }

  @override
  Future<Result<AvatarProfile>> setParamMap({
    required String ownerId,
    required String avatarId,
    required Map<String, Object?> paramMap,
  }) async {
    final profile = await _find(ownerId, avatarId);
    if (profile == null) return err(FailureCode.notFound, 'avatar not found');
    final invalid = _validateParamMap(paramMap);
    if (invalid != null) return Err<AvatarProfile>(invalid);
    return _updateProfile(profile, paramMap);
  }

  @override
  Future<Result<AvatarProfile>> enable({
    required String ownerId,
    required String avatarId,
    required int expectedRevision,
  }) async {
    final profile = await _find(ownerId, avatarId);
    if (profile == null) return err(FailureCode.notFound, 'avatar not found');
    if (profile.profileRev != expectedRevision) {
      return err(FailureCode.conflict, 'profile revision mismatch');
    }
    if (profile.kind == AvatarKind.live2d && !_complete(profile.paramMap)) {
      return err(FailureCode.conflict, 'missing semantic param map');
    }
    final result = await _updateProfile(profile, profile.paramMap);
    if (result.isErr) return result;
    final updated = result.value;
    await database.execute(
      'INSERT INTO world_avatar_active(owner_id, avatar_id, profile_rev) '
      'VALUES(?,?,?) '
      'ON CONFLICT(owner_id) DO UPDATE SET '
      'avatar_id=excluded.avatar_id, profile_rev=excluded.profile_rev',
      [ownerId, avatarId, updated.profileRev],
    );
    return Ok(updated);
  }

  @override
  Future<Result<AvatarProfile>> disable({
    required String ownerId,
    required String avatarId,
    required int expectedRevision,
  }) async {
    final profile = await _find(ownerId, avatarId);
    if (profile == null) return err(FailureCode.notFound, 'avatar not found');
    if (profile.profileRev != expectedRevision) {
      return err(FailureCode.conflict, 'profile revision mismatch');
    }
    final result = await _updateProfile(profile, profile.paramMap);
    if (result.isErr) return result;
    await database.execute(
      'DELETE FROM world_avatar_active WHERE owner_id = ? AND avatar_id = ?',
      [ownerId, avatarId],
    );
    return result;
  }

  @override
  Future<Result<AvatarProfile>> get({
    required String ownerId,
    required String avatarId,
  }) async {
    final profile = await _find(ownerId, avatarId);
    if (profile == null) return err(FailureCode.notFound, 'avatar not found');
    return Ok(profile);
  }

  @override
  Future<List<AvatarProfile>> list(String ownerId) async {
    final rows = await database.query(
      'SELECT * FROM world_avatars WHERE owner_id = ? ORDER BY avatar_id',
      [ownerId],
    );
    final profiles = <AvatarProfile>[];
    for (final row in rows) {
      final profile = _toProfile(row);
      if (profile != null) profiles.add(profile);
    }
    return List<AvatarProfile>.unmodifiable(profiles);
  }

  @override
  Future<Result<AvatarBroadcast>> active(String ownerId) async {
    final activeRows = await database.query(
      'SELECT avatar_id FROM world_avatar_active WHERE owner_id = ?',
      [ownerId],
    );
    if (activeRows.isEmpty) {
      return err(FailureCode.notFound, 'no active avatar');
    }
    final avatarId = activeRows.single['avatar_id'] as String;
    final profile = await _find(ownerId, avatarId);
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
