// Widget tests for Live2DPreviewView against the fake native view in
// live2d_native_fake.dart.
import 'package:client_flutter/app/app_theme.dart';
import 'package:client_flutter/features/world/live2d_preview_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'live2d_native_fake.dart';

const _directory = '/data/user/0/jingyu/cache/live2d-preview/live2d-preview-1';
const _loading = Key('live2d-preview-loading');
const _failed = Key('live2d-preview-failed');
const _retry = Key('live2d-preview-retry');

/// Lets channel calls, page events and state changes arrive. The loading
/// spinner never settles, so pumpAndSettle would time out.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

Future<FakeLive2DPlatformViews> _pumpPreview(
  WidgetTester tester, {
  Duration firstFrameTimeout = const Duration(seconds: 20),
  void Function(FakeLive2DView view)? onCreate,
  ThemeData? theme,
  EdgeInsets padding = EdgeInsets.zero,
  String model3File = Live2DPreviewView.model3Name,
  bool kept = false,
  ValueChanged<Live2DPreviewController>? onReady,
}) async {
  final platformViews = FakeLive2DPlatformViews()..onCreate = onCreate;
  addTearDown(platformViews.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Padding(
          padding: padding,
          child: SizedBox(
            height: 280,
            child: Live2DPreviewView(
              directory: _directory,
              firstFrameTimeout: firstFrameTimeout,
              model3File: model3File,
              kept: kept,
              onReady: onReady,
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  return platformViews;
}

/// WCAG contrast ratio of [text] over the background colour of [cover].
double _contrast(WidgetTester tester, Finder cover, Finder text) {
  final background = tester
      .widget<ColoredBox>(
        find.descendant(of: cover, matching: find.byType(ColoredBox)).first,
      )
      .color;
  final style = tester
      .widget<RichText>(
        find.descendant(of: text, matching: find.byType(RichText)),
      )
      .text
      .style!;
  final luminance = <double>[
    Color.alphaBlend(style.color!, background).computeLuminance(),
    background.computeLuminance(),
  ]..sort();
  return (luminance[1] + 0.05) / (luminance[0] + 0.05);
}

void main() {
  testWidgets('serves the stage and loads model.model3.json from its base URL',
      (tester) async {
    final platformViews = await _pumpPreview(tester);
    final view = platformViews.last;
    expect(
      tester.widget<AndroidView>(find.byType(AndroidView)).viewType,
      'jingyu/live2d_view',
    );
    expect(view.calls.first.method, 'serve');
    expect(view.calls.first.arguments, {'directory': _directory});
    expect(find.byKey(_loading), findsOneWidget);
    expect(view.posted, isEmpty);

    await view.boot();
    await _settle(tester);
    expect(view.postedCommands, ['load']);
    expect(
      view.posted.single,
      containsPair('model3', '${view.baseUrl}model.model3.json'),
    );
    expect(find.byKey(_loading), findsOneWidget);

    await view.ready();
    await _settle(tester);
    expect(find.byKey(_loading), findsNothing);
    expect(find.byKey(_failed), findsNothing);
  });

  testWidgets('a viewer error after ready shows the reason; retry loads the '
      'model in a new view', (tester) async {
    final platformViews = await _pumpPreview(tester);
    final view = platformViews.last;
    await view.boot();
    await view.ready();
    await _settle(tester);

    await view.viewerError('WebGL context lost', code: 'webgl_context_lost');
    await _settle(tester);
    expect(find.byKey(_failed), findsOneWidget);
    expect(find.text('模型无法显示。'), findsOneWidget);
    expect(find.text('WebGL context lost'), findsOneWidget);

    await tester.tap(find.byKey(_retry));
    await _settle(tester);
    expect(find.byKey(_loading), findsOneWidget);
    expect(platformViews.views, hasLength(2));
    expect(platformViews.disposed, contains(view.viewId));
    final second = platformViews.last;
    expect(second.calls.first.arguments, {'directory': _directory});

    await second.boot();
    await second.ready();
    await _settle(tester);
    expect(find.byKey(_loading), findsNothing);
    expect(find.byKey(_failed), findsNothing);
  });

  testWidgets('a lost renderer shows the reason; retry starts a new view',
      (tester) async {
    final platformViews = await _pumpPreview(tester);
    final first = platformViews.last;
    await first.boot();
    await first.ready();
    await _settle(tester);

    await first.renderProcessGone();
    await _settle(tester);
    expect(find.byKey(_failed), findsOneWidget);
    expect(find.text('预览渲染器已停止。'), findsOneWidget);

    await tester.tap(find.byKey(_retry));
    await _settle(tester);
    expect(platformViews.views, hasLength(2));
    expect(platformViews.disposed, contains(first.viewId));
    final second = platformViews.last;
    expect(second.calls.first.arguments, {'directory': _directory});
    expect(find.byKey(_loading), findsOneWidget);

    await second.boot();
    await second.ready();
    await _settle(tester);
    expect(second.postedCommands, ['load']);
    expect(find.byKey(_loading), findsNothing);
    expect(find.byKey(_failed), findsNothing);
  });

  testWidgets('a page that fails to load shows the reason; retry starts a new '
      'view', (tester) async {
    final platformViews = await _pumpPreview(tester);
    final first = platformViews.last;
    await first.pageError('net::ERR_FILE_NOT_FOUND');
    await _settle(tester);
    expect(find.text('预览页面加载失败。'), findsOneWidget);
    expect(find.text('net::ERR_FILE_NOT_FOUND'), findsOneWidget);

    await tester.tap(find.byKey(_retry));
    await _settle(tester);
    expect(platformViews.views, hasLength(2));
    expect(platformViews.disposed, contains(first.viewId));
  });

  testWidgets('a first frame that never comes times out; retry starts a new '
      'view', (tester) async {
    final platformViews = await _pumpPreview(
      tester,
      firstFrameTimeout: const Duration(seconds: 5),
    );
    final first = platformViews.last;
    await first.boot();
    await _settle(tester);
    await tester.pump(const Duration(seconds: 6));
    await _settle(tester);
    expect(find.text('模型加载超时。'), findsOneWidget);

    // The controller disposes a timed-out viewer page, so it cannot load
    // again.
    await tester.tap(find.byKey(_retry));
    await _settle(tester);
    expect(platformViews.views, hasLength(2));
    expect(platformViews.disposed, contains(first.viewId));
    final second = platformViews.last;
    await second.boot();
    await second.ready();
    await _settle(tester);
    expect(find.byKey(_loading), findsNothing);
    expect(find.byKey(_failed), findsNothing);
  });

  testWidgets('a stage the shell refuses shows the reason; retry serves again',
      (tester) async {
    final platformViews = await _pumpPreview(
      tester,
      onCreate: (view) => view.serveError = PlatformException(
        code: 'bad_directory',
        message: 'not a preview directory',
      ),
    );
    final view = platformViews.last;
    expect(find.text('无法读取临时预览文件。'), findsOneWidget);
    expect(find.text('not a preview directory'), findsOneWidget);

    view.serveError = null;
    await tester.tap(find.byKey(_retry));
    await _settle(tester);
    expect(view.calls.where((call) => call.method == 'serve'), hasLength(2));
    expect(find.byKey(_loading), findsOneWidget);

    await view.boot();
    await view.ready();
    await _settle(tester);
    expect(find.byKey(_loading), findsNothing);
    expect(find.byKey(_failed), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('a long failure stays readable in a 280-high card at 2x text '
        '(${brightness.name})', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final platformViews = await _pumpPreview(
        tester,
        theme: buildAppTheme(brightness),
        padding: const EdgeInsets.symmetric(horizontal: 20),
      );
      final loadingText = find.descendant(
        of: find.byKey(_loading),
        matching: find.byType(Text),
      );
      expect(
        _contrast(tester, find.byKey(_loading), loadingText),
        greaterThanOrEqualTo(4.5),
      );

      final first = platformViews.last;
      await first.pageError(
        'net::ERR_FILE_NOT_FOUND${' while reading the stage' * 12}',
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);
      for (final text in <Finder>[
        find.text('预览页面加载失败。'),
        find.textContaining('ERR_FILE_NOT_FOUND'),
      ]) {
        expect(
          _contrast(tester, find.byKey(_failed), text),
          greaterThanOrEqualTo(4.5),
        );
      }
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

      // At 2x text the cover may scroll; the retry button must stay reachable.
      await tester.ensureVisible(find.byKey(_retry));
      await tester.pump();
      await tester.tap(find.byKey(_retry));
      await _settle(tester);
      expect(platformViews.views, hasLength(2));
      expect(platformViews.disposed, contains(first.viewId));
    });
  }

  testWidgets('removing the preview disposes its view', (tester) async {
    final platformViews = await _pumpPreview(tester);
    final view = platformViews.last;
    await view.boot();
    await view.ready();
    await _settle(tester);

    await tester.pumpWidget(const SizedBox());
    await _settle(tester);
    expect(platformViews.disposed, contains(view.viewId));
  });

  testWidgets('hands each ready renderer to onReady once, and none that '
      'failed', (tester) async {
    final ready = <Live2DPreviewController>[];
    final platformViews = await _pumpPreview(tester, onReady: ready.add);
    final view = platformViews.last;
    await view.boot();
    await view.viewerError('model3 not found', code: 'load_failed');
    await _settle(tester);
    expect(find.byKey(_failed), findsOneWidget);
    expect(ready, isEmpty);

    await tester.tap(find.byKey(_retry));
    await _settle(tester);
    final second = platformViews.last;
    await second.boot();
    await second.ready();
    await second.ready();
    await _settle(tester);
    expect(ready, hasLength(1));
    expect(ready.single.state, Live2DPreviewState.ready);
  });

  testWidgets('a kept model loads its own model3 file and names a failed '
      'read', (tester) async {
    final platformViews = await _pumpPreview(
      tester,
      model3File: 'a b/模型.model3.json',
      kept: true,
      onCreate: (view) => view.serveError = PlatformException(
        code: 'bad_directory',
        message: 'not a model directory',
      ),
    );
    final view = platformViews.last;
    expect(find.text('无法读取本机保存的模型文件。'), findsOneWidget);
    expect(find.text('无法读取临时预览文件。'), findsNothing);

    view.serveError = null;
    await tester.tap(find.byKey(_retry));
    await _settle(tester);
    await view.boot();
    await _settle(tester);
    expect(
      view.posted.single,
      containsPair(
        'model3',
        '${view.baseUrl}a%20b/%E6%A8%A1%E5%9E%8B.model3.json',
      ),
    );
  });
}
