import 'dart:async';

import 'package:client_flutter/features/creative/creative_screen.dart';
import 'package:client_flutter/net/creative_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

CreativeReportSummary _summary({
  String kind = 'weekly',
  String periodKey = '2026-11-15',
  String status = 'generated',
  CreativeReport? report,
}) => CreativeReportSummary(
  aiId: 'ai-profile',
  kind: kind,
  periodKey: periodKey,
  status: status,
  report: report,
);

CreativeReport _report() => CreativeReport(
  kind: 'weekly',
  periodKey: '2026-11-15',
  windowStartDay: '2026-11-09',
  windowEndDay: '2026-11-15',
  generatedAt: DateTime.utc(2026, 11, 15, 13, 31),
  commonTopics: [],
  completedAgreements: 0,
  checkinDays: 0,
  moodCurve: {},
  letter: '',
  keywords: [],
  milestones: [],
  busiestDay: null,
  sourceScopes: [],
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
            _summary(kind: 'annual', periodKey: '2026', report: _report()),
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
