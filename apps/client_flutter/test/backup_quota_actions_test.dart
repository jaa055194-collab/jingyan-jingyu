import 'package:client_flutter/features/lifecycle/backup_quota_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/lifecycle_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

LifecycleQuotaStatus _quota() => LifecycleQuotaStatus.fromJson({
  'usedBytes': 5 * 1024 * 1024,
  'quotaBytes': 20 * 1024 * 1024 * 1024,
  'diskFreeBytes': 100 * 1024 * 1024 * 1024,
  'diskTotalBytes': 200 * 1024 * 1024 * 1024,
});

LifecycleDepartureSurvey _survey() => LifecycleDepartureSurvey.fromJson({
  'objectCounts': {'conversations': 1, 'messages': 2},
  'momentsToAnonymize': 0,
  'totalObjects': 3,
});

LifecycleExportBundle _bundle() => LifecycleExportBundle.fromJson({
  'ownerAccountId': 'owner',
  'files': {
    'manifest.json': '{}',
    'persona.json': '{"name":"secret-persona-text"}',
  },
  'manifest': {
    'formatVersion': 1,
    'counts': {
      'conversations': 1,
      'messages': 2,
      'memories': 3,
      'attachments': 0,
      'persona': 1,
    },
  },
  'sha256sums': 'deadbeef  manifest.json',
});

LifecycleImportReport _report(LifecycleImportMode mode) =>
    LifecycleImportReport.fromJson({
      'mode': mode.name,
      'checksumVerified': true,
      'imported': {
        'persona': 1,
        'conversations': 1,
        'messages': 2,
        'memories': 3,
        'attachments': 0,
      },
      'conflicts': [],
    });

class _FakeApi extends LifecycleApi {
  _FakeApi() : super(HostConnection(Uri.parse('http://127.0.0.1:1'), 'token'));

  LifecycleExportBundle? exportResult;
  Object? exportError;
  LifecycleImportMode? importModeEcho;
  Object? importError;
  int exportCalls = 0;
  int importCalls = 0;
  LifecycleImportMode? lastMode;
  Map<String, String>? lastFiles;

  @override
  Future<LifecycleQuotaStatus> readQuota({
    bool retryAuthentication = true,
  }) async => _quota();

  @override
  Future<LifecycleDepartureSurvey> readDepartureSurvey({
    bool retryAuthentication = true,
  }) async => _survey();

  @override
  Future<LifecycleExportBundle> exportBundle({
    bool retryAuthentication = true,
  }) async {
    exportCalls++;
    final error = exportError;
    if (error != null) throw error;
    return exportResult ?? _bundle();
  }

  @override
  Future<LifecycleImportReport> importBundle(
    LifecycleExportBundle bundle, {
    required LifecycleImportMode mode,
    bool retryAuthentication = true,
  }) async {
    importCalls++;
    lastMode = mode;
    lastFiles = bundle.files;
    final error = importError;
    if (error != null) throw error;
    return _report(importModeEcho ?? mode);
  }
}

void main() {
  Future<void> pump(WidgetTester tester, LifecycleApi api) async {
    await tester.pumpWidget(MaterialApp(home: BackupQuotaScreen(api: api)));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'explicit export then import renders summaries without file content',
    (tester) async {
      final api = _FakeApi();
      await pump(tester, api);
      expect(find.textContaining('已用：5.0 MiB'), findsOneWidget);

      await tapKey(tester, 'export-lifecycle');
      expect(find.byKey(const Key('lifecycle-action-notice')), findsOneWidget);
      expect(find.textContaining('已导出到内存'), findsOneWidget);
      expect(find.textContaining('secret-persona-text'), findsNothing);
      expect(find.textContaining('manifest.json'), findsNothing);
      expect(api.exportCalls, 1);

      await tapKey(tester, 'import-lifecycle');
      expect(find.byKey(const Key('import-confirm')), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('import-mode-personaAndConversations')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import-confirm')));
      await tester.pumpAndSettle();

      expect(find.textContaining('导入完成'), findsOneWidget);
      expect(find.textContaining('会话 1'), findsOneWidget);
      expect(api.importCalls, 1);
      expect(api.lastMode, LifecycleImportMode.personaAndConversations);
      expect(api.lastFiles, isNotNull);
    },
  );

  testWidgets('cancelling import confirmation performs no import', (
    tester,
  ) async {
    final api = _FakeApi();
    await pump(tester, api);
    await tapKey(tester, 'export-lifecycle');
    await tapKey(tester, 'import-lifecycle');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.importCalls, 0);
  });

  testWidgets('cleanup has no host route: disabled and gap reported', (
    tester,
  ) async {
    await pump(tester, _FakeApi());
    final cleanup = tester.widget<FilledButton>(
      find.byKey(const Key('cleanup-lifecycle')),
    );
    expect(cleanup.onPressed, isNull);
    expect(find.textContaining('宿主未提供清理 HTTP 接口'), findsOneWidget);
  });

  testWidgets('export failure is safe and shows no secret details', (
    tester,
  ) async {
    final api = _FakeApi()
      ..exportError = const HostRequestException(
        Failure(FailureCode.unavailable, 'secret-xyz'),
      );
    await pump(tester, api);
    await tapKey(tester, 'export-lifecycle');
    expect(find.textContaining('导出失败或结果未确认'), findsOneWidget);
    expect(find.textContaining('secret-xyz'), findsNothing);
  });

  testWidgets('without an injected api the write actions stay disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: BackupQuotaScreen(loadQuota: null, loadSurvey: null),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('export-lifecycle')))
          .onPressed,
      isNull,
    );
    expect(find.textContaining('未接线宿主连接'), findsOneWidget);
  });
}
