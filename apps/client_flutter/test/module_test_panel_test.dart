import 'package:client_flutter/app/module_catalog.dart';
import 'package:client_flutter/app/perf_probe.dart';
import 'package:client_flutter/features/diagnostics/module_test_panel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('empty frame window reports zeros', () {
    final summary = summarizeFrames(
      const <FrameSample>[],
      rssBytes: 10 * 1024 * 1024,
    );
    expect(summary.totalFrames, 0);
    expect(summary.fps, 0);
    expect(summary.avgMillis, 0);
    expect(summary.p95Millis, 0);
    expect(summary.jankFrames, 0);
    expect(summary.rssMegabytes, closeTo(10, 0.001));
  });

  test('fps, average, p95 and jank are computed from real frame times', () {
    const samples = <FrameSample>[
      FrameSample(buildMillis: 6, rasterMillis: 4), // 10
      FrameSample(buildMillis: 6, rasterMillis: 4), // 10
      FrameSample(buildMillis: 6, rasterMillis: 4), // 10
      FrameSample(buildMillis: 30, rasterMillis: 10), // 40 (janky)
    ];
    final summary = summarizeFrames(samples);
    expect(summary.totalFrames, 4);
    // sum=70ms -> 4/0.07 = 57.1428...
    expect(summary.fps, closeTo(57.1428, 0.01));
    expect(summary.avgMillis, closeTo(17.5, 0.001));
    expect(summary.p95Millis, 40); // nearest-rank over sorted [10,10,10,40]
    expect(summary.jankFrames, 1);
    expect(summary.rssMegabytes, isNull);
  });

  test('module catalog is honest about availability', () {
    final chat = findModule('chat');
    final world = findModule('world');
    expect(chat, isNotNull);
    expect(chat!.availability, ModuleAvailability.available);
    expect(world, isNotNull);
    // The 3D street works on Android; the description names what is missing.
    expect(world!.availability, ModuleAvailability.available);
    expect(world.availabilityLabel, '已实现');
    expect(world.description, contains('只接入了 Android 端'));
    expect(findModule('unknown-module'), isNull);
    expect(appModules.map((m) => m.id).toSet().length, appModules.length);
  });

  testWidgets('panel lists modules and toggles measurement state', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ModuleTestPanel())),
    );
    expect(find.text('世界与形象'), findsOneWidget);
    expect(find.text('状态：未开始（点击开始测量）'), findsOneWidget);
    expect(find.text('FPS：0.0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('module-test-start')));
    await tester.pump();
    expect(find.text('状态：测量中…'), findsOneWidget);

    await tester.tap(find.byKey(const Key('module-test-stop')));
    await tester.pump();
    expect(find.text('状态：未开始（点击开始测量）'), findsOneWidget);
  });

  testWidgets('help block states what the panel proves and does not prove', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ModuleTestPanel())),
    );
    final help = find.byKey(const Key('module-test-help'));
    expect(help, findsOneWidget);
    expect(find.textContaining('本面板证明'), findsOneWidget);
    expect(find.textContaining('不证明：模型可用'), findsOneWidget);
    expect(find.textContaining('GPU 显存'), findsWidgets);
  });

  testWidgets('each module row explains its availability honestly', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ModuleTestPanel())),
    );
    // Available modules: honest scope note (four modules are available).
    expect(find.textContaining('不代表模型可用或已授权'), findsNWidgets(4));
    // Placeholder modules get their own one-line explanation; none is
    // unavailable now that the world module's 3D street is wired.
    expect(find.textContaining('占位：入口存在'), findsNWidgets(3));
    expect(find.textContaining('未接入：渲染/能力尚未接入外壳'), findsNothing);
    for (final module in appModules) {
      expect(
        find.byKey(Key('module-availability-${module.id}')),
        findsOneWidget,
        reason: module.id,
      );
    }
  });

  testWidgets('probe status distinguishes unconfigured, measuring, measured', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ModuleTestPanel())),
    );
    expect(find.byKey(const Key('module-test-probe-result')), findsOneWidget);
    expect(find.textContaining('探针状态：未配置'), findsOneWidget);
    expect(find.textContaining('不代表性能差'), findsOneWidget);

    await tester.tap(find.byKey(const Key('module-test-start')));
    await tester.pump();
    expect(find.textContaining('探针状态：测量中'), findsOneWidget);
    expect(find.textContaining('探针状态：未配置'), findsNothing);

    await tester.tap(find.byKey(const Key('module-test-stop')));
    await tester.pump();
    // Without real frame timings in the test binding no samples are collected,
    // so the honest post-stop state stays "no data yet" (never a fake result).
    expect(find.textContaining('探针状态：测量中'), findsNothing);
    expect(
      find.textContaining('探针状态：已测得').evaluate().length +
          find.textContaining('探针状态：未配置').evaluate().length,
      1,
    );
    expect(find.textContaining('不代表宿主可用性或任何 AI 能力'), findsOneWidget);
  });
}
