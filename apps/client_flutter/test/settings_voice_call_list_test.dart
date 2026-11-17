import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

void main() {
  testWidgets('settings exposes the voice call list entry', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(model: TestShellModel(), onBack: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const Key('open-voice-call-list'));
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    expect(find.text('语音通话列表'), findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // Test model is not the runtime, so no connection: honest unbound.
    expect(find.text('语音通话列表'), findsWidgets);
    expect(find.byKey(const Key('voice-call-list-unbound')), findsOneWidget);
  });
}
