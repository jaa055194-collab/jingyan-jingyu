import 'package:client_flutter/features/search/search_screen.dart';
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

  testWidgets('settings exposes exactly one global message search entry', (
    tester,
  ) async {
    await pump(tester);
    final entry = find.byKey(const Key('open-message-search'));
    expect(entry, findsNothing, reason: 'below the initial viewport');
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    expect(entry, findsOneWidget);
    expect(find.text('消息搜索'), findsOneWidget);
    // Exactly one entry: no duplicate was added next to it.
    expect(
      find.descendant(of: entry, matching: find.text('消息搜索')),
      findsOneWidget,
    );
  });

  testWidgets('tapping the entry opens the search screen', (tester) async {
    await pump(tester);
    final entry = find.byKey(const Key('open-message-search'));
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);
    // TestShellModel is not ClientRuntime: no connection, so no query is sent
    // and the screen reports the honest unbound state.
    expect(find.byKey(const Key('search-unbound')), findsOneWidget);
    expect(find.byKey(const Key('search-query')), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  });
}
