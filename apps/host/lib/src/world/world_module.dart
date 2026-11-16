/// M10 world 宿主模块装配：房间布局、连续街区寻路、presence、形象登记。
///
/// 本模块只交付宿主侧世界能力；3D 渲染、Live2D/VRM 导入与客户端不在本模块。
/// 路由与 `jingyu_host.dart` 的 `defaultModules` 装配属实现建议（见交付报告），
/// 因此这里暂不在 [mount] 声明路由，也避免直接写未定的 `Routes` 常量。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';

import 'avatars.dart';
import 'layout_store.dart';
import 'presence.dart';

/// 世界模块。`name = 'world'`；依赖 social 提供的好友/拉黑判定。
class WorldModule extends HostModule {
  WorldModule({
    SpaceLayoutStore? layouts,
    PresenceService? presence,
    AvatarRegistry? avatars,
    this.clock = const SystemClock(),
  }) : _layouts = layouts ?? InMemorySpaceLayoutStore(clock: clock),
       _presence = presence ?? InMemoryPresenceService(clock: clock),
       _avatars = avatars ?? InMemoryAvatarRegistry(clock: clock);

  final SpaceLayoutStore _layouts;
  final PresenceService _presence;
  final AvatarRegistry _avatars;

  /// 供测试与装配注入；内存实现默认用它派生时间戳。
  final Clock clock;

  @override
  String get name => 'world';

  @override
  List<String> get dependsOn => const <String>['social'];

  @override
  Future<void> configure(HostServices services) async {
    services.provide<SpaceLayoutStore>(_layouts, owner: name);
    services.provide<PresenceService>(_presence, owner: name);
    services.provide<AvatarRegistry>(_avatars, owner: name);
  }
}
