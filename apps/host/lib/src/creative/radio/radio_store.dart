/// CR-07 深夜电台的存储接口与内存实现。
///
/// 预生成 + 本地缓存语义由存储层承载：[RadioEpisode.offlineCacheKey] 非空即表示
/// 已缓存可离线播放，宿主重新装配后仍能取回（离线可听）。
/// 私有数据带 [RadioEpisode.ownerAccountId]，读取必须带调用者（FR-67）。
library;

import 'radio_models.dart';

/// 一期深夜电台。
class RadioEpisode {
  const RadioEpisode({
    required this.ownerAccountId,
    required this.aiId,
    required this.dateKey,
    required this.scheduledFor,
    required this.generatedAt,
    required this.script,
    required this.voiceId,
    required this.offlineCacheKey,
    required this.playableOffline,
  });

  final String ownerAccountId;
  final String aiId;

  /// 本地日界键（yyyy-mm-dd），标识"哪一晚的电台"。
  final String dateKey;

  /// 该期原定播放时刻（绝对，本地 23:00 折算）。
  final DateTime scheduledFor;
  final DateTime generatedAt;
  final RadioScript script;

  /// 音频所用音色，必须等于档案音色。
  final String voiceId;

  /// 离线缓存键；非空即可离线播放。
  final String offlineCacheKey;
  final bool playableOffline;

  Map<String, Object?> toPayload() => {
    'aiId': aiId,
    'dateKey': dateKey,
    'scheduledFor': scheduledFor.toIso8601String(),
    'generatedAt': generatedAt.toIso8601String(),
    'voiceId': voiceId,
    'offlineCacheKey': offlineCacheKey,
    'playableOffline': playableOffline,
    'script': script.toPayload(),
  };
}

/// 电台仓储。
abstract class RadioStore {
  Future<RadioEpisode?> find({
    required String ownerAccountId,
    required String aiId,
    required String dateKey,
  });

  Future<void> save(RadioEpisode episode);

  Future<List<RadioEpisode>> listByOwner(String ownerAccountId);
}

/// 内存实现。SQLite 实现由 M01 完成后补，并通过同一契约测试。
class InMemoryRadioStore implements RadioStore {
  final Map<String, RadioEpisode> _episodes = <String, RadioEpisode>{};

  String _key(String owner, String ai, String dateKey) =>
      '$owner\u0000$ai\u0000$dateKey';

  @override
  Future<RadioEpisode?> find({
    required String ownerAccountId,
    required String aiId,
    required String dateKey,
  }) async => _episodes[_key(ownerAccountId, aiId, dateKey)];

  @override
  Future<void> save(RadioEpisode episode) async {
    _episodes[_key(episode.ownerAccountId, episode.aiId, episode.dateKey)] =
        episode;
  }

  @override
  Future<List<RadioEpisode>> listByOwner(String ownerAccountId) async => [
    for (final episode in _episodes.values)
      if (episode.ownerAccountId == ownerAccountId) episode,
  ];
}
