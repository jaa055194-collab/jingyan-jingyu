import 'package:client_flutter/features/ai_config/model_diagnostics_screen.dart';
import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(model: TestShellModel(), onBack: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('settings exposes the model diagnostics entry beside AI config', (
    tester,
  ) async {
    await pump(tester);
    final entry = find.byKey(const Key('open-model-diagnostics'));
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    expect(find.text('模型能力与预算诊断'), findsOneWidget);
    // The entry is grouped with the existing read-only AI config entry.
    expect(find.byKey(const Key('open-ai-config')), findsOneWidget);
  });

  testWidgets('the entry opens the diagnostics screen in its honest unbound state', (
    tester,
  ) async {
    await pump(tester);
    final entry = find.byKey(const Key('open-model-diagnostics'));
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(ModelDiagnosticsScreen), findsOneWidget);
    // TestShellModel is not the runtime, so there is no host connection: the
    // screen must stay honestly unbound instead of inventing numbers.
    expect(find.byKey(const Key('model-diagnostics-unbound')), findsOneWidget);
    expect(find.textContaining('不会自动重试'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('the diagnostics entry never renders a key or credential', (
    tester,
  ) async {
    await pump(tester);
    final entry = find.byKey(const Key('open-model-diagnostics'));
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: entry,
        matching: find.textContaining('api_key'),
      ),
      findsNothing,
    );
    expect(find.textContaining('****'), findsNothing);
  });
}
