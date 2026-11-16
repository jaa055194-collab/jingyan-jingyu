import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/creative/creative_budget.dart';
import 'package:jingyu_host/src/creative/creative_time.dart';
import 'package:jingyu_host/src/creative/reports/reports_models.dart';
import 'package:jingyu_host/src/creative/reports/reports_service.dart';
import 'package:jingyu_host/src/creative/reports/reports_store.dart';
import 'package:test/test.dart';

import 'creative_reports_store_contract.dart';

const UserTimeZone _zone = UserTimeZone(Duration(hours: 8));

CreativeActivity act({
  String owner = 'u1',
  String ai = 'ai1',
  CreativeScope scope = CreativeScope.privateChat,
  required CreativeActivityKind kind,
  required String dayKey,
  String label = '',
  int value = 0,
}) => CreativeActivity(
  ownerAccountId: owner,
  aiId: ai,
  scope: scope,
  kind: kind,
  dayKey: dayKey,
  label: label,
  value: value,
);

ReportsService buildService({
  required FakeClock clock,
  required InMemoryCreativeActivitySource source,
  required InMemoryReportsStore store,
  required List<ReportTarget> targets,
  CreativeBudgetGate? budget,
  ReportScheduleConfig schedule = const ReportScheduleConfig(),
}) => ReportsService(
  store: store,
  activitySource: source,
  clock: clock,
  timeZone: _zone,
  targetProvider: InMemoryReportTargetProvider(targets),
  schedule: schedule,
  budget: budget ?? const AlwaysGrantBudgetGate(),
);

/// 可编排的预算闸门：按顺序返回给定的放行结果。
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

void main() {
  reportsStoreContract('内存', InMemoryReportsStore.new);

  // 2026-11-15 是周日；本地 21:31 = UTC 13:31。
  const weeklyTarget = ReportTarget(
    ownerAccountId: 'u1',
    aiId: 'ai1',
    authorizedScopes: {CreativeScope.privateChat},
  );

  test('AC-27 CR-03 主路径：周日 21:30（本地）按期生成周报', () async {
    final clock = FakeClock(DateTime.utc(2026, 11, 15, 13, 31)); // 周日 21:31
    final source = InMemoryCreativeActivitySource([
      act(
        kind: CreativeActivityKind.topic,
        dayKey: '2026-11-15',
        label: '旅行',
        value: 3,
      ),
      act(
        kind: CreativeActivityKind.topic,
        dayKey: '2026-11-10',
        label: '电影',
        value: 1,
      ),
      act(
        kind: CreativeActivityKind.agreementCompleted,
        dayKey: '2026-11-12',
        value: 1,
      ),
      act(kind: CreativeActivityKind.checkin, dayKey: '2026-11-09', value: 1),
      act(kind: CreativeActivityKind.mood, dayKey: '2026-11-11', value: 4),
    ]);
    final store = InMemoryReportsStore();
    final service = buildService(
      clock: clock,
      source: source,
      store: store,
      targets: const [weeklyTarget],
    );

    final changed = await service.tick();
    expect(changed, hasLength(1));
    expect(changed.single.status, ReportStatus.generated);
    expect(changed.single.periodKey, '2026-11-15');

    final result = await service.getReport(
      ownerAccountId: 'u1',
      aiId: 'ai1',
      kind: ReportKind.weekly,
      periodKey: '2026-11-15',
    );
    expect(result.isOk, isTrue);
    final report = result.value;
    expect(report.commonTopics.first.label, '旅行');
    expect(report.commonTopics.first.count, 3);
    expect(report.completedAgreements, 1);
    expect(report.checkinDays, 1);
    expect(report.moodCurve['2026-11-11'], 4);
    expect(report.letter, isNotEmpty);
    // 生成计入额度后，再 tick 不重复生成。
    expect(await service.tick(), isEmpty);
  });

  test('AC-27 CR-03 边界：只统计授权范围，分享图带水印', () async {
    final clock = FakeClock(DateTime.utc(2026, 11, 15, 13, 31));
    final source = InMemoryCreativeActivitySource([
      act(
        kind: CreativeActivityKind.topic,
        dayKey: '2026-11-15',
        label: '旅行',
      ),
      // 未授权的群聊话题，必须被过滤。
      act(
        scope: CreativeScope.groupChat,
        kind: CreativeActivityKind.topic,
        dayKey: '2026-11-14',
        label: '八卦',
      ),
      // 别人的数据，也不得混入。
      act(
        owner: 'u2',
        kind: CreativeActivityKind.topic,
        dayKey: '2026-11-14',
        label: '越权',
      ),
    ]);
    final service = buildService(
      clock: clock,
      source: source,
      store: InMemoryReportsStore(),
      targets: const [weeklyTarget],
    );
    await service.tick();
    final report =
        (await service.getReport(
          ownerAccountId: 'u1',
          aiId: 'ai1',
          kind: ReportKind.weekly,
          periodKey: '2026-11-15',
        )).value;

    final labels = report.commonTopics.map((t) => t.label).toSet();
    expect(labels, contains('旅行'));
    expect(labels, isNot(contains('八卦')));
    expect(labels, isNot(contains('越权')));
    expect(report.sourceScopes, {CreativeScope.privateChat});

    final card = report.shareCard;
    expect(card.watermark, isNotEmpty);
    expect(card.watermark, contains('鲸言鲸语'));
    expect(card.watermark, contains('生成'));
  });

  test('B-4 错过不补：周日离线、周一才恢复则不补生成', () async {
    // 周一 12:00 本地 = UTC 04:00。宿主没在周日 21:30 运行。
    final clock = FakeClock(DateTime.utc(2026, 11, 16, 4, 0));
    final source = InMemoryCreativeActivitySource([
      act(kind: CreativeActivityKind.topic, dayKey: '2026-11-15', label: '旅行'),
    ]);
    final store = InMemoryReportsStore();
    final service = buildService(
      clock: clock,
      source: source,
      store: store,
      targets: const [weeklyTarget],
    );

    final changed = await service.tick();
    expect(changed.single.status, ReportStatus.missed);
    expect(changed.single.periodKey, '2026-11-15');
    final report = await service.getReport(
      ownerAccountId: 'u1',
      aiId: 'ai1',
      kind: ReportKind.weekly,
      periodKey: '2026-11-15',
    );
    expect(report.isErr, isTrue);
    final records = await service.listForOwner('u1');
    expect(records.where((r) => r.status == ReportStatus.generated), isEmpty);
  });

  test('B-4 静默窗顺延：触发点落在静默窗则顺延到窗结束', () async {
    // 自定义静默窗 20:00–09:00，覆盖周日 21:30。
    const config = ReportScheduleConfig(
      silentWindow: SilentWindow(
        start: LocalTime(20, 0),
        end: LocalTime(9, 0),
      ),
    );
    final clock = FakeClock(DateTime.utc(2026, 11, 15, 13, 45)); // 周日 21:45
    final source = InMemoryCreativeActivitySource([
      act(kind: CreativeActivityKind.topic, dayKey: '2026-11-15', label: '旅行'),
    ]);
    final store = InMemoryReportsStore();
    final service = buildService(
      clock: clock,
      source: source,
      store: store,
      targets: const [weeklyTarget],
      schedule: config,
    );

    // 21:45 仍在静默窗，顺延到次日 09:00，尚未到点。
    expect(await service.tick(), isEmpty);
    // 次日 09:05 本地 = UTC 01:05，静默窗结束后立即生成。
    clock.set(DateTime.utc(2026, 11, 16, 1, 5));
    final changed = await service.tick();
    expect(changed.single.status, ReportStatus.generated);
    expect(changed.single.periodKey, '2026-11-15');
  });

  test('预算边界：B4 超支顺延次日再生成', () async {
    final clock = FakeClock(DateTime.utc(2026, 11, 15, 13, 31)); // 周日 21:31
    final source = InMemoryCreativeActivitySource([
      act(kind: CreativeActivityKind.topic, dayKey: '2026-11-15', label: '旅行'),
    ]);
    final store = InMemoryReportsStore();
    final budget = _ScriptedBudget([false, true]);
    final service = buildService(
      clock: clock,
      source: source,
      store: store,
      targets: const [weeklyTarget],
      budget: budget,
    );

    final first = await service.tick();
    expect(first.single.status, ReportStatus.deferred);
    expect(first.single.deferredTo, isNotNull);
    // 同一天再 tick：还在顺延期，不生成。
    expect(await service.tick(), isEmpty);

    // 次日 21:32（顺延到次日）再试：预算恢复，生成同一周报告。
    clock.set(DateTime.utc(2026, 11, 16, 13, 32));
    final second = await service.tick();
    expect(second.single.status, ReportStatus.generated);
    expect(second.single.periodKey, '2026-11-15');
    expect(budget.calls, 2);
  });

  test('FR-67 串数据：A 的报告 B 读不到', () async {
    final clock = FakeClock(DateTime.utc(2026, 11, 15, 13, 31));
    final source = InMemoryCreativeActivitySource([
      act(kind: CreativeActivityKind.topic, dayKey: '2026-11-15', label: '旅行'),
    ]);
    final service = buildService(
      clock: clock,
      source: source,
      store: InMemoryReportsStore(),
      targets: const [weeklyTarget],
    );
    await service.tick();

    final foreign = await service.getReport(
      ownerAccountId: 'u2',
      aiId: 'ai1',
      kind: ReportKind.weekly,
      periodKey: '2026-11-15',
    );
    expect(foreign.isErr, isTrue);
    expect(foreign.failureOrNull!.code, FailureCode.notFound);
    expect(await service.listForOwner('u2'), isEmpty);
  });

  test('AC-27 CR-03 年报：年度关键词/里程碑/最热闹一天 + 水印', () async {
    final clock = FakeClock(DateTime.utc(2026, 12, 31, 13, 31));
    final source = InMemoryCreativeActivitySource([
      act(
        scope: CreativeScope.moments,
        kind: CreativeActivityKind.topic,
        dayKey: '2026-03-01',
        label: '旅行',
        value: 5,
      ),
      act(
        scope: CreativeScope.moments,
        kind: CreativeActivityKind.topic,
        dayKey: '2026-04-01',
        label: '电影',
        value: 3,
      ),
      act(
        scope: CreativeScope.moments,
        kind: CreativeActivityKind.topic,
        dayKey: '2026-05-01',
        label: '读书',
        value: 1,
      ),
      act(
        scope: CreativeScope.moments,
        kind: CreativeActivityKind.milestone,
        dayKey: '2026-08-15',
        label: '一起看海',
      ),
    ]);
    final service = buildService(
      clock: clock,
      source: source,
      store: InMemoryReportsStore(),
      targets: const [],
    );
    final result = await service.generateAnnual(
      ownerAccountId: 'u1',
      aiId: 'ai1',
      year: 2026,
      authorizedScopes: {CreativeScope.moments},
    );
    expect(result.isOk, isTrue);
    final report = result.value;
    expect(report.kind, ReportKind.annual);
    expect(report.periodKey, '2026');
    expect(report.keywords, contains('旅行'));
    expect(report.milestones, hasLength(1));
    expect(report.milestones.single, contains('一起看海'));
    expect(report.busiestDay, isNotNull);
    expect(report.shareCard.watermark, contains('鲸言鲸语'));
  });
}
