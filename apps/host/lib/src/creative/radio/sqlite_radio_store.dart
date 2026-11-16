/// [RadioStore] 的 SQLite 实现。
///
/// 与 [InMemoryRadioStore] 共用 `test/creative_radio_store_contract.dart` 契约测试。
/// 私有数据按 owner_account_id 过滤（FR-67 / NFR-09）。
/// 离线缓存语义：offline_cache_key 非空 + playable_offline=1 表示可离线播放。
library;

import 'dart:convert';

import '../../storage/database.dart';
import 'radio_models.dart';
import 'radio_store.dart';

final class SqliteRadioStore implements RadioStore {
  SqliteRadioStore({required this.database});

  final Database database;

  static const String _columns =
      'owner_account_id, ai_id, date_key, scheduled_for, generated_at, '
      'script_json, voice_id, offline_cache_key, playable_offline';

  @override
  Future<RadioEpisode?> find({
    required String ownerAccountId,
    required String aiId,
    required String dateKey,
  }) async {
    final rows = await database.query(
      'SELECT $_columns FROM creative_radio_episodes '
      'WHERE owner_account_id = ? AND ai_id = ? AND date_key = ?',
      [ownerAccountId, aiId, dateKey],
    );
    return rows.isEmpty ? null : _fromRow(rows.single);
  }

  @override
  Future<void> save(RadioEpisode episode) async {
    await database.execute(
      '''
INSERT INTO creative_radio_episodes(
  owner_account_id, ai_id, date_key, scheduled_for, generated_at,
  script_json, voice_id, offline_cache_key, playable_offline
) VALUES(?,?,?,?,?,?,?,?,?)
ON CONFLICT(owner_account_id, ai_id, date_key) DO UPDATE SET
  scheduled_for = excluded.scheduled_for,
  generated_at = excluded.generated_at,
  script_json = excluded.script_json,
  voice_id = excluded.voice_id,
  offline_cache_key = excluded.offline_cache_key,
  playable_offline = excluded.playable_offline
''',
      [
        episode.ownerAccountId,
        episode.aiId,
        episode.dateKey,
        episode.scheduledFor.toUtc().toIso8601String(),
        episode.generatedAt.toUtc().toIso8601String(),
        jsonEncode(episode.script.toJson()),
        episode.voiceId,
        episode.offlineCacheKey,
        episode.playableOffline ? 1 : 0,
      ],
    );
  }

  @override
  Future<List<RadioEpisode>> listByOwner(String ownerAccountId) async {
    final rows = await database.query(
      'SELECT $_columns FROM creative_radio_episodes WHERE owner_account_id = ? '
      'ORDER BY date_key',
      [ownerAccountId],
    );
    return [for (final row in rows) _fromRow(row)];
  }

  RadioEpisode _fromRow(Map<String, Object?> row) {
    final rawScript = row['script_json'] as String;
    return RadioEpisode(
      ownerAccountId: row['owner_account_id'] as String,
      aiId: row['ai_id'] as String,
      dateKey: row['date_key'] as String,
      scheduledFor: DateTime.parse(row['scheduled_for'] as String),
      generatedAt: DateTime.parse(row['generated_at'] as String),
      script: RadioScript.fromJson(
        (jsonDecode(rawScript) as Map).cast<String, Object?>(),
      ),
      voiceId: row['voice_id'] as String,
      offlineCacheKey: row['offline_cache_key'] as String,
      playableOffline: (row['playable_offline'] as int) == 1,
    );
  }
}
