/// CR-03 周报/年报的数据模型、授权范围与生成依赖接口。
///
/// 边界（docs/modules/M09-creative.md）：
/// * 只统计本人授权范围内的数据；越权 scope 一律不进入聚合。
/// * 分享图必须带水印标注（CR-03 验收）。
/// * 生成计入额度（由 [CreativeBudgetGate] 控制，见 service）。
library;

import '../creative_budget.dart';
import '../creative_time.dart' show LocalTime, SilentWindow, WeeklySchedule;

/// 报告类型。
enum ReportKind { weekly, annual }

/// 授权数据域。报告只统计 [ReportTarget.authorizedScopes] 内的活动。
enum CreativeScope { privateChat, groupChat, moments }

/// 活动种类，用于周报/年报聚合。
enum CreativeActivityKind {
  /// 共同话题（[CreativeActivity.label] 为话题标签）。
  topic,

  /// 完成的约定。
  agreementCompleted,

  /// 打卡（[CreativeActivity.value] > 0 记为当日打卡）。
  checkin,

  /// 心情（[CreativeActivity.value] 为当日心情分）。
  mood,

  /// 里程碑（[CreativeActivity.label] 为里程碑描述）。
  milestone,
}

/// 一条可汇总的活动。由 ai_core / brain 侧提供，宿主切片用内存假实现。
///
/// [dayKey] 为**用户本地**日界键（yyyy-mm-dd），聚合只按本地日切分。
class CreativeActivity {
  const CreativeActivity({
    required this.ownerAccountId,
    required this.aiId,
    required this.scope,
    required this.kind,
    required this.dayKey,
    this.label = '',
    this.value = 0,
  });

  final String ownerAccountId;
  final String aiId;
  final CreativeScope scope;
  final CreativeActivityKind kind;
  final String dayKey;
  final String label;
  final int value;
}

/// 活动来源接口。真实实现从消息/约定/心情数据中取已授权的活动。
abstract class CreativeActivitySource {
  Future<List<CreativeActivity>> collect({
    required String ownerAccountId,
    required String aiId,
    required String windowStartDay,
    required String windowEndDay,
  });
}

/// 内存假实现，便于单元/契约测试。
class InMemoryCreativeActivitySource implements CreativeActivitySource {
  InMemoryCreativeActivitySource([List<CreativeActivity> activities = const []])
    : _activities = [...activities];

  final List<CreativeActivity> _activities;

  void add(CreativeActivity activity) => _activities.add(activity);

  @override
  Future<List<CreativeActivity>> collect({
    required String ownerAccountId,
    required String aiId,
    required String windowStartDay,
    required String windowEndDay,
  }) async => [
    for (final activity in _activities)
      if (activity.ownerAccountId == ownerAccountId &&
          activity.aiId == aiId &&
          activity.dayKey.compareTo(windowStartDay) >= 0 &&
          activity.dayKey.compareTo(windowEndDay) <= 0)
        activity,
  ];
}

/// 话题计数。
class TopicCount {
  const TopicCount(this.label, this.count);

  final String label;
  final int count;

  Map<String, Object?> toPayload() => {'label': label, 'count': count};
}

/// 分享卡片：带水印标注（CR-03「分享图带水印标注」）。
class ShareCard {
  const ShareCard({
    required this.title,
    required this.lines,
    required this.watermark,
  });

  final String title;
  final List<String> lines;

  /// 非空水印，必须包含产品名与"生成"字样。
  final String watermark;

  Map<String, Object?> toPayload() => {
    'title': title,
    'lines': lines,
    'watermark': watermark,
  };
}

/// 生成的一封信的上下文（只含聚合后的、已授权的统计，不含原文）。
class ReportLetterContext {
  const ReportLetterContext({
    required this.kind,
    required this.periodKey,
    required this.commonTopics,
    required this.completedAgreements,
    required this.checkinDays,
  });

  final ReportKind kind;
  final String periodKey;
  final List<TopicCount> commonTopics;
  final int completedAgreements;
  final int checkinDays;
}

/// AI 手写一封信的依赖接口。真实实现走 M07 brain/模型；宿主切片默认用模板兜底。
abstract class ReportLetterWriter {
  Future<String> writeLetter(ReportLetterContext context);
}

/// 周报/年报结果。
class RelationshipReport {
  const RelationshipReport({
    required this.ownerAccountId,
    required this.aiId,
    required this.kind,
    required this.periodKey,
    required this.windowStartDay,
    required this.windowEndDay,
    required this.generatedAt,
    required this.commonTopics,
    required this.completedAgreements,
    required this.checkinDays,
    required this.moodCurve,
    required this.letter,
    required this.keywords,
    required this.milestones,
    required this.busiestDay,
    required this.sourceScopes,
  });

  final String ownerAccountId;
  final String aiId;
  final ReportKind kind;

  /// 周期键：周报为触发日本地日界键；年报为年份串。
  final String periodKey;
  final String windowStartDay;
  final String windowEndDay;

  /// 生成时刻（绝对）。
  final DateTime generatedAt;

  final List<TopicCount> commonTopics;
  final int completedAgreements;
  final int checkinDays;

  /// 本地日界键 → 当日心情均分。
  final Map<String, double> moodCurve;

  final String letter;

  // 年报字段（周报为空）。
  final List<String> keywords;
  final List<String> milestones;
  final String? busiestDay;

  /// 本次统计实际纳入的授权范围（回显，便于审计核对）。
  final Set<CreativeScope> sourceScopes;

  String get _kindLabel => kind == ReportKind.weekly ? '我们这一周' : '年度报告';

  /// 分享卡片：带水印。只放入聚合统计，不含原文。
  ShareCard get shareCard {
    final lines = <String>[
      if (commonTopics.isNotEmpty)
        '共同话题：${commonTopics.take(3).map((t) => t.label).join('、')}',
      '完成的约定：$completedAgreements',
      '打卡天数：$checkinDays',
      if (keywords.isNotEmpty) '年度关键词：${keywords.join('、')}',
      if (busiestDay != null) '最热闹的一天：$busiestDay',
    ];
    return ShareCard(
      title: '$_kindLabel · $periodKey',
      lines: lines,
      watermark: '由鲸言鲸语生成 · 仅统计已授权范围',
    );
  }

  Map<String, Object?> toPayload() => {
    'kind': kind.name,
    'periodKey': periodKey,
    'windowStartDay': windowStartDay,
    'windowEndDay': windowEndDay,
    'generatedAt': generatedAt.toIso8601String(),
    'commonTopics': [for (final topic in commonTopics) topic.toPayload()],
    'completedAgreements': completedAgreements,
    'checkinDays': checkinDays,
    'moodCurve': moodCurve,
    'letter': letter,
    'keywords': keywords,
    'milestones': milestones,
    'busiestDay': busiestDay,
    'sourceScopes': [for (final scope in sourceScopes) scope.name],
  };
}

/// 一个待调度的报告对象（某用户 + 某 AI）及其授权范围。
class ReportTarget {
  const ReportTarget({
    required this.ownerAccountId,
    required this.aiId,
    required this.authorizedScopes,
    this.enabled = true,
  });

  final String ownerAccountId;
  final String aiId;

  /// 用户明确授权的数据域；只有这些域的活动会被统计。
  final Set<CreativeScope> authorizedScopes;
  final bool enabled;
}

/// 目标来源接口（真实实现遍历所有启用的 owner/AI）。
abstract class ReportTargetProvider {
  Future<List<ReportTarget>> targets();
}

/// 内存假实现。
class InMemoryReportTargetProvider implements ReportTargetProvider {
  InMemoryReportTargetProvider([List<ReportTarget> targets = const []])
    : _targets = [...targets];

  final List<ReportTarget> _targets;

  void add(ReportTarget target) => _targets.add(target);

  @override
  Future<List<ReportTarget>> targets() async => [..._targets];
}

/// 报告调度配置。默认周报：每周日 21:30（v4.2 可调默认值）。
class ReportScheduleConfig {
  const ReportScheduleConfig({
    this.weeklySchedule = const WeeklySchedule(
      weekday: DateTime.sunday,
      time: LocalTime(21, 30),
    ),
    this.silentWindow = const SilentWindow(),
    this.onTimeGrace = const Duration(minutes: 15),
    this.generationTokens = 0,
  });

  final WeeklySchedule weeklySchedule;
  final SilentWindow silentWindow;

  /// 准时容忍窗：到点后超过此窗仍未见生成，判为"错过"（B-4 不补）。
  final Duration onTimeGrace;

  /// 单次生成计入的额度。
  final int generationTokens;
}

/// 预算闸门在报告模块的别名，避免上层直接依赖具体实现。
typedef ReportBudgetGate = CreativeBudgetGate;
