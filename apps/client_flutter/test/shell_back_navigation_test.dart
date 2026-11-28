import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

/// Simulates the Android system back button.
Future<void> systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('system back closes settings before leaving the shell', (
    tester,
  ) async {
    await tester.pumpWidget(WhaleChatApp(model: TestShellModel()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    await systemBack(tester);
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(WhaleChatApp), findsOneWidget);
  });

  testWidgets('system back from another tab returns to the first tab', (
    tester,
  ) async {
    await tester.pumpWidget(WhaleChatApp(model: TestShellModel()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.people_outline));
    await tester.pumpAndSettle();
    final rail = find.byType(NavigationRail);
    expect(tester.widget<NavigationRail>(rail).selectedIndex, 1);

    await systemBack(tester);
    expect(tester.widget<NavigationRail>(rail).selectedIndex, 0);
  });

  testWidgets('narrow screen: system back from another tab selects the first', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(WhaleChatApp(model: TestShellModel()));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);

    await tester.tap(find.byIcon(Icons.people_outline).last);
    await tester.pumpAndSettle();
    await systemBack(tester);
    expect(find.byType(WhaleChatApp), findsOneWidget);
    expect(find.byIcon(Icons.people_outline), findsWidgets);
  });
}
