import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/creative/creative_budget.dart';
import 'package:jingyu_host/src/creative/creative_time.dart';
import 'package:jingyu_host/src/creative/radio/radio_models.dart';
import 'package:jingyu_host/src/creative/radio/radio_service.dart';
import 'package:jingyu_host/src/creative/radio/radio_store.dart';
import 'package:test/test.dart';

import 'creative_radio_store_contract.dart';

const UserTimeZone _zone = UserTimeZone(Duration(hours: 8));

/// 固定音色的 TTS 假适配器。[fixedVoiceId] 为空时回显请求音色（正常一致）。
class _FakeVoice implements VoiceSynthesizer {
  _FakeVoice({this.fixedVoiceId});

  final String? fixedVoiceId;
  int calls = 0;

  @override
  Future<RadioAudio?> synthesize({
    required String script,
    required String voiceId,
  }) async {
    calls++;
    return RadioAudio(
      voiceId: fixedVoiceId ?? voiceId,
      ref: 'cache-ref-$voiceId',
    );
  }
}

class _ScriptedBudget implements CreativeBudgetGate {
  _ScriptedBudget(this.results);

  final List<bool> results;
  int calls = 0;

  @override
  Future<bool> tryReserve({
    required String ownerAccountId,
    required String aiId,
    required int tokens,
  }) async {
    final index = calls < results.length ? calls : results.length - 1;
    calls++;
    return results[index];
  }
}

const _target = RadioTarget(
  ownerAccountId: 'u1',
  aiId: 'ai1',
  profileVoiceId: 'voice-1',
);

RadioService buildService({
  required Clock clock,
  required RadioStore store,
  required VoiceSynthesizer voice,
  required List<RadioTarget> targets,
  CreativeBudgetGate? budget,
  RadioScheduleConfig schedule = const RadioScheduleConfig(),
}) => RadioService(
  store: store,
  scriptSource: const TemplateRadioScriptSource(),
  voice: voice,
  clock: clock,
  timeZone: _zone,
  targetProvider: InMemoryRadioTargetProvider(targets),
  schedule: schedule,
  budget: budget ?? const AlwaysGrantBudgetGate(),
);

void main() {
  radioStoreContract('内存', InMemoryRadioStore.new);

  test('AC-27 CR-07 主路径：23:00 前预生成，离线缓存可听，音色一致', () async {
    // 本地 2026-11-16 22:50 = UTC 14:50。
    final clock = FakeClock(DateTime.utc(2026, 11, 16, 14, 50));
    final store = InMemoryRadioStore();
    final voice = _FakeVoice();
    final service = buildService(
      clock: clock,
      store: store,
      voice: voice,
      targets: const [_target],
    );

    final generated = await service.tick();
    expect(generated, hasLength(1));
    final episode = generated.single;
    expect(episode.dateKey, '2026-11-16');
    expect(episode.voiceId, 'voice-1');
    expect(episode.playableOffline, isTrue);
    expect(episode.offlineCacheKey, isNotEmpty);
    expect(episode.script.text, isNotEmpty);
    expect(voice.calls, 1);

    // 模拟宿主重启：用同一 store 新建服务，仍能取回离线缓存的电台。
    final restarted = buildService(
      clock: clock,
      store: store,
      voice: _FakeVoice(),
      targets: const [_target],
    );
    final cached = await restarted.getEpisode(
      ownerAccountId: 'u1',
      aiId: 'ai1',
      dateKey: '2026-11-16',
    );
    expect(cached.isOk, isTrue);
    expect(cached.value.playableOffline, isTrue);

    // 跨用户读不到（FR-67）。
    final foreign = await restarted.getEpisode(
      ownerAccountId: 'u2',
      aiId: 'ai1',
      dateKey: '2026-11-16',
    );
    expect(foreign.isErr, isTrue);
    expect(foreign.failureOrNull!.code, FailureCode.notFound);
  });

  test('B-4 错过不补：凌晨才恢复不补昨晚，下一晚正常生成', () async {
    // 本地 2026-11-17 01:00 = UTC 2026-11-16 17:00，已错过 11-16 的 23:00。
    final clock = FakeClock(DateTime.utc(2026, 11, 16, 17, 0));
    final store = InMemoryRadioStore();
    final service = buildService(
      clock: clock,
      store: store,
      voice: _FakeVoice(),
      targets: const [_target],
    );

    expect(await service.tick(), isEmpty);
    final missed = await service.getEpisode(
      ownerAccountId: 'u1',
      aiId: 'ai1',
      dateKey: '2026-11-16',
    );
    expect(missed.isErr, isTrue);

    // 次晚 22:50 正常预生成 11-17 的一期，且没有补 11-16。
    clock.set(DateTime.utc(2026, 11, 17, 14, 50));
    final generated = await service.tick();
    expect(generated.single.dateKey, '2026-11-17');
    final yesterday = await service.getEpisode(
      ownerAccountId: 'u1',
      aiId: 'ai1',
      dateKey: '2026-11-16',
    );
    expect(yesterday.isErr, isTrue);
  });

  test('CR-07 静默窗内仍生成：本地播放不受静默窗限制', () async {
    // 本地 2026-11-16 23:10（落在默认静默窗 23:00–08:00 内）＝ UTC 15:10。
    final clock = FakeClock(DateTime.utc(2026, 11, 16, 15, 10));
    final service = buildService(
      clock: clock,
      store: InMemoryRadioStore(),
      voice: _FakeVoice(),
      targets: const [_target],
    );
    final generated = await service.tick();
    expect(generated, hasLength(1));
    expect(generated.single.dateKey, '2026-11-16');
  });

  test('边界：音色与档案不一致则拒绝生成', () async {
    final clock = FakeClock(DateTime.utc(2026, 11, 16, 14, 50));
    final store = InMemoryRadioStore();
    // TTS 固定返回 voice-1，但档案音色要求 voice-2。
    final service = buildService(
      clock: clock,
      store: store,
      voice: _FakeVoice(fixedVoiceId: 'voice-1'),
      targets: const [_target],
    );
    final result = await service.generateFor(
      ownerAccountId: 'u1',
      aiId: 'ai1',
      referenceInstant: clock.now(),
      profileVoiceId: 'voice-2',
    );
    expect(result.isErr, isTrue);
    expect(result.failureOrNull!.code, FailureCode.modelUnavailable);
    expect(await store.listByOwner('u1'), isEmpty);
  });

  test('预算边界：额度不足则跳过当晚', () async {
    final clock = FakeClock(DateTime.utc(2026, 11, 16, 14, 50));
    final store = InMemoryRadioStore();
    final budget = _ScriptedBudget([false]);
    final service = buildService(
      clock: clock,
      store: store,
      voice: _FakeVoice(),
      targets: const [_target],
      budget: budget,
      schedule: const RadioScheduleConfig(generationTokens: 100),
    );
    expect(await service.tick(), isEmpty);
    expect(await store.listByOwner('u1'), isEmpty);
    expect(budget.calls, greaterThan(0));
  });
}
