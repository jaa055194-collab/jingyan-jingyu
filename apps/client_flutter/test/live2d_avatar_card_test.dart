// Widget tests for Live2DAvatarCard against the fake native view in
// live2d_native_fake.dart and the in-memory store in live2d_fake_store.dart.
import 'package:client_flutter/features/world/live2d_avatar_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'live2d_fake_store.dart';
import 'live2d_native_fake.dart';

const _card = Key('live2d-avatar-card');
const _toggle = Key('live2d-avatar-toggle');
const _body = Key('live2d-avatar-body');
const _resize = Key('live2d-avatar-resize');
const _failed = Key('live2d-avatar-failed');
const _retry = Key('live2d-avatar-retry');
const _loading = Key('live2d-avatar-loading');

/// Loading shows an infinite spinner, so pumpAndSettle would time out. A few
/// frames let channel calls, stream events and rebuilds land.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
}

Future<FakeLive2DPlatformViews> _pumpCard(
  WidgetTester tester, {
  required FakeLive2DFileStore store,
  double? maxHeight,
}) async {
  final platformViews = FakeLive2DPlatformViews();
  addTearDown(platformViews.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: Live2DAvatarCard(
              openStore: () async => store,
              supported: true,
              maxHeight: maxHeight,
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  return platformViews;
}

void main() {
  testWidgets('is hidden when no model is enabled', (tester) async {
    final store = FakeLive2DFileStore();
    final platformViews = await _pumpCard(tester, store: store);

    expect(find.byKey(_card), findsNothing);
    expect(find.byType(AndroidView), findsNothing);
    expect(platformViews.views, isEmpty);
  });

  testWidgets('shows the enabled model in a card and serves+loads once',
      (tester) async {
    final store = FakeLive2DFileStore()
      ..addModel('m1', displayName: '示例模型', active: true);
    final platformViews = await _pumpCard(tester, store: store);

    expect(find.byKey(_card), findsOneWidget);
    expect(find.text('示例模型'), findsOneWidget);
    expect(find.byKey(_loading), findsOneWidget);
    expect(find.byType(AndroidView), findsOneWidget);
    expect(platformViews.views, hasLength(1));
    final view = platformViews.last;
    expect(view.calls.where((call) => call.method == 'serve'), hasLength(1));
    expect(view.calls.first.arguments, {'directory': store.modelDirectory('m1')});

    await view.boot();
    await _settle(tester);
    expect(view.postedCommands, ['load']);

    await view.ready(modelId: 'm1');
    await _settle(tester);
    expect(find.byKey(_loading), findsNothing);

    // Rebuilding does not mount another view or serve/load again.
    await tester.pump();
    expect(platformViews.views, hasLength(1));
    expect(view.calls.where((call) => call.method == 'serve'), hasLength(1));
    expect(view.postedCommands, ['load']);
  });

  testWidgets('collapsing hides the view area and expanding restores it',
      (tester) async {
    final store = FakeLive2DFileStore()
      ..addModel('m1', displayName: '示例模型', active: true);
    final platformViews = await _pumpCard(tester, store: store);
    final first = platformViews.last;
    await first.boot();
    await first.ready(modelId: 'm1');
    await _settle(tester);
    expect(find.byType(AndroidView), findsOneWidget);

    await tester.tap(find.byKey(_toggle));
    await _settle(tester);
    expect(find.byType(AndroidView), findsNothing);
    expect(find.byKey(_body), findsNothing);
    // The header stays for re-expanding.
    expect(find.text('示例模型'), findsOneWidget);

    await tester.tap(find.byKey(_toggle));
    await _settle(tester);
    expect(find.byType(AndroidView), findsOneWidget);
    // A fresh platform view is mounted, which reloads the model.
    expect(platformViews.views, hasLength(2));
    expect(platformViews.last.calls.first.arguments, {
      'directory': store.modelDirectory('m1'),
    });
  });

  testWidgets('dragging the handle changes height within the clamps',
      (tester) async {
    final store = FakeLive2DFileStore()
      ..addModel('m1', displayName: '示例模型', active: true);
    await _pumpCard(tester, store: store, maxHeight: 300);

    expect(tester.getSize(find.byKey(_body)).height, 220);

    await tester.drag(find.byKey(_resize), const Offset(0, -400));
    await _settle(tester);
    expect(tester.getSize(find.byKey(_body)).height, 120);

    await tester.drag(find.byKey(_resize), const Offset(0, 400));
    await _settle(tester);
    expect(tester.getSize(find.byKey(_body)).height, 300);
  });

  testWidgets('a failure shows an honest message and retry recovers',
      (tester) async {
    final store = FakeLive2DFileStore()
      ..addModel('m1', displayName: '示例模型', active: true);
    final platformViews = await _pumpCard(tester, store: store);
    final first = platformViews.last;
    await first.boot();
    await first.viewerError('模型无法显示', code: 'render_failed');
    await _settle(tester);

    expect(find.byKey(_failed), findsOneWidget);
    expect(find.byKey(_retry), findsOneWidget);

    await tester.tap(find.byKey(_retry));
    await _settle(tester);
    expect(platformViews.views, hasLength(2));
    expect(platformViews.disposed, contains(first.viewId));

    final second = platformViews.last;
    await second.boot();
    await second.ready(modelId: 'm1');
    await _settle(tester);
    expect(find.byKey(_failed), findsNothing);
    expect(find.byType(AndroidView), findsOneWidget);
  });
}
