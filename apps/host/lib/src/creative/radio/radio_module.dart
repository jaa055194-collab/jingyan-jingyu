/// CR-07 电台模块：把 [RadioService] 登记为宿主服务并驱动后台调度。
///
/// 路由与装配建议（本切片不改 `jingyu_host.dart`、不改共享 routes）：
/// * 在 `packages/jingyu_protocol/lib/src/routes.dart` 增加
///   `GET /creative/radio/{dateKey}` 与 `GET /creative/radio`；
/// * 在 `apps/host/lib/jingyu_host.dart` 的 `defaultModules` 追加
///   `RadioModule(service: RadioService(...))`。
library;

import 'dart:async';

import 'package:jingyu_host_kit/jingyu_host_kit.dart';

import 'radio_service.dart';

class RadioModule extends HostModule {
  RadioModule({
    required this.service,
    this.tickInterval = const Duration(minutes: 1),
    this.enableTimer = true,
  });

  final RadioService service;
  final Duration tickInterval;
  final bool enableTimer;
  Timer? _timer;

  @override
  String get name => 'creative_radio';

  @override
  Future<void> configure(HostServices services) async {
    services.provide<RadioService>(service, owner: name);
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
