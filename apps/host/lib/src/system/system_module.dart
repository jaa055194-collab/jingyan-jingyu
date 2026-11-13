/// 系统模块：健康检查与宿主信息。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../audit/audit_log.dart';
import '../config.dart';
import '../security/url_guard.dart';

/// 系统模块：登记时钟、审计、出站防护，提供 health/host 路由。
class SystemModule extends HostModule {
  SystemModule({
    required this.config,
    this.clock = const SystemClock(),
    AuditLog? audit,
    UrlGuard? urlGuard,
  })  : audit = audit ?? InMemoryAuditLog(clock: clock),
        urlGuard = urlGuard ?? UrlGuard();

  final HostConfig config;
  final Clock clock;
  final AuditLog audit;
  final UrlGuard urlGuard;
  late HostServices _services;
  List<String> Function() moduleNames = () => const [];

  @override
  String get name => 'system';

  @override
  Future<void> configure(HostServices services) async {
    _services = services;
    services
      ..provide<Clock>(clock, owner: name)
      ..provide<AuditLog>(audit, owner: name)
      ..provide<UrlGuard>(urlGuard, owner: name);
  }

  @override
  void mount(Router router) {
    router.get(Routes.health, (_) async => HostResponse.ok({'status': 'ok'}), access: Access.public);
    router.get(
      Routes.hostInfo,
      (_) async => HostResponse.ok({
        'hostVersion': config.hostVersion,
        'protocolVersion': protocolVersion,
        'modules': moduleNames(),
        'services': _services.describe().keys.toList()..sort(),
      }),
      access: Access.admin,
    );
  }
}
