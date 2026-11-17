/// Application module catalog for the shell test harness.
///
/// Pure data: it describes which product modules the shell can route to and
/// whether each is actually implemented. It performs no I/O and grants no
/// capability. Placeholder/unavailable modules never fake success so the panel
/// and tests report honest availability.
library;

enum ModuleAvailability { available, placeholder, unavailable }

class AppModule {
  const AppModule({
    required this.id,
    required this.title,
    required this.description,
    required this.availability,
  });

  final String id;
  final String title;
  final String description;
  final ModuleAvailability availability;

  String get availabilityLabel => switch (availability) {
    ModuleAvailability.available => '已实现',
    ModuleAvailability.placeholder => '占位',
    ModuleAvailability.unavailable => '未接入',
  };
}

/// Current shell modules. Mirrors the shell's five destinations plus settings
/// and the own-AI consent surface. `world` is an independent module (FR-12)
/// whose 3D renderer is not yet wired into the Flutter shell.
const List<AppModule> appModules = <AppModule>[
  AppModule(
    id: 'chat',
    title: '聊天',
    description: '私聊/群聊、发件箱与同步',
    availability: ModuleAvailability.available,
  ),
  AppModule(
    id: 'contacts',
    title: '联系人',
    description: '好友与关系（宿主联系人接口未接入）',
    availability: ModuleAvailability.placeholder,
  ),
  AppModule(
    id: 'moments',
    title: '动态',
    description: '动态流（宿主未接入）',
    availability: ModuleAvailability.placeholder,
  ),
  AppModule(
    id: 'inbox',
    title: '收件箱',
    description: '邀请与通知（宿主未接入）',
    availability: ModuleAvailability.placeholder,
  ),
  AppModule(
    id: 'world',
    title: '世界与形象',
    description: '3D 街区与 AI 形象（独立模块，渲染尚未接入 Flutter 外壳）',
    availability: ModuleAvailability.unavailable,
  ),
  AppModule(
    id: 'own-ai-consent',
    title: '我的 AI 私聊授权',
    description: '显式开启/撤回本人 AI 私聊（正文与已保存人格）',
    availability: ModuleAvailability.available,
  ),
  AppModule(
    id: 'settings',
    title: '设置',
    description: '隐私、外观与账户',
    availability: ModuleAvailability.available,
  ),
];

/// The module with the given id, or null when unknown.
AppModule? findModule(String id) {
  for (final module in appModules) {
    if (module.id == id) return module;
  }
  return null;
}
