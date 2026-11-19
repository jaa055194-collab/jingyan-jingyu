/// M12 lifecycle 宿主模块：装配 quota / 清理 / 导出导入 / 离开，并挂载 HTTP 路由。
///
/// 路由常量来自 `Routes.lifecycle*`（只追加，未改既有路径）。所有路由默认要求登录；
/// 处理函数一律以 `request.principal!.accountId` 作为 owner，绝不信任请求体里的账号，
/// 从而实现 owner 隔离；"不存在/无权"统一 404（防探测）。
///
/// 上传预检复用既有 [QuotaService] 的 `UploadGate`：预检占用一个并发名额并返回
/// permitId，记用量时释放名额并累加已用字节；未知/跨账号 permit 一律 404。
library;

import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../audit/audit_log.dart';
import 'cleanup.dart';
import 'departure.dart';
import 'export.dart';
import 'import.dart';
import 'quota.dart';
import 'quota_service.dart';

/// 一次已预检、待记用量的上传。
class _PendingUpload {
  _PendingUpload({
    required this.accountId,
    required this.permit,
    required this.decision,
  });

  final String accountId;
  final UploadPermit permit;
  final QuotaDecision decision;
}

/// 生命周期模块。
class LifecycleModule extends HostModule {
  factory LifecycleModule({
    Clock clock = const SystemClock(),
    AuditLog? audit,
    QuotaService? quota,
    CleanupService? cleanup,
    ExportService? exportService,
    ImportService? importService,
    DepartureService? departure,
    ImportSink? importSink,
  }) {
    final effectiveAudit = audit ?? InMemoryAuditLog(clock: clock);
    return LifecycleModule._(
      clock: clock,
      quota: quota ?? QuotaService(store: InMemoryQuotaStore()),
      cleanup:
          cleanup ??
          CleanupService(
            store: InMemoryCleanupStore(),
            clock: clock,
            audit: effectiveAudit,
          ),
      exportService:
          exportService ??
          ExportService(source: InMemoryExportSource(), clock: clock),
      importService: importService ?? ImportService(),
      departure:
          departure ??
          DepartureService(
            store: InMemoryDepartureStore(),
            clock: clock,
            audit: effectiveAudit,
          ),
      importSink: importSink ?? InMemoryImportSink(),
    );
  }

  LifecycleModule._({
    required this.clock,
    required this.quota,
    required this.cleanup,
    required this.exportService,
    required this.importService,
    required this.departure,
    required this.importSink,
  });

  final Clock clock;
  final QuotaService quota;
  final CleanupService cleanup;
  final ExportService exportService;
  final ImportService importService;
  final DepartureService departure;
  final ImportSink importSink;

  final Map<String, _PendingUpload> _pendingUploads =
      <String, _PendingUpload>{};
  var _uploadSeq = 0;

  Timer? _cleanupTimer;
  Future<void>? _cleanupInFlight;
  bool _running = false;

  @override
  String get name => 'lifecycle';

  @override
  List<String> get dependsOn => const <String>['storage', 'messages'];

  @override
  Future<void> configure(HostServices services) async {
    services
      ..provide<QuotaService>(quota, owner: name)
      ..provide<CleanupService>(cleanup, owner: name)
      ..provide<ExportService>(exportService, owner: name)
      ..provide<ImportService>(importService, owner: name)
      ..provide<DepartureService>(departure, owner: name);
  }

  @override
  void mount(Router router) {
    router.get(Routes.lifecycleQuota, _quotaState);
    router.get(Routes.lifecycleCleanupPreview, _cleanupPreview);
    router.post(Routes.lifecycleUploadPreview, _previewUpload);
    router.post(Routes.lifecycleUploadCommit, _commitUpload);
    router.post(Routes.lifecycleExport, _exportData);
    router.post(Routes.lifecycleImport, _importData);
    router.get(Routes.lifecycleDepartureSurvey, _departureSurvey);
    router.post(Routes.lifecycleDepartureReceipt, _departureReceipt);
  }

  @override
  Future<void> start() async {
    _running = true;
    _scheduleNextCleanup();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    // 存储依赖在本模块停止后才关闭。
    await _cleanupInFlight;
  }

  void _scheduleNextCleanup() {
    if (!_running) return;
    final now = clock.now();
    final delay = CleanupService.nextScheduledRun(now).difference(now);
    _cleanupTimer = Timer(delay, () {
      _cleanupTimer = null;
      _cleanupInFlight = _runScheduledCleanup();
    });
  }

  Future<void> _runScheduledCleanup() async {
    try {
      await cleanup.run();
    } catch (_) {
      // 单次清理失败不终止调度；次日继续。
    } finally {
      _cleanupInFlight = null;
      _scheduleNextCleanup();
    }
  }

  UploadKind? _uploadKind(String raw) {
    for (final kind in UploadKind.values) {
      if (kind.name == raw) return kind;
    }
    return null;
  }

  // --- HTTP 处理函数 ---------------------------------------------------------

  Future<HostResponse> _quotaState(HostRequest request) async {
    final accountId = request.principal!.accountId;
    final used = await quota.usedBytes(accountId);
    final disk = await quota.diskSpace();
    return HostResponse.ok({
      'usedBytes': used,
      'quotaBytes': quota.quotaBytes,
      'diskFreeBytes': disk.freeBytes,
      'diskTotalBytes': disk.totalBytes,
    });
  }

  Future<HostResponse> _cleanupPreview(HostRequest request) async {
    if (request.query.isNotEmpty || request.body != null) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'Invalid cleanup preview'),
      );
    }
    try {
      final preview = await cleanup.retentionPreview(
        ownerAccountId: request.principal!.accountId,
      );
      return HostResponse.ok(preview.toJson());
    } catch (_) {
      // Never surface store/transport details; preview is read-only.
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'Cleanup preview unavailable'),
      );
    }
  }

  Future<HostResponse> _previewUpload(HostRequest request) async {
    final accountId = request.principal!.accountId;
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final json = body.value;
    final kindRaw = json['kind'];
    final bytesRaw = json['uploadBytes'];
    final kind = kindRaw is String ? _uploadKind(kindRaw) : null;
    if (kind == null || bytesRaw is! int || bytesRaw < 0) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad upload preview'),
      );
    }

    final slot = quota.acquireUploadSlot(accountId);
    if (slot.isErr) return HostResponse.failure(slot.failureOrNull!);
    final permit = slot.value;

    final decision = await quota.evaluate(
      accountId: accountId,
      kind: kind,
      uploadBytes: bytesRaw,
    );
    if (decision.isErr) {
      quota.releaseUploadSlot(permit);
      return HostResponse.failure(decision.failureOrNull!);
    }

    final permitId = 'up-${++_uploadSeq}';
    _pendingUploads[permitId] = _PendingUpload(
      accountId: accountId,
      permit: permit,
      decision: decision.value,
    );
    return HostResponse.ok({
      'permitId': permitId,
      'chunkSizeBytes': decision.value.chunkSizeBytes,
      'countedBytes': decision.value.countedBytes,
      'quotaWarning': decision.value.quotaWarning,
      'diskWarning': decision.value.diskWarning,
    });
  }

  Future<HostResponse> _commitUpload(HostRequest request) async {
    final accountId = request.principal!.accountId;
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final permitId = body.value['permitId'];
    if (permitId is! String || permitId.isEmpty) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad permitId'),
      );
    }
    final pending = _pendingUploads[permitId];
    if (pending == null || pending.accountId != accountId) {
      // 未知或跨账号的 permit 都按"不存在"回答，避免探测。
      return HostResponse.failure(
        const Failure(FailureCode.notFound, 'permit not found'),
      );
    }
    _pendingUploads.remove(permitId);
    quota.releaseUploadSlot(pending.permit);
    final committed = await quota.commit(
      accountId: accountId,
      decision: pending.decision,
    );
    if (committed.isErr) return HostResponse.failure(committed.failureOrNull!);
    return HostResponse.ok({
      'countedBytes': pending.decision.countedBytes,
      'usedBytes': await quota.usedBytes(accountId),
    });
  }

  Future<HostResponse> _exportData(HostRequest request) async {
    final accountId = request.principal!.accountId;
    final result = await exportService.export(accountId);
    return HostResponse.fromResult(
      result,
      (bundle) => {
        'ownerAccountId': bundle.ownerAccountId,
        'files': bundle.files,
        'manifest': bundle.manifest(),
        'sha256sums': bundle.sha256Sums(),
      },
    );
  }

  Future<HostResponse> _importData(HostRequest request) async {
    final accountId = request.principal!.accountId;
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final json = body.value;
    final modeRaw = json['mode'];
    final mode = switch (modeRaw) {
      'personaOnly' => ImportMode.personaOnly,
      'personaAndConversations' => ImportMode.personaAndConversations,
      _ => null,
    };
    final filesRaw = json['files'];
    if (mode == null || filesRaw is! Map) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad import request'),
      );
    }
    final files = <String, String>{};
    for (final entry in filesRaw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! String) {
        return HostResponse.failure(
          const Failure(FailureCode.invalidArgument, 'bad files map'),
        );
      }
      files[key] = value;
    }
    final result = await importService.import(
      bundle: ExportBundle(ownerAccountId: accountId, files: files),
      mode: mode,
      ownerAccountId: accountId,
      sink: importSink,
    );
    return HostResponse.fromResult(result, (report) => report.toJson());
  }

  Future<HostResponse> _departureSurvey(HostRequest request) async {
    final accountId = request.principal!.accountId;
    final result = await departure.survey(accountId);
    return HostResponse.fromResult(
      result,
      (survey) => {
        'objectCounts': survey.objectCounts,
        'momentsToAnonymize': survey.momentsToAnonymize,
        'totalObjects': survey.objectCounts.values.fold<int>(
          0,
          (sum, count) => sum + count,
        ),
      },
    );
  }

  Future<HostResponse> _departureReceipt(HostRequest request) async {
    final accountId = request.principal!.accountId;
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final disposition = switch (body.value['aiDisposition']) {
      'transfer' => AiDisposition.transfer,
      'retain' => AiDisposition.retain,
      'delete' => AiDisposition.delete,
      _ => null,
    };
    if (disposition == null) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad aiDisposition'),
      );
    }
    final result = await departure.depart(
      accountId: accountId,
      aiDisposition: disposition,
    );
    return HostResponse.fromResult(result, (receipt) => receipt.toJson());
  }
}
