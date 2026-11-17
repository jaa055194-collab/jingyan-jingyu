import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/features/lifecycle/backup_quota_screen.dart';
import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/lifecycle_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

LifecycleQuotaStatus _quota() => LifecycleQuotaStatus.fromJson({
  'usedBytes': 5 * 1024 * 1024,
  'quotaBytes': 20 * 1024 * 1024 * 1024,
  'diskFreeBytes': 100 * 1024 * 1024 * 1024,
  'diskTotalBytes': 200 * 1024 * 1024 * 1024,
});

LifecycleDepartureSurvey _survey() => LifecycleDepartureSurvey.fromJson({
  'objectCounts': {'conversations': 2, 'messages': 3},
  'momentsToAnonymize': 1,
  'totalObjects': 5,
});

void main() {
  testWidgets('renders quota and lifecycle object counts read-only', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BackupQuotaScreen(
          loadQuota: () async => _quota(),
          loadSurvey: () async => _survey(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('配额与生命周期状态'), findsOneWidget);
    expect(find.textContaining('已用：5.0 MiB'), findsOneWidget);
    expect(find.textContaining('配额：20.0 GiB'), findsOneWidget);
    expect(find.textContaining('conversations：2'), findsOneWidget);
    expect(find.textContaining('对象合计：5'), findsOneWidget);
    // No free-form input; explicit actions exist but stay disabled without api.
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('export-lifecycle')), findsOneWidget);
    expect(find.byKey(const Key('import-lifecycle')), findsOneWidget);
    expect(find.byKey(const Key('cleanup-lifecycle')), findsOneWidget);
    expect(find.textContaining('不代表可用'), findsWidgets);
  });

  testWidgets('unknown state when loader fails, without leaking details', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BackupQuotaScreen(
          loadQuota: () async =>
              throw const FormatException('secret-detail-xyz'),
          loadSurvey: () async => _survey(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('lifecycle-unknown')), findsOneWidget);
    expect(find.textContaining('secret-detail-xyz'), findsNothing);
    expect(find.textContaining('状态未知'), findsOneWidget);
  });

  testWidgets('unknown state when no host connection loader is available', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: BackupQuotaScreen()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('lifecycle-unknown')), findsOneWidget);
    expect(find.textContaining('不会自动重试'), findsOneWidget);
  });

  testWidgets('settings developer entry opens the read-only lifecycle screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(model: TestShellModel(), onBack: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const Key('open-lifecycle-status'));
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.text('配额与生命周期状态'), findsOneWidget);
    // Test model is not the runtime, so no connection: honest unknown.
    expect(find.byKey(const Key('lifecycle-unknown')), findsOneWidget);
  });

  test('settings wiring passes LifecycleApi when a host connection exists', () {
    final runtime = ClientRuntime();
    runtime.connection = HostConnection(
      Uri.parse('http://127.0.0.1:1'),
      'token',
    );
    expect(SettingsScreen.lifecycleScreenFor(runtime).api, isNotNull);
    // Without a runtime connection the actions stay honestly disabled.
    expect(SettingsScreen.lifecycleScreenFor(TestShellModel()).api, isNull);
  });
}
