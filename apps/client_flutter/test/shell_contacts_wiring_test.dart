import 'package:client_flutter/app/shell_app.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

void main() {
  testWidgets('contacts destination without a runtime connection keeps the honest empty state', (tester) async {
    // TestShellModel is a plain ShellViewModel (not ClientRuntime), so the shell
    // cannot obtain a host connection and must not fabricate a friends list.
    await tester.pumpWidget(WhaleChatApp(model: TestShellModel()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.people_outline));
    await tester.pumpAndSettle();

    expect(find.text('联系人'), findsWidgets);
    expect(find.textContaining('宿主未提供好友列表路由'), findsOneWidget);
    expect(find.textContaining('接入好友列表后可在此显示'), findsOneWidget);
    // No fabricated friend rows.
    expect(find.byKey(const Key('contacts-friend-x')), findsNothing);
  });
}
