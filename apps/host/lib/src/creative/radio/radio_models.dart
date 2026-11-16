/// CR-07 深夜电台的数据模型与生成依赖接口。
///
/// 边界（docs/modules/M09-creative.md）：
/// * 默认每晚 23:00（用户本地时区），预生成可离线听。
/// * 本地播放不受静默窗限制（[RadioScheduleConfig] 不接静默窗）。
/// * 音色必须与该 AI 档案一致（生成时校验 [RadioAudio.voiceId]）。
/// * 生成计入额度。
library;

import '../creative_time.dart' show DailySchedule, LocalTime;

/// 电台片段：日记朗读 / 安慰语 / 白噪音脚本。
class RadioSegment {
  const RadioSegment({required this.kind, required this.text});

  final String kind;
  final String text;

  Map<String, Object?> toPayload() => {'kind': kind, 'text': text};
}

/// 一期电台的朗读脚本。
class RadioScript {
  const RadioScript(this.segments);

  final List<RadioSegment> segments;

  String get text => segments.map((segment) => segment.text).join('\n');

  Map<String, Object?> toPayload() => {
    'text': text,
    'segments': [for (final segment in segments) segment.toPayload()],
  };

  /// 持久化序列化（只存片段，不存拼接后的 text，避免冗余）。
  Map<String, Object?> toJson() => {
    'segments': [for (final segment in segments) segment.toPayload()],
  };

  /// 从持久化 JSON 还原。
  factory RadioScript.fromJson(Map<String, Object?> json) => RadioScript([
    for (final segment in (json['segments'] as List? ?? const []))
      RadioSegment(
        kind: (segment as Map)['kind'] as String,
        text: segment['text'] as String,
      ),
  ]);
}

/// 脚本来源接口。真实实现取 AI 日记/安慰语/白噪音，宿主切片用模板假实现。
abstract class RadioScriptSource {
  Future<RadioScript> compose({
    required String ownerAccountId,
    required String aiId,
    required String dateKey,
  });
}

/// 确定性模板实现：用于没有 M06 日记数据时的降级，内容不含隐私正文。
class TemplateRadioScriptSource implements RadioScriptSource {
  const TemplateRadioScriptSource();

  @override
  Future<RadioScript> compose({
    required String ownerAccountId,
    required String aiId,
    required String dateKey,
  }) async => const RadioScript([
    RadioSegment(kind: 'diary', text: '今天也想和你说说话。'),
    RadioSegment(kind: 'comfort', text: '慢慢呼吸，把今天放下来。'),
    RadioSegment(kind: 'whiteNoise', text: '（海浪声，缓缓）'),
  ]);
}

/// 合成出的音频引用。[voiceId] 必须等于该 AI 档案音色，否则拒绝。
class RadioAudio {
  const RadioAudio({required this.voiceId, required this.ref});

  final String voiceId;
  final String ref;
}

/// TTS 合成接口。真实实现走 M08 voice；宿主切片用可控假适配器。
abstract class VoiceSynthesizer {
  Future<RadioAudio?> synthesize({
    required String script,
    required String voiceId,
  });
}

/// 一个待调度的电台对象（某用户 + 某 AI）及其档案音色。
class RadioTarget {
  const RadioTarget({
    required this.ownerAccountId,
    required this.aiId,
    required this.profileVoiceId,
    this.enabled = true,
  });

  final String ownerAccountId;
  final String aiId;

  /// 该 AI 档案的音色 id（与生成的音频必须一致）。
  final String profileVoiceId;
  final bool enabled;
}

/// 目标来源接口（真实实现遍历所有启用 owner/AI）。
abstract class RadioTargetProvider {
  Future<List<RadioTarget>> targets();
}

/// 内存假实现。
class InMemoryRadioTargetProvider implements RadioTargetProvider {
  InMemoryRadioTargetProvider([List<RadioTarget> targets = const []])
    : _targets = [...targets];

  final List<RadioTarget> _targets;

  void add(RadioTarget target) => _targets.add(target);

  @override
  Future<List<RadioTarget>> targets() async => [..._targets];
}

/// 电台调度配置。默认每晚 23:00（v4.2 可调默认值）。
class RadioScheduleConfig {
  const RadioScheduleConfig({
    this.schedule = const DailySchedule(time: LocalTime(23, 0)),
    this.preGenerateLead = const Duration(minutes: 15),
    this.onTimeGrace = const Duration(minutes: 30),
    this.generationTokens = 0,
  });

  final DailySchedule schedule;

  /// 提前生成量：在 23:00 前这么久就开始预生成，保证离线可听。
  final Duration preGenerateLead;

  /// 到点后的容忍窗：超过即判为错过（B-4 不补）。
  final Duration onTimeGrace;

  final int generationTokens;
}
