import 'package:client_flutter/app/shell_app.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

void main() {
  testWidgets('wide screen: nav, list and chat are separate boards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(WhaleChatApp(model: TestShellModel()));
    await tester.pumpAndSettle();

    final nav = find.byKey(const Key('shell-nav-board'));
    final list = find.byKey(const Key('shell-list-board'));
    final chat = find.byKey(const Key('shell-chat-board'));
    expect(nav, findsOneWidget);
    expect(list, findsOneWidget);
    expect(chat, findsOneWidget);
    expect(find.byType(VerticalDivider), findsNothing);

    final navRect = tester.getRect(nav);
    final listRect = tester.getRect(list);
    final chatRect = tester.getRect(chat);
    expect(listRect.width, 320);
    // A 12dp gap between boards shows the canvas.
    expect(listRect.left - navRect.right, closeTo(12, 0.01));
    expect(chatRect.left - listRect.right, closeTo(12, 0.01));
    expect(
      find.descendant(of: nav, matching: find.byType(NavigationRail)),
      findsOneWidget,
    );
  });

  testWidgets('narrow screen keeps the dock and no boards', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(WhaleChatApp(model: TestShellModel()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('shell-nav-board')), findsNothing);
    expect(find.byKey(const Key('shell-list-board')), findsNothing);
    expect(find.byType(NavigationRail), findsNothing);
  });
}
