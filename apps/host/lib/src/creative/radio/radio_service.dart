/// CR-07 深夜电台：宿主侧调度（默认每晚 23:00 本地）、预生成离线缓存、
/// 音色一致性校验与生成额度扣减。
///
/// 关键边界：
/// * 本地时区：按用户本地 23:00 折算绝对时刻（[UserTimeZone]）。
/// * 预生成：在 23:00 前 [RadioScheduleConfig.preGenerateLead] 起就生成并缓存，离线可听。
/// * 静默窗：CR-07 明确「本地播放不受静默窗限制」，因此本服务不接静默窗。
/// * 错过不补：超过 [RadioScheduleConfig.onTimeGrace] 才恢复的今晚不再补生成（B-4）。
/// * 音色一致：合成音频音色必须等于档案音色，否则拒绝（modelUnavailable）。
/// * 预算：生成前经 [CreativeBudgetGate] 预留；不足则跳过今晚。
library;

import 'package:jingyu_core/jingyu_core.dart';

import '../creative_budget.dart';
import '../creative_time.dart';
import 'radio_models.dart';
import 'radio_store.dart';

class RadioService {
  RadioService({
    required RadioStore store,
    required RadioScriptSource scriptSource,
    required VoiceSynthesizer voice,
    required Clock clock,
    required UserTimeZone timeZone,
    required RadioTargetProvider targetProvider,
    RadioScheduleConfig schedule = const RadioScheduleConfig(),
    CreativeBudgetGate budget = const AlwaysGrantBudgetGate(),
    this.generationEnabled = true,
  }) : _store = store,
       _scriptSource = scriptSource,
       _voice = voice,
       _clock = clock,
       _timeZone = timeZone,
       _targetProvider = targetProvider,
       _schedule = schedule,
       _budget = budget;

  final RadioStore _store;
  final RadioScriptSource _scriptSource;
  final VoiceSynthesizer _voice;
  final Clock _clock;
  final UserTimeZone _timeZone;
  final RadioTargetProvider _targetProvider;
  final RadioScheduleConfig _schedule;
  final CreativeBudgetGate _budget;

  /// False in default assembly until genuine audio and production gates exist.
  final bool generationEnabled;

  /// 处理一次调度 tick。返回本轮新生成的电台。
  ///
  /// 只考虑"今天"的 23:00 槽：宿主离线错过之后不会回头补昨晚的电台（B-4）。
  Future<List<RadioEpisode>> tick() async {
    if (!generationEnabled) return const [];
    final targets = await _targetProvider.targets();
    final nowInstant = _clock.now().toUtc();
    final nowWall = _timeZone.toLocalWall(nowInstant);
    final dateKey = dayKey(nowWall);
    final dueWall = _schedule.schedule.occurrenceOnDay(nowWall);
    final windowStart = _timeZone
        .toInstant(dueWall)
        .subtract(_schedule.preGenerateLead);
    final windowEnd = _timeZone.toInstant(dueWall).add(_schedule.onTimeGrace);
    if (nowInstant.isBefore(windowStart) || nowInstant.isAfter(windowEnd)) {
      return const [];
    }
    final generated = <RadioEpisode>[];
    for (final target in targets) {
      if (!target.enabled) continue;
      final existing = await _store.find(
        ownerAccountId: target.ownerAccountId,
        aiId: target.aiId,
        dateKey: dateKey,
      );
      if (existing != null) continue;
      final result = await _generateEpisode(target, nowWall);
      if (result.isOk) generated.add(result.value);
    }
    return generated;
  }

  /// 手动为某一天生成（用于测试或补生成入口）。预算与音色校验同样生效。
  Future<Result<RadioEpisode>> generateFor({
    required String ownerAccountId,
    required String aiId,
    required DateTime referenceInstant,
    required String profileVoiceId,
  }) {
    if (!generationEnabled) {
      return Future.value(
        err(FailureCode.modelUnavailable, 'radio generation unavailable'),
      );
    }
    final target = RadioTarget(
      ownerAccountId: ownerAccountId,
      aiId: aiId,
      profileVoiceId: profileVoiceId,
    );
    return _generateEpisode(target, _timeZone.toLocalWall(referenceInstant));
  }

  /// 读取某晚已缓存的电台（离线可听）。跨用户按不存在处理。
  Future<Result<RadioEpisode>> getEpisode({
    required String ownerAccountId,
    required String aiId,
    required String dateKey,
  }) async {
    final episode = await _store.find(
      ownerAccountId: ownerAccountId,
      aiId: aiId,
      dateKey: dateKey,
    );
    if (episode == null) return err(FailureCode.notFound, 'episode not found');
    return ok(episode);
  }

  Future<List<RadioEpisode>> listForOwner(String ownerAccountId) =>
      _store.listByOwner(ownerAccountId);

  Future<Result<RadioEpisode>> _generateEpisode(
    RadioTarget target,
    DateTime localDayWall,
  ) async {
    final dateKey = dayKey(localDayWall);
    final dueWall = _schedule.schedule.occurrenceOnDay(localDayWall);
    final scheduledFor = _timeZone.toInstant(dueWall);
    final generatedAt = _clock.now().toUtc();

    final granted = await _budget.tryReserve(
      ownerAccountId: target.ownerAccountId,
      aiId: target.aiId,
      tokens: _schedule.generationTokens,
    );
    if (!granted) {
      return err(FailureCode.budgetExhausted, 'radio budget exhausted');
    }

    final script = await _scriptSource.compose(
      ownerAccountId: target.ownerAccountId,
      aiId: target.aiId,
      dateKey: dateKey,
    );
    final audio = await _voice.synthesize(
      script: script.text,
      voiceId: target.profileVoiceId,
    );
    if (audio == null) {
      return err(FailureCode.modelUnavailable, 'tts unavailable');
    }
    if (audio.voiceId != target.profileVoiceId) {
      // CR-07「音色与档案一致」：音色不符不生成。
      return err(FailureCode.modelUnavailable, 'voice does not match profile');
    }

    final episode = RadioEpisode(
      ownerAccountId: target.ownerAccountId,
      aiId: target.aiId,
      dateKey: dateKey,
      scheduledFor: scheduledFor,
      generatedAt: generatedAt,
      script: script,
      voiceId: audio.voiceId,
      offlineCacheKey: audio.ref,
      playableOffline: audio.ref.isNotEmpty,
    );
    await _store.save(episode);
    return ok(episode);
  }
}
