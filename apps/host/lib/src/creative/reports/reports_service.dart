/// CR-03 关系周报/年度报告：宿主侧调度、授权范围过滤、聚合与分享水印。
///
/// 关键边界：
/// * 时区：全部按用户本地时区（[UserTimeZone]）判定"周日 21:30"。
/// * 静默窗：触发点若落在静默窗内，顺延到窗结束（B-4）。
/// * 错过不补：宿主恢复时若已明显错过触发点，只记录 missed，不再生成（B-4）。
/// * 授权范围：只聚合 [ReportTarget.authorizedScopes] 内、且 owner/ai 匹配的活动。
/// * 预算：生成前经 [CreativeBudgetGate] 预留；B4 超支时顺延到次日再试。
/// * 标注：分享卡片带水印。
library;

import 'package:jingyu_core/jingyu_core.dart';

import '../creative_budget.dart';
import '../creative_time.dart';
import 'reports_models.dart';
import 'reports_store.dart';

class ReportsService {
  ReportsService({
    required ReportsStore store,
    required CreativeActivitySource activitySource,
    required Clock clock,
    required UserTimeZone timeZone,
    required ReportTargetProvider targetProvider,
    ReportScheduleConfig schedule = const ReportScheduleConfig(),
    CreativeBudgetGate budget = const AlwaysGrantBudgetGate(),
    ReportLetterWriter? letterWriter,
  }) : _store = store,
       _activitySource = activitySource,
       _clock = clock,
       _timeZone = timeZone,
       _targetProvider = targetProvider,
       _schedule = schedule,
       _budget = budget,
       _letterWriter = letterWriter;

  final ReportsStore _store;
  final CreativeActivitySource _activitySource;
  final Clock _clock;
  final UserTimeZone _timeZone;
  final ReportTargetProvider _targetProvider;
  final ReportScheduleConfig _schedule;
  final CreativeBudgetGate _budget;
  final ReportLetterWriter? _letterWriter;

  /// 处理一次调度 tick（后台定时器或测试驱动）。返回本轮发生状态变化的记录。
  Future<List<ReportRecord>> tick() async {
    final targets = await _targetProvider.targets();
    final nowInstant = _clock.now().toUtc();
    final nowWall = _timeZone.toLocalWall(nowInstant);
    final changed = <ReportRecord>[];
    for (final target in targets) {
      if (!target.enabled) continue;
      final record = await _processWeeklyTarget(target, nowInstant, nowWall);
      if (record != null) changed.add(record);
    }
    return changed;
  }

  Future<ReportRecord?> _processWeeklyTarget(
    ReportTarget target,
    DateTime nowInstant,
    DateTime nowWall,
  ) async {
    final occurrenceWall = _schedule.weeklySchedule.lastOccurrenceOnOrBefore(
      nowWall,
    );
    final periodKey = dayKey(occurrenceWall);
    final existing = await _store.find(
      ownerAccountId: target.ownerAccountId,
      aiId: target.aiId,
      kind: ReportKind.weekly,
      periodKey: periodKey,
    );

    if (existing != null) {
      if (existing.status == ReportStatus.generated ||
          existing.status == ReportStatus.missed) {
        return null;
      }
      // deferred：等到 deferredTo 后再试。
      final deferredTo = existing.deferredTo;
      if (deferredTo != null && nowInstant.isBefore(deferredTo)) return null;
      final granted = await _reserve(target);
      if (!granted) {
        final bumped = existing.copyWith(
          updatedAt: nowInstant,
          deferredTo: nowInstant.add(const Duration(days: 1)),
        );
        await _store.upsert(bumped);
        return bumped;
      }
      final report = await _buildWeekly(target, occurrenceWall, nowInstant);
      final record = ReportRecord(
        ownerAccountId: target.ownerAccountId,
        aiId: target.aiId,
        kind: ReportKind.weekly,
        periodKey: periodKey,
        status: ReportStatus.generated,
        updatedAt: nowInstant,
        report: report,
      );
      await _store.upsert(record);
      return record;
    }

    final outcome = evaluateSlot(
      occurrenceWall: occurrenceWall,
      nowWall: nowWall,
      silentWindow: _schedule.silentWindow,
      onTimeGrace: _schedule.onTimeGrace,
      timeZone: _timeZone,
    );
    if (outcome == SlotOutcome.notDue) return null;
    if (outcome == SlotOutcome.missed) {
      final record = ReportRecord(
        ownerAccountId: target.ownerAccountId,
        aiId: target.aiId,
        kind: ReportKind.weekly,
        periodKey: periodKey,
        status: ReportStatus.missed,
        updatedAt: nowInstant,
      );
      await _store.upsert(record);
      return record;
    }
    // due now
    final granted = await _reserve(target);
    if (!granted) {
      final record = ReportRecord(
        ownerAccountId: target.ownerAccountId,
        aiId: target.aiId,
        kind: ReportKind.weekly,
        periodKey: periodKey,
        status: ReportStatus.deferred,
        updatedAt: nowInstant,
        deferredTo: nowInstant.add(const Duration(days: 1)),
      );
      await _store.upsert(record);
      return record;
    }
    final report = await _buildWeekly(target, occurrenceWall, nowInstant);
    final record = ReportRecord(
      ownerAccountId: target.ownerAccountId,
      aiId: target.aiId,
      kind: ReportKind.weekly,
      periodKey: periodKey,
      status: ReportStatus.generated,
      updatedAt: nowInstant,
      report: report,
    );
    await _store.upsert(record);
    return record;
  }

  Future<bool> _reserve(ReportTarget target) => _budget.tryReserve(
    ownerAccountId: target.ownerAccountId,
    aiId: target.aiId,
    tokens: _schedule.generationTokens,
  );

  Future<RelationshipReport> _buildWeekly(
    ReportTarget target,
    DateTime occurrenceWall,
    DateTime generatedAt,
  ) async {
    final windowStartDay = weekStartDayKey(occurrenceWall);
    final windowEndDay = dayKey(occurrenceWall);
    final activities = await _activitySource.collect(
      ownerAccountId: target.ownerAccountId,
      aiId: target.aiId,
      windowStartDay: windowStartDay,
      windowEndDay: windowEndDay,
    );
    return _aggregate(
      kind: ReportKind.weekly,
      target: target,
      periodKey: windowEndDay,
      windowStartDay: windowStartDay,
      windowEndDay: windowEndDay,
      activities: activities,
      generatedAt: generatedAt,
    );
  }

  /// 生成某年的年度报告（年度 Wrapped）。只统计授权范围。
  Future<Result<RelationshipReport>> generateAnnual({
    required String ownerAccountId,
    required String aiId,
    required int year,
    required Set<CreativeScope> authorizedScopes,
  }) async {
    final target = ReportTarget(
      ownerAccountId: ownerAccountId,
      aiId: aiId,
      authorizedScopes: authorizedScopes,
    );
    final nowInstant = _clock.now().toUtc();
    final periodKey = year.toString().padLeft(4, '0');
    final windowStartDay = '$periodKey-01-01';
    final windowEndDay = '$periodKey-12-31';
    final granted = await _reserve(target);
    if (!granted) {
      return err(FailureCode.budgetExhausted, 'report budget exhausted');
    }
    final activities = await _activitySource.collect(
      ownerAccountId: ownerAccountId,
      aiId: aiId,
      windowStartDay: windowStartDay,
      windowEndDay: windowEndDay,
    );
    final report = await _aggregate(
      kind: ReportKind.annual,
      target: target,
      periodKey: periodKey,
      windowStartDay: windowStartDay,
      windowEndDay: windowEndDay,
      activities: activities,
      generatedAt: nowInstant,
    );
    await _store.upsert(
      ReportRecord(
        ownerAccountId: ownerAccountId,
        aiId: aiId,
        kind: ReportKind.annual,
        periodKey: periodKey,
        status: ReportStatus.generated,
        updatedAt: nowInstant,
        report: report,
      ),
    );
    return ok(report);
  }

  /// 读取已生成的报告。跨用户查询一律按不存在处理（防探测）。
  Future<Result<RelationshipReport>> getReport({
    required String ownerAccountId,
    required String aiId,
    required ReportKind kind,
    required String periodKey,
  }) async {
    final record = await _store.find(
      ownerAccountId: ownerAccountId,
      aiId: aiId,
      kind: kind,
      periodKey: periodKey,
    );
    final report = record?.report;
    if (report == null) {
      return err(FailureCode.notFound, 'report not found');
    }
    return ok(report);
  }

  /// 某用户的全部报告记录（跨用户不可见）。
  Future<List<ReportRecord>> listForOwner(String ownerAccountId) =>
      _store.listByOwner(ownerAccountId);

  Future<RelationshipReport> _aggregate({
    required ReportKind kind,
    required ReportTarget target,
    required String periodKey,
    required String windowStartDay,
    required String windowEndDay,
    required List<CreativeActivity> activities,
    required DateTime generatedAt,
  }) async {
    // 只统计授权范围：owner/ai 匹配 + scope 命中授权 + 本地日界在窗口内。
    final scoped = <CreativeActivity>[
      for (final activity in activities)
        if (activity.ownerAccountId == target.ownerAccountId &&
            activity.aiId == target.aiId &&
            target.authorizedScopes.contains(activity.scope) &&
            activity.dayKey.compareTo(windowStartDay) >= 0 &&
            activity.dayKey.compareTo(windowEndDay) <= 0)
          activity,
    ];

    final topicCounts = <String, int>{};
    final moodSum = <String, int>{};
    final moodSeen = <String, int>{};
    final checkinDays = <String>{};
    final milestoneLines = <String>[];
    final dayActivity = <String, int>{};
    var completedAgreements = 0;

    for (final activity in scoped) {
      dayActivity.update(
        activity.dayKey,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      switch (activity.kind) {
        case CreativeActivityKind.topic:
          final amount = activity.value > 0 ? activity.value : 1;
          topicCounts.update(
            activity.label,
            (value) => value + amount,
            ifAbsent: () => amount,
          );
        case CreativeActivityKind.agreementCompleted:
          completedAgreements += activity.value > 0 ? activity.value : 1;
        case CreativeActivityKind.checkin:
          if (activity.value > 0 || activity.label.isNotEmpty) {
            checkinDays.add(activity.dayKey);
          }
        case CreativeActivityKind.mood:
          moodSum.update(
            activity.dayKey,
            (value) => value + activity.value,
            ifAbsent: () => activity.value,
          );
          moodSeen.update(
            activity.dayKey,
            (value) => value + 1,
            ifAbsent: () => 1,
          );
        case CreativeActivityKind.milestone:
          milestoneLines.add('${activity.dayKey} ${activity.label}'.trim());
      }
    }

    final topics = topicCounts.entries
        .map((entry) => TopicCount(entry.key, entry.value))
        .toList()
      ..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : a.label.compareTo(b.label);
      });
    final commonTopics = topics.take(5).toList();

    final moodDays = moodSum.keys.toList()..sort();
    final moodCurve = <String, double>{
      for (final day in moodDays)
        day: moodSum[day]! / (moodSeen[day] ?? 1),
    };

    final busiestDay = _busiestDay(dayActivity);
    final keywords = kind == ReportKind.annual
        ? topics.take(3).map((topic) => topic.label).toList()
        : const <String>[];
    final milestones = kind == ReportKind.annual
        ? (milestoneLines..sort())
        : const <String>[];

    final context = ReportLetterContext(
      kind: kind,
      periodKey: periodKey,
      commonTopics: commonTopics,
      completedAgreements: completedAgreements,
      checkinDays: checkinDays.length,
    );
    final letter = _letterWriter != null
        ? await _letterWriter.writeLetter(context)
        : _defaultLetter(context);

    return RelationshipReport(
      ownerAccountId: target.ownerAccountId,
      aiId: target.aiId,
      kind: kind,
      periodKey: periodKey,
      windowStartDay: windowStartDay,
      windowEndDay: windowEndDay,
      generatedAt: generatedAt,
      commonTopics: commonTopics,
      completedAgreements: completedAgreements,
      checkinDays: checkinDays.length,
      moodCurve: moodCurve,
      letter: letter,
      keywords: keywords,
      milestones: milestones,
      busiestDay: kind == ReportKind.annual ? busiestDay : null,
      sourceScopes: {...target.authorizedScopes},
    );
  }

  String? _busiestDay(Map<String, int> dayActivity) {
    if (dayActivity.isEmpty) return null;
    final days = dayActivity.keys.toList()..sort();
    String? busiest;
    var best = -1;
    for (final day in days) {
      final count = dayActivity[day]!;
      if (count > best) {
        best = count;
        busiest = day;
      }
    }
    return busiest;
  }

  String _defaultLetter(ReportLetterContext context) {
    final topics = context.commonTopics;
    if (topics.isEmpty) {
      return '这一段我们安安静静，也是一起走过的日子。';
    }
    final lead = topics.first.label;
    final scopeLabel = context.kind == ReportKind.weekly ? '这周' : '这一年';
    return '$scopeLabel我们聊了很多关于「$lead」的事，'
        '一起完成了 ${context.completedAgreements} 个约定。'
        '想和你继续这样走下去。';
  }
}
