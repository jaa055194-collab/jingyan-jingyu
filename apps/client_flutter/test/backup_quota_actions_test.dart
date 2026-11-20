import 'package:client_flutter/features/lifecycle/backup_files.dart';
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

LifecycleExportBundle _bundle({bool chatOnly = false}) =>
    LifecycleExportBundle.fromJson({
      'ownerAccountId': 'owner',
      'files': {
        'manifest.json': '{}',
        'persona.json': '{"name":"secret-persona-text"}',
      },
      'manifest': {
        'formatVersion': 1,
        if (chatOnly)
          'coverage': {
            'scope': 'chatHistory',
            'completeAccountExport': false,
            'pendingDomains': ['persona', 'memories', 'attachments'],
          },
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

class _FakeBackupFiles implements BackupFileStore {
  SavedBackupFile? result = const SavedBackupFile(
    name: 'jingyu-export.json',
    bytes: 12,
  );
  Object? error;
  int calls = 0;
  LifecycleExportBundle? lastBundle;

  @override
  Future<SavedBackupFile?> save(LifecycleExportBundle bundle) async {
    calls++;
    lastBundle = bundle;
    final failure = error;
    if (failure != null) throw failure;
    return result;
  }
}

class _FakeApi extends LifecycleApi {
  _FakeApi() : super(HostConnection(Uri.parse('http://127.0.0.1:1'), 'token'));

  LifecycleExportBundle? exportResult;
  Object? exportError;
  LifecycleImportMode? importModeEcho;
  Object? importError;
  int exportCalls = 0;
  int importCalls = 0;
  int previewCalls = 0;
  Object? previewError;
  LifecycleCleanupPreview preview = LifecycleCleanupPreview.fromJson({
    'dayKey': '2026-03-01',
    'remindSoon': {'video': 1, 'voice': 0},
    'expiring': {'video': 2, 'voice': 1},
    'totalHeld': {'video': 3, 'voice': 4},
  });
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
  Future<LifecycleCleanupPreview> readCleanupPreview({
    bool retryAuthentication = true,
  }) async {
    previewCalls++;
    final error = previewError;
    if (error != null) throw error;
    return preview;
  }

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
  Future<void> pump(
    WidgetTester tester,
    LifecycleApi api, {
    BackupFileStore? backupFiles,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BackupQuotaScreen(api: api, backupFiles: backupFiles),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> ensureVisible(WidgetTester tester, String key) async {
    await tester.scrollUntilVisible(
      find.byKey(Key(key)),
      300,
      scrollable: find.byType(Scrollable).first,
    );
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

  testWidgets(
    'partial chat export identifies missing domains without file contents',
    (tester) async {
      final api = _FakeApi()..exportResult = _bundle(chatOnly: true);
      await pump(tester, api);
      await tapKey(tester, 'export-lifecycle');
      expect(find.textContaining('当前仅导出有权读取的聊天记录'), findsOneWidget);
      expect(find.textContaining('不包含人格、记忆和附件内容'), findsOneWidget);
      expect(find.textContaining('不是完整账号备份'), findsOneWidget);
      expect(find.textContaining('secret-persona-text'), findsNothing);
      expect(api.importCalls, 0);
    },
  );

  testWidgets(
    'save action appears only after export and passes the exact bundle',
    (tester) async {
      final api = _FakeApi();
      final files = _FakeBackupFiles();
      await pump(tester, api, backupFiles: files);
      final saveButton = find.byKey(const Key('save-lifecycle'));
      expect(saveButton, findsOneWidget);
      expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);

      await tapKey(tester, 'export-lifecycle');
      expect(find.byKey(const Key('save-lifecycle')), findsOneWidget);
      expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);
      expect(files.calls, 0);

      await tapKey(tester, 'save-lifecycle');
      expect(files.calls, 1);
      expect(files.lastBundle?.files, _bundle().files);
      expect(find.textContaining('已保存导出文件：jingyu-export.json'), findsOneWidget);
      expect(find.textContaining('文件含聊天明文'), findsOneWidget);
      expect(find.textContaining('12 B'), findsOneWidget);
      expect(find.textContaining('secret-persona-text'), findsNothing);
      expect(find.textContaining(r'C:\private'), findsNothing);
      expect(api.importCalls, 0);
    },
  );

  testWidgets('saving cancellation is reported without a retry', (
    tester,
  ) async {
    final api = _FakeApi();
    final files = _FakeBackupFiles()..result = null;
    await pump(tester, api, backupFiles: files);
    await tapKey(tester, 'export-lifecycle');
    await tapKey(tester, 'save-lifecycle');
    expect(files.calls, 1);
    expect(find.textContaining('已取消保存'), findsOneWidget);
  });

  testWidgets('saving failure is honest and hides platform details', (
    tester,
  ) async {
    final api = _FakeApi();
    final files = _FakeBackupFiles()
      ..error = StateError(r'C:\private\export.json failed');
    await pump(tester, api, backupFiles: files);
    await tapKey(tester, 'export-lifecycle');
    await tapKey(tester, 'save-lifecycle');
    expect(find.textContaining('导出文件保存失败或结果未确认'), findsOneWidget);
    expect(find.textContaining('private'), findsNothing);
  });

  testWidgets(
    'without a save platform export stays usable but save is disabled',
    (tester) async {
      final api = _FakeApi();
      await pump(tester, api);
      expect(find.textContaining('未接线本机文件保存'), findsOneWidget);
      await tapKey(tester, 'export-lifecycle');
      expect(find.textContaining('已导出到内存'), findsOneWidget);
      final save = find.byKey(const Key('save-lifecycle'));
      expect(save, findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
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

  testWidgets('cleanup stays non-destructive: no execute button remains', (
    tester,
  ) async {
    await pump(tester, _FakeApi());
    // The old disabled "cleanup" button is replaced by a read-only preview.
    expect(find.byKey(const Key('cleanup-lifecycle')), findsNothing);
    await ensureVisible(tester, 'cleanup-execution-gap');
    expect(find.textContaining('执行尚未提供'), findsOneWidget);
    expect(find.textContaining('不会删除任何数据'), findsOneWidget);
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

  testWidgets('cleanup section shows read-only preview with execution gap', (
    tester,
  ) async {
    final api = _FakeApi();
    await pump(tester, api);
    await ensureVisible(tester, 'cleanup-execution-gap');
    expect(api.previewCalls, 1);
    expect(find.textContaining('运行日：2026-03-01'), findsOneWidget);
    expect(find.textContaining('视频：1'), findsOneWidget);
    expect(find.textContaining('视频：2'), findsOneWidget);
    expect(find.textContaining('视频：3'), findsOneWidget);
    expect(find.textContaining('语音：1'), findsOneWidget);
    expect(find.textContaining('语音：4'), findsOneWidget);
    expect(find.textContaining('执行尚未提供'), findsOneWidget);
    // Non-destructive: cleanup is a preview, never an execution button.
    expect(find.byKey(const Key('cleanup-lifecycle')), findsNothing);
    expect(find.byKey(const Key('cleanup-preview-refresh')), findsOneWidget);
  });

  testWidgets('cleanup preview refresh reloads counts explicitly', (
    tester,
  ) async {
    final api = _FakeApi();
    await pump(tester, api);
    api.preview = LifecycleCleanupPreview.fromJson({
      'dayKey': '2026-03-02',
      'remindSoon': {'video': 0, 'voice': 2},
      'expiring': {'video': 0, 'voice': 0},
      'totalHeld': {'video': 1, 'voice': 2},
    });
    await ensureVisible(tester, 'cleanup-preview-refresh');
    await tester.tap(find.byKey(const Key('cleanup-preview-refresh')));
    await tester.pumpAndSettle();
    expect(api.previewCalls, 2);
    expect(find.textContaining('运行日：2026-03-02'), findsOneWidget);
    expect(find.textContaining('语音：2'), findsWidgets);
    expect(find.textContaining('视频：0'), findsWidgets);
  });

  testWidgets('cleanup preview failure is honest without details', (
    tester,
  ) async {
    final api = _FakeApi()
      ..previewError = const HostRequestException(
        Failure(FailureCode.unavailable, 'secret-cleanup-xyz'),
      );
    await pump(tester, api);
    await ensureVisible(tester, 'cleanup-preview-unknown');
    expect(find.textContaining('清理预览读取失败'), findsOneWidget);
    expect(find.textContaining('secret-cleanup-xyz'), findsNothing);
    // No automatic retry: preview stays unknown until an explicit refresh.
    expect(api.previewCalls, 1);
    await tester.ensureVisible(
      find.byKey(const Key('cleanup-preview-refresh')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cleanup-preview-refresh')));
    await tester.pumpAndSettle();
    expect(api.previewCalls, 2);
    expect(find.textContaining('执行尚未提供'), findsOneWidget);
  });

  testWidgets('no api keeps the honest cleanup gap text', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: BackupQuotaScreen(loadQuota: null, loadSurvey: null),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cleanup-execution-gap')).evaluate().length, 1);
    expect(find.textContaining('宿主未提供清理 HTTP 接口'), findsOneWidget);
  });
}
