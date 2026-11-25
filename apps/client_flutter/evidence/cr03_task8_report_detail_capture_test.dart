import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _weeklyLetter =
    '合成示例：这一周，我们记下了周末的短途旅行计划，也约好了下次一起看电影。\n谢谢你把这些小事留在我们的共同记录里。';
const _annualLetter = '合成示例：今年我们从春天的散步聊到秋天的海。谢谢你和我一起写下这些回忆。';

Map<String, Object?> _report({required bool annual}) => {
  'kind': annual ? 'annual' : 'weekly',
  'periodKey': annual ? '2025' : '2026-11-15',
  'windowStartDay': annual ? '2025-01-01' : '2026-11-09',
  'windowEndDay': annual ? '2025-12-31' : '2026-11-15',
  'generatedAt': annual ? '2025-12-31T13:31:00Z' : '2026-11-15T13:31:00Z',
  'commonTopics': [
    {'label': '旅行', 'count': annual ? 24 : 3},
    {'label': '电影', 'count': annual ? 12 : 1},
  ],
  'completedAgreements': annual ? 16 : 2,
  'checkinDays': annual ? 38 : 4,
  'moodCurve': annual
      ? {'2025-04-10': 4.5, '2025-10-01': 4.0}
      : {'2026-11-11': 4.0, '2026-11-12': 3.5},
  'letter': annual ? _annualLetter : _weeklyLetter,
  'keywords': annual ? ['旅行', '读书', '电影'] : <String>[],
  'milestones': annual ? ['2025-04-10 一起散步', '2025-10-01 一起看海'] : <String>[],
  'busiestDay': annual ? '2025-10-01' : null,
  'sourceScopes': annual
      ? ['groupChat', 'moments']
      : ['privateChat', 'moments'],
};

/// Only the authenticated transport is substituted; real CreativeApi and the
/// production shell are used on both revisions.
class _FixtureConnection extends HostConnection {
  _FixtureConnection() : super(Uri.parse('http://fixture.invalid'), 'fixture');

  final calls = <String>[];

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    expect(method, 'GET');
    expect(body, isNull);
    expect(query, isNull);
    calls.add(path);
    return switch (path) {
      '/api/v1/creative/reports' => {
        'reports': [
          {
            'aiId': 'fixture-ai-atlas',
            'kind': 'weekly',
            'periodKey': '2026-11-15',
            'status': 'generated',
            'report': _report(annual: false),
          },
          {
            'aiId': 'fixture-ai-atlas',
            'kind': 'annual',
            'periodKey': '2025',
            'status': 'generated',
            'report': _report(annual: true),
          },
          {
            'aiId': 'fixture-ai-atlas',
            'kind': 'weekly',
            'periodKey': '2026-11-08',
            'status': 'missed',
          },
          {
            'aiId': 'fixture-ai-atlas',
            'kind': 'weekly',
            'periodKey': '2026-11-01',
            'status': 'deferred',
          },
          {
            'aiId': 'fixture-ai-atlas',
            'kind': 'weekly',
            'periodKey': '2026-10-25',
            'status': 'generated',
          },
        ],
      },
      '/api/v1/creative/radio' => {'episodes': <Object?>[]},
      _ => throw StateError('Unexpected fixture request'),
    };
  }
}

class _FixtureRuntime extends ClientRuntime {
  _FixtureRuntime(HostConnection fixture) {
    connection = fixture;
  }

  @override
  bool get ready => true;
  @override
  bool get onboarded => true;
  @override
  bool get chatEntered => true;
  @override
  bool get online => true;
  @override
  String? get connectedAccountId => 'fixture-report-reader';
  @override
  Object get ownAiSessionContext => 1;
  @override
  ThemeMode get themeMode => ThemeMode.light;
  @override
  double get fontScale => 1;
}

void main() {
  testWidgets('capture the real 动态 tab and optional report disclosures', (
    tester,
  ) async {
    const output = String.fromEnvironment('CR03_CAPTURE_PATH');
    const weekly = String.fromEnvironment('CR03_CAPTURE_WEEKLY');
    const annual = String.fromEnvironment('CR03_CAPTURE_ANNUAL');
    const font = String.fromEnvironment('CAPTURE_CJK_FONT');
    const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
    expect(output, isNotEmpty);
    for (final (family, path) in [('Ahem', font), ('MaterialIcons', icons)]) {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final connection = _FixtureConnection();
    final runtime = _FixtureRuntime(connection);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: WhaleChatApp(model: runtime),
      ),
    );
    expect(
      connection.calls,
      isEmpty,
      reason: 'chat does not fetch creative data',
    );
    await tester.tap(find.text('动态'));
    await tester.pumpAndSettle();
    final weeklyRow = find.text('周报 · 2026-11-15');
    final annualRow = find.text('年报 · 2025');
    expect(weeklyRow, findsOneWidget);
    expect(annualRow, findsOneWidget);
    expect(find.text('已错过'), findsOneWidget);
    expect(find.text('待重试'), findsOneWidget);
    expect(find.text('周报 · 2026-10-25'), findsOneWidget);
    expect(find.text(_weeklyLetter), findsNothing);
    expect(find.text(_annualLetter), findsNothing);

    Future<void> capture(String path) async {
      expect(connection.calls, [
        '/api/v1/creative/reports',
        '/api/v1/creative/radio',
      ]);
      expect(tester.takeException(), isNull);
      final painter =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final png = await tester.runAsync(() async {
        final image = await painter.toImage();
        try {
          expect((image.width, image.height), (1280, 960));
          return await image.toByteData(format: ui.ImageByteFormat.png);
        } finally {
          image.dispose();
        }
      });
      File(path).writeAsBytesSync(
        png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    }

    await capture(output);

    // These follow-on states intentionally are not the matched list pair.
    if (weekly.isNotEmpty) {
      await tester.tap(weeklyRow);
      await tester.pumpAndSettle();
      expect(find.text(_weeklyLetter).hitTestable(), findsOneWidget);
      expect(find.text('来源范围'), findsOneWidget);
      await capture(weekly);
      await tester.tap(weeklyRow);
      await tester.pumpAndSettle();
      expect(find.text(_weeklyLetter), findsNothing);
    }
    if (annual.isNotEmpty) {
      await tester.tap(annualRow);
      await tester.pumpAndSettle();
      expect(find.text(_annualLetter).hitTestable(), findsOneWidget);
      expect(find.text('最热闹的一天：2025-10-01'), findsOneWidget);
      await capture(annual);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });
}
