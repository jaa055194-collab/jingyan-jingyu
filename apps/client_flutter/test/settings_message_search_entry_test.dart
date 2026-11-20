import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/features/search/search_screen.dart';
import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

class _SearchConnection extends HostConnection {
  _SearchConnection() : super(Uri.parse('http://fixture.invalid'), 'fixture');

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    expect(method, 'GET');
    expect(path, '/api/v1/search');
    expect(query?['q'], 'fixture query');
    return const {
      'hits': [
        {
          'conversationId': 'fixture-chat',
          'messageId': 'private-hit',
          'seq': 1,
          'senderId': 'fixture-user',
          'kind': 'text',
          'body': {'text': 'private message fixture'},
          'sentAt': '2026-11-18T02:03:04.000Z',
          'mode': 'scan',
        },
      ],
    };
  }
}

class _SearchRuntime extends ClientRuntime {
  _SearchRuntime() {
    connection = _SearchConnection();
  }

  @override
  String? get connectedAccountId => 'fixture-owner';
  @override
  bool get locked => appLocked;
  bool appLocked = false;

  void setLocked(bool value) {
    appLocked = value;
    notifyListeners();
  }
}

void main() {
  testWidgets('the pushed search page hides query and hits on lock', (
    tester,
  ) async {
    final runtime = _SearchRuntime();
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(model: runtime, onBack: () {}),
        ),
      ),
    );
    final entry = find.byKey(const Key('open-message-search'));
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    final query = find.byKey(const Key('search-query'));
    final submit = find.byKey(const Key('search-submit'));
    final hit = find.byKey(const Key('search-hit-private-hit'));
    await tester.enterText(query, 'fixture query');
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(hit, findsOneWidget);

    runtime.setLocked(true);
    await tester.pumpAndSettle();
    expect(hit, findsNothing);
    expect(query, findsNothing);
    runtime.setLocked(false);
    await tester.pumpAndSettle();
    expect(submit, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
