import 'package:client_flutter/app/module_catalog.dart';
import 'package:client_flutter/app/perf_probe.dart';
import 'package:client_flutter/features/diagnostics/module_test_panel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('empty frame window reports zeros', () {
    final summary = summarizeFrames(const <FrameSample>[], rssBytes: 10 * 1024 * 1024);
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
    expect(world!.availability, ModuleAvailability.unavailable);
    expect(world.availabilityLabel, '未接入');
    expect(findModule('unknown-module'), isNull);
    expect(appModules.map((m) => m.id).toSet().length, appModules.length);
  });

  testWidgets('panel lists modules and toggles measurement state', (tester) async {
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
}
