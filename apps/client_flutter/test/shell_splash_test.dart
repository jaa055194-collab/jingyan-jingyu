import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/ui/jy_presence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

void main() {
  testWidgets('start-up shows the light core splash until the model is ready', (
    tester,
  ) async {
    final model = TestShellModel()..ready = false;
    await tester.pumpWidget(WhaleChatApp(model: model));
    // The thinking core breathes, so never settle here.
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(ShellSplash), findsOneWidget);
    expect(find.byType(JyPresenceOrb), findsOneWidget);
    expect(find.text('鲸言鲸语'), findsOneWidget);
    expect(find.bySemanticsLabel('正在启动鲸言鲸语'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    model.ready = true;
    model.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(ShellSplash), findsNothing);
  });

  testWidgets('a busy model shows the labelled shell busy line', (
    tester,
  ) async {
    final model = TestShellModel();
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.pumpAndSettle();
    expect(find.byType(JyBusyIndicator), findsNothing);

    model.busy = true;
    model.notifyListeners();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(JyBusyIndicator), findsOneWidget);
    expect(find.bySemanticsLabel('正在处理'), findsWidgets);

    model.busy = false;
    model.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(JyBusyIndicator), findsNothing);
  });
}
