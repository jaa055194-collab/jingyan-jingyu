/// VoiceProfiles 的 SQLite 持久化实现（M08，FR-30/31、AC-11）。
///
/// 与 [InMemoryVoiceProfiles] 共用同一份 [VoiceProfiles] 契约与校验函数；
/// 表结构见 [voiceProfileMigrations]（700–703）。
library;

import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'voice_profiles.dart';

/// SQLite 版音色档案存储。
class SqliteVoiceProfiles implements VoiceProfiles {
  SqliteVoiceProfiles({required this.database, required this.clock});

  final Database database;
  final Clock clock;
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
  }) =>
      database.transaction((tx) async {
        final existing = await tx.query(
          'SELECT 1 FROM voice_profiles WHERE ai_id=?',
          [ai.value],
        );
        if (existing.isNotEmpty) {
          return err<VoiceProfile>(FailureCode.conflict, '该 AI 已有音色档案');
        }
        final invalid = validateVoiceCreation(
          provider: provider,
          model: model,
          voiceId: voiceId,
          consentRef: consentRef,
        );
        if (invalid != null) return Err<VoiceProfile>(invalid);

        final now = clock.now().toUtc();
        final paramsJson = jsonEncode(params);
        await tx.execute(
          '''
INSERT INTO voice_profiles(
  ai_id,provider,model,voice_id,params_json,revision,
  pending_params_json,pending_revision,consent_ref,activated_at
) VALUES(?,?,?,?,?,?,NULL,NULL,?,?)
''',
          [
            ai.value,
            provider,
            model,
            voiceId,
            paramsJson,
            1,
            consentRef,
            now.toIso8601String(),
          ],
        );
        await tx.execute(
          'INSERT INTO voice_profile_revisions(ai_id,revision,params_json,created_at) VALUES(?,?,?,?)',
          [ai.value, 1, paramsJson, now.toIso8601String()],
        );
        await tx.execute(
          'INSERT OR IGNORE INTO voice_consents(ai_id,consent_ref,granted_by,granted_at,scope) VALUES(?,?,?,?,?)',
          [
            ai.value,
            consentRef,
            grantedBy.isEmpty ? 'unknown' : grantedBy,
            now.toIso8601String(),
            '本人或已授权声音；禁第三方、未成年人',
          ],
        );
        return Ok<VoiceProfile>(
          VoiceProfile(
            aiId: ai,
            provider: provider,
            model: model,
            voiceId: voiceId,
            params: _freeze(params),
            revision: 1,
            consentRef: consentRef,
            activatedAt: now,
          ),
        );
      });

  @override
  Future<Result<VoiceProfile>> get({required AiId ai}) async {
    final rows = await database.query(
      'SELECT * FROM voice_profiles WHERE ai_id=?',
      [ai.value],
    );
    if (rows.isEmpty) {
      return err<VoiceProfile>(FailureCode.notFound, '音色档案不存在');
    }
    return Ok<VoiceProfile>(_profileFromRow(rows.single));
  }

  @override
  Future<Result<VoiceProfile>> stageParams({
    required AiId ai,
    required Map<String, Object?> params,
  }) =>
      database.transaction((tx) async {
        final rows = await tx.query(
          'SELECT * FROM voice_profiles WHERE ai_id=?',
          [ai.value],
        );
        if (rows.isEmpty) {
          return err<VoiceProfile>(FailureCode.notFound, '音色档案不存在');
        }
        final profile = _profileFromRow(rows.single);
        final nextRevision = (profile.pendingRevision ?? profile.revision) + 1;
        await tx.execute(
          'UPDATE voice_profiles SET pending_params_json=?,pending_revision=? WHERE ai_id=?',
          [jsonEncode(params), nextRevision, ai.value],
        );
        return Ok<VoiceProfile>(
          profile.copyWith(
            pendingParams: _freeze(params),
            pendingRevision: nextRevision,
          ),
        );
      });

  @override
  Future<Result<VoiceProfile>> rollback({
    required AiId ai,
    required int revision,
  }) =>
      database.transaction((tx) async {
        final rows = await tx.query(
          'SELECT * FROM voice_profiles WHERE ai_id=?',
          [ai.value],
        );
        if (rows.isEmpty) {
          return err<VoiceProfile>(FailureCode.notFound, '音色档案不存在');
        }
        final target = await tx.query(
          'SELECT params_json FROM voice_profile_revisions WHERE ai_id=? AND revision=?',
          [ai.value, revision],
        );
        if (target.isEmpty) {
          return err<VoiceProfile>(FailureCode.notFound, '目标 revision 不存在');
        }
        final profile = _profileFromRow(rows.single);
        final nextRevision = (profile.pendingRevision ?? profile.revision) + 1;
        final targetJson = target.single['params_json']! as String;
        await tx.execute(
          'UPDATE voice_profiles SET pending_params_json=?,pending_revision=? WHERE ai_id=?',
          [targetJson, nextRevision, ai.value],
        );
        return Ok<VoiceProfile>(
          profile.copyWith(
            pendingParams: _decodeParams(targetJson),
            pendingRevision: nextRevision,
          ),
        );
      });

  @override
  Future<Result<VoiceProfile>> applyAtSentenceBoundary({
    required AiId ai,
  }) =>
      database.transaction((tx) async {
        final rows = await tx.query(
          'SELECT * FROM voice_profiles WHERE ai_id=?',
          [ai.value],
        );
        if (rows.isEmpty) {
          return err<VoiceProfile>(FailureCode.notFound, '音色档案不存在');
        }
        final profile = _profileFromRow(rows.single);
        final pendingParams = profile.pendingParams;
        final pendingRevision = profile.pendingRevision;
        if (pendingParams == null || pendingRevision == null) {
          return Ok<VoiceProfile>(profile);
        }
        final paramsJson = jsonEncode(pendingParams);
        final now = clock.now().toUtc().toIso8601String();
        await tx.execute(
          'UPDATE voice_profiles SET params_json=?,revision=?,pending_params_json=NULL,pending_revision=NULL WHERE ai_id=?',
          [paramsJson, pendingRevision, ai.value],
        );
        await tx.execute(
          'INSERT INTO voice_profile_revisions(ai_id,revision,params_json,created_at) VALUES(?,?,?,?)',
          [ai.value, pendingRevision, paramsJson, now],
        );
        return Ok<VoiceProfile>(
          profile.copyWith(
            params: _freeze(pendingParams),
            revision: pendingRevision,
            clearPending: true,
          ),
        );
      });

  @override
  Future<Result<List<VoiceRevision>>> history({required AiId ai}) async {
    final exists = await database.query(
      'SELECT 1 FROM voice_profiles WHERE ai_id=?',
      [ai.value],
    );
    if (exists.isEmpty) {
      return err<List<VoiceRevision>>(FailureCode.notFound, '音色档案不存在');
    }
    final rows = await database.query(
      'SELECT revision,params_json,created_at FROM voice_profile_revisions WHERE ai_id=? ORDER BY revision',
      [ai.value],
    );
    return Ok<List<VoiceRevision>>(
      List<VoiceRevision>.unmodifiable([
        for (final row in rows)
          VoiceRevision(
            revision: row['revision']! as int,
            params: _decodeParams(row['params_json']! as String),
            createdAt: DateTime.parse(row['created_at']! as String),
          ),
      ]),
    );
  }

  @override
  Future<Result<List<VoiceConsent>>> consents({required AiId ai}) async {
    final rows = await database.query(
      'SELECT consent_ref,granted_by,granted_at,scope FROM voice_consents WHERE ai_id=? ORDER BY granted_at',
      [ai.value],
    );
    return Ok<List<VoiceConsent>>(
      List<VoiceConsent>.unmodifiable([
        for (final row in rows)
          VoiceConsent(
            consentRef: row['consent_ref']! as String,
            aiId: ai,
            grantedBy: row['granted_by']! as String,
            grantedAt: DateTime.parse(row['granted_at']! as String),
            scope: row['scope']! as String,
          ),
      ]),
    );
  }

  @override
  Future<Result<bool>> delete({required AiId ai}) =>
      database.transaction((tx) async {
        final existing = await tx.query(
          'SELECT 1 FROM voice_profiles WHERE ai_id=?',
          [ai.value],
        );
        if (existing.isEmpty) {
          return err<bool>(FailureCode.notFound, '音色档案不存在');
        }
        // 只删档案与音频引用；同意记录保留（FR-31）。
        await tx.execute('DELETE FROM voice_profiles WHERE ai_id=?', [ai.value]);
        await tx.execute(
          'DELETE FROM voice_profile_revisions WHERE ai_id=?',
          [ai.value],
        );
        await tx.execute('DELETE FROM voice_samples WHERE ai_id=?', [ai.value]);
        return Ok<bool>(true);
      });

  @override
  Future<Result<String>> importSample({
    required AiId ai,
    required VoiceSampleMeta sample,
    required String consentRef,
  }) async {
    final failure = validateVoiceSample(sample, consentRef);
    if (failure != null) return Err<String>(failure);
    final now = clock.now().toUtc();
    final sampleId = 'sample-${now.microsecondsSinceEpoch}-${_sampleSeq++}';
    await database.transaction((tx) async {
      await tx.execute(
        'INSERT INTO voice_samples(sample_id,ai_id,consent_ref,recorded_at) VALUES(?,?,?,?)',
        [sampleId, ai.value, consentRef, now.toIso8601String()],
      );
      await tx.execute(
        'INSERT OR IGNORE INTO voice_consents(ai_id,consent_ref,granted_by,granted_at,scope) VALUES(?,?,?,?,?)',
        [
          ai.value,
          consentRef,
          'self',
          now.toIso8601String(),
          '本人或已授权声音；禁第三方、未成年人',
        ],
      );
    });
    return Ok<String>(sampleId);
  }

  VoiceProfile _profileFromRow(Map<String, Object?> row) {
    final pendingRevisionRaw = row['pending_revision'];
    final pendingParamsRaw = row['pending_params_json'];
    return VoiceProfile(
      aiId: AiId.parse(row['ai_id']! as String),
      provider: row['provider']! as String,
      model: row['model']! as String,
      voiceId: row['voice_id']! as String,
      params: _decodeParams(row['params_json']! as String),
      revision: row['revision']! as int,
      consentRef: row['consent_ref']! as String,
      activatedAt: DateTime.parse(row['activated_at']! as String),
      pendingRevision: pendingRevisionRaw is int ? pendingRevisionRaw : null,
      pendingParams: pendingParamsRaw is String
          ? _decodeParams(pendingParamsRaw)
          : null,
    );
  }

  Map<String, Object?> _decodeParams(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, Object?>) {
      return Map<String, Object?>.unmodifiable(decoded);
    }
    if (decoded is Map) {
      return Map<String, Object?>.unmodifiable(
        decoded.cast<String, Object?>(),
      );
    }
    throw FormatException('voice params 不是 JSON 对象', raw);
  }

  Map<String, Object?> _freeze(Map<String, Object?> params) =>
      Map<String, Object?>.unmodifiable(params);
}
