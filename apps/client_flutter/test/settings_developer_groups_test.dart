import 'package:client_flutter/features/lifecycle/backup_quota_screen.dart';
import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:client_flutter/features/world/world_status_screen.dart';
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

  for (final (key, screenType) in [
    ('open-lifecycle-status', BackupQuotaScreen),
    ('open-world-status', WorldStatusScreen),
  ]) {
    testWidgets('$key opens $screenType', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsScreen(model: TestShellModel(), onBack: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Each case starts at the top; going back from a pushed route restores
      // the previous scroll offset, which can be below an earlier entry.
      final entry = find.byKey(Key(key));
      await tester.scrollUntilVisible(entry, 200);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(screenType), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byType(screenType), findsNothing);
    });
  }
}
