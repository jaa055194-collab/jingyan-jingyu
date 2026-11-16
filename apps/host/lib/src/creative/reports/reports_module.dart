/// CR-03 报告模块：把 [ReportsService] 登记为宿主服务并驱动后台调度。
///
/// 路由与装配建议（本切片不改 `jingyu_host.dart`、不改共享 routes）：
/// * 在 `packages/jingyu_protocol/lib/src/routes.dart` 增加
///   `GET /creative/reports/{kind}/{periodKey}` 与 `GET /creative/reports`；
/// * 在 `apps/host/lib/jingyu_host.dart` 的 `defaultModules` 追加
///   `ReportsModule(service: ReportsService(...))`。
library;

import 'dart:async';

import 'package:jingyu_host_kit/jingyu_host_kit.dart';

import 'reports_service.dart';

class ReportsModule extends HostModule {
  ReportsModule({
    required this.service,
    this.tickInterval = const Duration(minutes: 1),
    this.enableTimer = true,
  });

  final ReportsService service;
  final Duration tickInterval;
  final bool enableTimer;
  Timer? _timer;

  @override
  String get name => 'creative_reports';

  @override
  Future<void> configure(HostServices services) async {
    services.provide<ReportsService>(service, owner: name);
  }

  @override
  Future<void> start() async {
    if (!enableTimer) return;
    _timer = Timer.periodic(tickInterval, (_) async {
      try {
        await service.tick();
      } catch (_) {
        // 单次 tick 失败在下一轮重试；不得让调度崩溃。
      }
    });
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }
}
