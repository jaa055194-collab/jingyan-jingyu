import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

const _readOnlyKeys = <String>[
  'open-module-test',
  'open-world-status',
  'open-voice-profile',
  'open-ai-config',
  'open-lifecycle-status',
];

void main() {
  testWidgets('developer section groups read-only and write entries', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(model: TestShellModel(), onBack: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('只读检查'), 200);
    await tester.pumpAndSettle();
    expect(find.text('只读检查'), findsOneWidget);

    for (final key in _readOnlyKeys) {
      await tester.scrollUntilVisible(find.byKey(Key(key)), 200);
      await tester.pumpAndSettle();
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }

    await tester.scrollUntilVisible(
      find.byKey(const Key('open-ai-config-write')),
      200,
    );
    await tester.pumpAndSettle();
    expect(find.text('AI 运行配置编辑'), findsOneWidget);
    expect(find.byKey(const Key('open-ai-config-write')), findsOneWidget);
  });

  testWidgets('read-only entries still open their original screens', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(model: TestShellModel(), onBack: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> open(String key) async {
      final finder = find.byKey(Key(key));
      await tester.scrollUntilVisible(finder, 200);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    await open('open-lifecycle-status');
    expect(find.text('配额与生命周期状态'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await open('open-world-status');
    expect(find.text('世界状态'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
  });
}
