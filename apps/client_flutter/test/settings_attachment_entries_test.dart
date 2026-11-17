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

  testWidgets('settings exposes the attachment list entry', (tester) async {
    await pump(tester);
    final entry = find.byKey(const Key('open-attachments-list'));
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    expect(find.text('附件列表'), findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    // Test model is not the runtime, so no connection: honest unbound.
    expect(find.text('附件列表'), findsWidgets);
    expect(find.byKey(const Key('attachments-unbound')), findsOneWidget);
  });

  testWidgets('settings exposes the attachment metadata viewer entry', (
    tester,
  ) async {
    await pump(tester);
    final entry = find.byKey(const Key('open-attachment-viewer'));
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    expect(find.text('附件元数据'), findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    // Test model is not the runtime, so no connection: honest unbound.
    expect(find.text('附件元数据'), findsWidgets);
    expect(find.byKey(const Key('attachment-unbound')), findsOneWidget);
  });
}
