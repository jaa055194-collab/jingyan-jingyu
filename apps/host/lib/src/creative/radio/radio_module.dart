/// CR-07 电台模块：登记 [RadioService]、驱动后台调度，并暴露本人只读 HTTP 路由。
///
/// 路由（只读、需登录、按 owner 隔离）：
/// * `GET /creative/radio` → 当前调用者的全部电台期次
/// * `GET /creative/radio/{aiId}/{dateKey}` → 某一晚的电台（离线缓存可听）
/// 非本人/不存在一律 404（防探测）。
///
/// 默认宿主已注册该模块。生成调度器仅在逐用户时区、授权与生产源接通后显式启用。
library;

import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

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
  void mount(Router router) {
    router.get(Routes.creativeRadio, _list);
    router.get(Routes.creativeRadioEpisode, _get);
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
    final episodes = await service.listForOwner(owner);
    return HostResponse.ok({
      'episodes': [for (final episode in episodes) episode.toPayload()],
    });
  }

  Future<HostResponse> _get(HostRequest request) async {
    final owner = request.principal!.accountId;
    final aiId = request.pathParams['aiId']!;
    final dateKey = request.pathParams['dateKey']!;
    try {
      validateId(aiId, kind: 'ai');
      validateId(dateKey, kind: 'dateKey');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad id'),
      );
    }
    final result = await service.getEpisode(
      ownerAccountId: owner,
      aiId: aiId,
      dateKey: dateKey,
    );
    return HostResponse.fromResult(result, (episode) => episode.toPayload());
  }
}
