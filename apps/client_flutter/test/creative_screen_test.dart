import 'dart:async';

import 'package:client_flutter/features/creative/creative_screen.dart';
import 'package:client_flutter/net/creative_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

CreativeReportSummary _summary({
  String aiId = 'ai-profile',
  String kind = 'weekly',
  String periodKey = '2026-11-15',
  String status = 'generated',
  CreativeReport? report,
}) => CreativeReportSummary(
  aiId: aiId,
  kind: kind,
  periodKey: periodKey,
  status: status,
  report: report,
);

CreativeReport _report({
  String kind = 'weekly',
  String letter = '这一周我们聊了很多。',
  bool empty = false,
}) => CreativeReport(
  kind: kind,
  periodKey: kind == 'annual' ? '2026' : '2026-11-15',
  windowStartDay: kind == 'annual' ? '2026-01-01' : '2026-11-09',
  windowEndDay: kind == 'annual' ? '2026-12-31' : '2026-11-15',
  generatedAt: DateTime.utc(2026, 11, 15, 13, 31),
  commonTopics: empty
      ? []
      : const [
          CreativeTopicCount(label: '旅行', count: 3),
          CreativeTopicCount(label: '电影', count: 1),
        ],
  completedAgreements: empty ? 0 : 2,
  checkinDays: empty ? 0 : 4,
  moodCurve: empty ? {} : const {'2026-11-12': 3.5, '2026-11-11': 4.0},
  letter: empty ? '' : letter,
  keywords: kind == 'annual' ? const ['旅行', '电影'] : [],
  milestones: kind == 'annual' ? const ['2026-08-15 一起看海'] : [],
  busiestDay: kind == 'annual' ? '2026-08-15' : null,
  sourceScopes: empty ? [] : const ['privateChat', 'moments'],
);

CreativeRadioEpisode _episode({
  String dateKey = '2026-11-16',
  bool offline = true,
}) => CreativeRadioEpisode(
  aiId: 'ai-profile',
  dateKey: dateKey,
  scheduledFor: DateTime.utc(2026, 11, 16, 15),
  generatedAt: DateTime.utc(2026, 11, 16, 14, 50),
  voiceId: 'voice-1',
  offlineCacheKey: 'cache/2026-11-16',
  playableOffline: offline,
  script: const CreativeRadioScript(
    text: '晚安，慢慢呼吸。',
    segments: [CreativeRadioSegment(kind: 'comfort', text: '晚安，慢慢呼吸。')],
  ),
);

void main() {
  testWidgets(
    'without a host loader the creative surface is an honest unknown state',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CreativeScreen()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('creative-unbound')), findsOneWidget);
      expect(find.textContaining('创作内容需要接入宿主连接后显示'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(ListTile), findsNothing);
      // Unbound has no loaders: the explicit refresh action is disabled.
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('creative-refresh')))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('host lists render weekly/annual reports and offline radio', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CreativeScreen(
          loadReports: () async => [
            _summary(report: _report()),
            _summary(
              kind: 'annual',
              periodKey: '2026',
              report: _report(kind: 'annual'),
            ),
            _summary(periodKey: '2026-11-08', status: 'missed'),
          ],
          loadRadio: () async => [
            _episode(),
            _episode(dateKey: '2026-11-17', offline: false),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('关系周报 / 年报'), findsOneWidget);
    expect(find.text('深夜电台'), findsOneWidget);
    expect(find.text('周报 · 2026-11-15'), findsOneWidget);
    expect(find.text('年报 · 2026'), findsOneWidget);
    expect(find.text('已错过'), findsOneWidget);
    expect(find.textContaining('可离线播放'), findsOneWidget);
    expect(find.textContaining('在线播放'), findsOneWidget);
    expect(find.text('2026-11-17'), findsOneWidget);
  });

  testWidgets(
    'expanding a weekly row displays stored fields without rereading',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 960));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CreativeScreen(
            loadReports: () async {
              reads++;
              return [_summary(report: _report())];
            },
            loadRadio: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('这一周我们聊了很多。'), findsNothing);

      await tester.tap(find.text('周报 · 2026-11-15'));
      await tester.pumpAndSettle();
      expect(find.text('这一周我们聊了很多。'), findsOneWidget);
      expect(find.textContaining('2026-11-09 至 2026-11-15'), findsOneWidget);
      expect(find.textContaining('2026-11-15 13:31:00 UTC'), findsOneWidget);
      expect(find.text('旅行 · 3 次'), findsOneWidget);
      expect(find.text('电影 · 1 次'), findsOneWidget);
      expect(find.text('完成的约定：2 项'), findsOneWidget);
      expect(find.text('打卡天数：4 天'), findsOneWidget);
      expect(find.text('2026-11-11：4.0'), findsOneWidget);
      expect(find.text('2026-11-12：3.5'), findsOneWidget);
      expect(find.text('私聊、朋友圈'), findsOneWidget);
      expect(find.text('年度关键词'), findsNothing);
      expect(reads, 1);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('周报 · 2026-11-15'));
      await tester.pumpAndSettle();
      expect(find.text('这一周我们聊了很多。'), findsNothing);
    },
  );

  testWidgets('annual detail presents stored annual fields', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: CreativeScreen(
          loadReports: () async => [
            _summary(
              kind: 'annual',
              periodKey: '2026',
              report: _report(kind: 'annual'),
            ),
          ],
          loadRadio: () async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('年报 · 2026'));
    await tester.pumpAndSettle();
    expect(find.text('年度关键词'), findsOneWidget);
    expect(find.text('旅行、电影'), findsOneWidget);
    expect(find.text('2026-08-15 一起看海'), findsOneWidget);
    expect(find.text('最热闹的一天：2026-08-15'), findsOneWidget);
  });

  testWidgets('missing body is distinguishable from missed and deferred', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CreativeScreen(
          loadReports: () async => [
            _summary(),
            _summary(periodKey: '2026-11-08', status: 'missed'),
            _summary(periodKey: '2026-11-01', status: 'deferred'),
          ],
          loadRadio: () async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('已生成 · 缺少报告内容'), findsOneWidget);
    expect(find.text('已错过'), findsOneWidget);
    expect(find.text('待重试'), findsOneWidget);
    for (final day in ['15', '08', '01']) {
      await tester.tap(find.text('周报 · 2026-11-$day'));
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.text('完成的约定：0 项'), findsNothing);
    }
  });

  testWidgets(
    'stored zero counts do not invent missing mood, letter or scope',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CreativeScreen(
            loadReports: () async => [_summary(report: _report(empty: true))],
            loadRadio: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('周报 · 2026-11-15'));
      await tester.pumpAndSettle();
      expect(find.text('完成的约定：0 项'), findsOneWidget);
      expect(find.text('打卡天数：0 天'), findsOneWidget);
      expect(find.text('暂无心情记录'), findsOneWidget);
      expect(find.text('未附信件'), findsOneWidget);
      expect(find.text('未记录来源范围'), findsOneWidget);
      expect(find.textContaining('2026-11-11：'), findsNothing);
    },
  );

  testWidgets('same-period rows disclose only their own AI report', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CreativeScreen(
          loadReports: () async => [
            _summary(
              aiId: 'ai-one',
              report: _report(letter: '只属于 AI 甲的信。'),
            ),
            _summary(
              aiId: 'ai-two',
              report: _report(letter: '只属于 AI 乙的信。'),
            ),
          ],
          loadRadio: () async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('AI：ai-one'), findsOneWidget);
    final second = find.text('AI：ai-two');
    await tester.tap(second);
    await tester.pumpAndSettle();
    expect(find.text('只属于 AI 乙的信。'), findsOneWidget);
    expect(find.text('只属于 AI 甲的信。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty host lists stay distinct from unbound and failures', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CreativeScreen(
          loadReports: () async => [],
          loadRadio: () async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无周报或年报。'), findsOneWidget);
    expect(find.text('暂无电台期次。'), findsOneWidget);
    expect(find.byKey(const Key('creative-empty-reports')), findsOneWidget);
    expect(find.byKey(const Key('creative-empty-radio')), findsOneWidget);
    expect(find.textContaining('创作内容需要接入宿主连接后显示'), findsNothing);
    expect(find.byKey(const Key('creative-retry')), findsNothing);
  });

  testWidgets(
    'failed load reports a safe retry hint and hides upstream detail',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CreativeScreen(
            loadReports: () async =>
                throw StateError('PRIVATE-UPSTREAM-SENTINEL'),
            loadRadio: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('读取失败，请稍后重试；不会自动重试'), findsOneWidget);
      expect(find.textContaining('PRIVATE-UPSTREAM-SENTINEL'), findsNothing);
      // Failure offers an explicit manual retry only; no auto-retry loop.
      expect(find.byKey(const Key('creative-retry')), findsOneWidget);
    },
  );

  testWidgets('refresh action re-runs the loader with honest loading state', (
    tester,
  ) async {
    var reportCalls = 0, radioCalls = 0;
    final gate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: CreativeScreen(
          loadReports: () async {
            reportCalls++;
            if (reportCalls > 1) await gate.future;
            return [_summary(report: _report())];
          },
          loadRadio: () async {
            radioCalls++;
            return [_episode()];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(reportCalls, 1);
    expect(radioCalls, 1);

    await tester.tap(find.byKey(const Key('creative-refresh')));
    await tester.pump();
    // Loading indicator while the second load is still pending.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(reportCalls, 2);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('周报 · 2026-11-15'), findsOneWidget);
    // Exactly the manual refresh; no automatic repeated loads.
    expect(reportCalls, 2);
    expect(radioCalls, 2);
  });

  testWidgets('failed load retries only on explicit manual action', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CreativeScreen(
          loadReports: () async {
            calls++;
            if (calls == 1) throw StateError('PRIVATE');
            return [_summary(report: _report())];
          },
          loadRadio: () async => [_episode()],
        ),
      ),
    );
    await tester.pumpAndSettle();
    // One initial attempt, then a stable failure state (no auto retries).
    expect(calls, 1);
    expect(find.byKey(const Key('creative-retry')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 1);
    expect(find.textContaining('PRIVATE'), findsNothing);

    await tester.tap(find.byKey(const Key('creative-retry')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('周报 · 2026-11-15'), findsOneWidget);
    expect(find.byKey(const Key('creative-retry')), findsNothing);
  });
}
