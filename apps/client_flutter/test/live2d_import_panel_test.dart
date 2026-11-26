import 'dart:async';

import 'package:client_flutter/features/world/live2d_import_panel.dart';
import 'package:client_flutter/features/world/live2d_preview_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'live2d_native_fake.dart';

void main() {
  const action = Key('live2d-select-zip');

  testWidgets('cancellation re-enables selection without reporting success', (
    tester,
  ) async {
    final pending = Completer<Live2DImportSession?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Live2DImportPanel(open: () => pending.future)),
      ),
    );
    await tester.tap(find.byKey(action));
    await tester.pump();
    expect(tester.widget<OutlinedButton>(find.byKey(action)).onPressed, isNull);
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(
      tester.widget<OutlinedButton>(find.byKey(action)).onPressed,
      isNotNull,
    );
    expect(find.byKey(const Key('live2d-import-prepared')), findsNothing);
  });

  testWidgets('late preparation is released when the world view is gone', (
    tester,
  ) async {
    final pending = Completer<Live2DImportSession?>();
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Live2DImportPanel(open: () => pending.future)),
      ),
    );
    await tester.tap(find.byKey(action));
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(
      Live2DImportSession(() async {
        closed++;
      }),
    );
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets(
    'prepared files are not represented as a rendered or activated avatar',
    (tester) async {
      var closed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Live2DImportPanel(
              open: () async => Live2DImportSession(() async {
                closed++;
              }),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(action));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live2d-import-prepared')), findsOneWidget);
      expect(find.textContaining('未显示或启用形象'), findsOneWidget);
      await tester.tap(find.byKey(const Key('live2d-release-zip')));
      await tester.pumpAndSettle();
      expect(closed, 1);
      expect(find.byKey(const Key('live2d-import-prepared')), findsNothing);
    },
  );

  group('a prepared preview stage', () {
    const directory =
        '/data/user/0/jingyu/cache/live2d-preview/live2d-preview-1';
    const preview = Key('live2d-import-preview');
    const prepared = Key('live2d-import-prepared');
    const release = Key('live2d-release-zip');

    // The preview's loading spinner never settles, so pumpAndSettle would
    // time out. A few frames let channel calls and state changes land.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
    }

    Future<FakeLive2DPlatformViews> pumpPrepared(
      WidgetTester tester,
      Future<void> Function() close,
    ) async {
      final platformViews = FakeLive2DPlatformViews();
      addTearDown(platformViews.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                Live2DImportPanel(
                  open: () async =>
                      Live2DImportSession(close, previewDirectory: directory),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(action));
      await settle(tester);
      return platformViews;
    }

    testWidgets('is shown in a 280-high card as a local preview only', (
      tester,
    ) async {
      final platformViews = await pumpPrepared(tester, () async {});
      final card = find.byKey(preview);
      expect(card, findsOneWidget);
      expect(tester.widget<Card>(card).clipBehavior, Clip.antiAlias);
      final view = find.descendant(
        of: card,
        matching: find.byType(Live2DPreviewView),
      );
      expect(tester.widget<Live2DPreviewView>(view).directory, directory);
      expect(tester.getSize(view).height, 280);
      expect(platformViews.last.calls.first.arguments, {
        'directory': directory,
      });
      expect(find.byKey(prepared), findsOneWidget);
      expect(find.textContaining('未启用形象'), findsOneWidget);
      expect(find.textContaining('未显示'), findsNothing);

      await platformViews.last.boot();
      await platformViews.last.ready();
      await settle(tester);
      expect(find.byKey(const Key('live2d-preview-loading')), findsNothing);
      expect(find.byKey(const Key('live2d-preview-failed')), findsNothing);
    }, variant: const TargetPlatformVariant({TargetPlatform.android}));

    testWidgets('is not shown where there is no Android preview host', (
      tester,
    ) async {
      var closed = 0;
      final platformViews = await pumpPrepared(tester, () async {
        closed++;
      });
      expect(tester.takeException(), isNull);
      expect(find.byKey(preview), findsNothing);
      expect(find.byType(Live2DPreviewView), findsNothing);
      expect(platformViews.views, isEmpty);
      expect(find.byKey(prepared), findsOneWidget);
      expect(find.textContaining('未显示或启用形象'), findsOneWidget);

      await tester.tap(find.byKey(release));
      await settle(tester);
      expect(closed, 1);
      expect(find.byKey(prepared), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

    testWidgets('is removed while its files are cleaned', (tester) async {
      final cleaning = Completer<void>();
      var closed = 0;
      final platformViews = await pumpPrepared(tester, () {
        closed++;
        return cleaning.future;
      });
      final viewId = platformViews.last.viewId;

      await tester.tap(find.byKey(release));
      await settle(tester);
      expect(closed, 1);
      expect(find.byKey(preview), findsNothing);
      expect(platformViews.disposed, contains(viewId));

      cleaning.complete();
      await settle(tester);
      expect(find.byKey(prepared), findsNothing);
      expect(find.byKey(release), findsNothing);
      expect(
        tester.widget<OutlinedButton>(find.byKey(action)).onPressed,
        isNotNull,
      );
    });
  });
}
