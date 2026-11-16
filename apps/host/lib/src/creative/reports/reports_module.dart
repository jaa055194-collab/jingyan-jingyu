/// CR-03 报告模块：登记 [ReportsService]、驱动后台调度，并暴露本人只读 HTTP 路由。
///
/// 路由（只读、需登录、按 owner 隔离）：
/// * `GET /creative/reports` → 当前调用者的全部报告记录
/// * `GET /creative/reports/{aiId}/{kind}/{periodKey}` → 单份报告
/// 非本人/不存在一律 404（防探测）。
///
/// 装配建议（不改共享 `jingyu_host.dart`）：在 `defaultModules` 追加
/// `ReportsModule(service: ReportsService(...))`，适配器见 `creative_adapters.dart`。
library;

import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'reports_models.dart';
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
  void mount(Router router) {
    router.get(Routes.creativeReports, _list);
    router.get(Routes.creativeReport, _get);
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

  Future<HostResponse> _list(HostRequest request) async {
    final owner = request.principal!.accountId;
    final records = await service.listForOwner(owner);
    return HostResponse.ok({
      'reports': [
        for (final record in records)
          {
            'aiId': record.aiId,
            'kind': record.kind.name,
            'periodKey': record.periodKey,
            'status': record.status.name,
            if (record.report != null) 'report': record.report!.toPayload(),
          },
      ],
    });
  }

  Future<HostResponse> _get(HostRequest request) async {
    final owner = request.principal!.accountId;
    final aiId = request.pathParams['aiId']!;
    final kindRaw = request.pathParams['kind']!;
    final periodKey = request.pathParams['periodKey']!;
    try {
      validateId(aiId, kind: 'ai');
      validateId(periodKey, kind: 'periodKey');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad id'),
      );
    }
    ReportKind? kind;
    for (final candidate in ReportKind.values) {
      if (candidate.name == kindRaw) kind = candidate;
    }
    if (kind == null) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad kind'),
      );
    }
    final result = await service.getReport(
      ownerAccountId: owner,
      aiId: aiId,
      kind: kind,
      periodKey: periodKey,
    );
    return HostResponse.fromResult(result, (report) => report.toPayload());
  }
}
