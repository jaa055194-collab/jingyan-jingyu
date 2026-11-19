import 'dart:async';

import 'package:client_flutter/features/world/live2d_import_panel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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
}
