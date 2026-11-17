import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:client_flutter/app/shell_app.dart';

import 'ui_test.dart'
    show
        TestShellModel,
        enterOnboardingField,
        fillNewAccountCredentials,
        submitHostConnection;

void main() {
  testWidgets('authenticated user has a way to enter chat before world setup', (
    tester,
  ) async {
    final model = TestShellModel()..onboarded = false;
    await tester.pumpWidget(WhaleChatApp(model: model));
    await enterOnboardingField(tester, 'host-address', 'https://host.example');
    await enterOnboardingField(tester, 'host-invite', 'synthetic-invite');
    await fillNewAccountCredentials(tester);
    await submitHostConnection(tester);
    expect(find.text('选择你的形象'), findsOneWidget);
    expect(find.byKey(const Key('defer-world-setup')), findsOneWidget);
  });
}
