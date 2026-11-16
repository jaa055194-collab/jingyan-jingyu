/// M12 lifecycle 宿主模块：装配 quota / 清理 / 导出导入 / 离开。
///
/// 按 docs/architecture/01-layering.md 的宿主模块形状：本文件只做装配与后台调度，
/// 具体逻辑在各自服务文件里，且都通过抽象接口 + 内存实现交付。
///
/// 路由：`jingyu_protocol` 尚未分配 M12 路由常量；本切片不改共享 `routes.dart`，
/// 也不在 [mount] 里硬编码路径字符串。上线路由与 `defaultModules` 装配补丁见
/// `requirements-traceability.md` 与交付报告。
library;

import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';

import '../audit/audit_log.dart';
import 'cleanup.dart';
import 'departure.dart';
import 'export.dart';
import 'import.dart';
import 'quota_service.dart';

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
    );
  }

  LifecycleModule._({
    required this.clock,
    required this.quota,
    required this.cleanup,
    required this.exportService,
    required this.importService,
    required this.departure,
  });

  final Clock clock;
  final QuotaService quota;
  final CleanupService cleanup;
  final ExportService exportService;
  final ImportService importService;
  final DepartureService departure;

  Timer? _cleanupTimer;
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
  Future<void> start() async {
    _running = true;
    _scheduleNextCleanup();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  void _scheduleNextCleanup() {
    if (!_running) return;
    final now = clock.now();
    final delay = CleanupService.nextScheduledRun(now).difference(now);
    _cleanupTimer = Timer(delay, () async {
      try {
        await cleanup.run();
      } catch (_) {
        // 单次清理失败不终止调度；次日继续。
      }
      _scheduleNextCleanup();
    });
  }
}
