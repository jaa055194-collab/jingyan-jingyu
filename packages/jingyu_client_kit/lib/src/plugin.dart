/// 插件契约（需求方 2026-11-13 答复第 14 条：规范插件模式，后续加功能不大改软件）。
///
/// 一个插件 = 一份 [PluginManifest] + 一个 [ClientPlugin] 实现。
/// 插件只能通过 [PluginContext] 拿到被授权的能力，拿不到宿主内部对象。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

/// Host evaluates visibility, external-model restrictions and AI budget.
/// Plugins never receive credentials or direct network access.
class PluginModelRequest {
  const PluginModelRequest({
    required this.aiId,
    required this.capability,
    required this.input,
    this.conversationId,
  });
  final String aiId;
  final String capability;
  final String? conversationId;
  final Map<String, Object?> input;
}

/// 插件可申请的能力。未在清单里声明的能力，运行时一律拿不到。
enum PluginCapability {
  /// 读取当前会话的消息（只读，且受服务端可见性约束）。
  readConversation,

  /// 以当前用户身份发送消息（仍走发件箱与幂等）。
  sendMessage,

  /// 注册斜杠指令（FR-60）。
  slashCommands,

  /// 在设置页添加一个分区。
  settingsPage,

  /// 渲染自定义消息卡片（按 card 类型）。
  messageRenderer,

  /// 3D 房间/街区扩展：家具、场景、房间生成（FR-35、需求方第 13 条）。
  roomScene,

  /// 调用宿主暴露的模型能力（计入该 AI 的预算，FR-48/58）。
  modelInvoke,

  /// 插件私有键值存储（按插件 id 隔离）。
  localStorage,
}

/// 扩展点：插件把贡献挂到这些位置。
enum ExtensionSlot {
  slashCommand,
  settingsSection,
  messageCard,
  roomGenerator,
  roomFurniture,
  sessionHeader,
}

/// 插件清单。放在插件目录的 `plugin.json`，字段与本类一一对应。
class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.apiVersion,
    this.capabilities = const <PluginCapability>{},
    this.platforms = const {'android', 'windows'},
    this.hostOnly = false,
    this.license,
    this.assetCredits = const <String>[],
  });

  /// 反向域名风格的唯一 id，例如 `jingyu.room.generator`。
  final String id;
  final String name;

  /// 插件自身版本（语义化版本）。
  final String version;

  /// 依赖的插件 API 主版本。与 [pluginApiVersion] 不同则拒绝加载。
  final int apiVersion;

  final Set<PluginCapability> capabilities;

  /// 适用平台。
  final Set<String> platforms;

  /// 仅宿主机客户端可用（例如 Live2D `.moc3` 导入，FR-38/39）。
  final bool hostOnly;

  /// 插件代码许可证（SPDX 标识）。
  final String? license;

  /// 随插件分发的素材署名（CC 素材必须保留署名，见 docs/plugins/02-assets.md）。
  final List<String> assetCredits;

  static final RegExp _idPattern = RegExp(
    r'^[a-z][a-z0-9]*(\.[a-z][a-z0-9_-]*)+$',
  );
  static final RegExp _semver = RegExp(r'^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$');

  /// 从 `plugin.json` 解析。失败抛 [FormatException]，不做宽松兜底。
  factory PluginManifest.fromJson(Map<String, Object?> json) {
    String str(String key) {
      final v = json[key];
      if (v is String && v.isNotEmpty) return v;
      throw FormatException('plugin.json 缺少字段 $key');
    }

    final id = str('id');
    if (!_idPattern.hasMatch(id)) throw FormatException('插件 id 非法', id);
    final version = str('version');
    if (!_semver.hasMatch(version)) {
      throw FormatException('version 不是语义化版本', version);
    }
    final api = json['apiVersion'];
    if (api is! int) throw const FormatException('apiVersion 必须是整数');

    final caps = <PluginCapability>{};
    final rawCaps = json['capabilities'] ?? const <Object?>[];
    if (rawCaps is! List) throw const FormatException('capabilities 必须是数组');
    for (final c in rawCaps) {
      final match = PluginCapability.values.where((v) => v.name == c);
      if (match.isEmpty) throw FormatException('未知能力', '$c');
      caps.add(match.first);
    }

    final rawPlatforms = json['platforms'] ?? const ['android', 'windows'];
    if (rawPlatforms is! List ||
        rawPlatforms.any((p) => p != 'android' && p != 'windows')) {
      throw const FormatException('platforms 只允许 android / windows');
    }

    final credits = json['assetCredits'] ?? const <Object?>[];
    if (credits is! List || credits.any((c) => c is! String)) {
      throw const FormatException('assetCredits 必须是字符串数组');
    }

    return PluginManifest(
      id: id,
      name: str('name'),
      version: version,
      apiVersion: api,
      capabilities: caps,
      platforms: {for (final p in rawPlatforms) p as String},
      hostOnly: json['hostOnly'] == true,
      license: json['license'] as String?,
      assetCredits: [for (final c in credits) c as String],
    );
  }
}

/// 当前插件 API 主版本。破坏性变更时 +1。
const int pluginApiVersion = 1;

/// 斜杠指令贡献。
class SlashCommand {
  const SlashCommand({
    required this.name,
    required this.description,
    required this.run,
    this.requiresAiCapability,
  });

  /// 不带斜杠的指令名，例如 `画图`。
  final String name;
  final String description;

  /// 对应的 AI 能力（chat / image_gen ……）。该能力未绑定时指令自动隐藏（FR-60）。
  final String? requiresAiCapability;

  /// 执行。返回给用户看的提示文字；为 null 表示无提示。
  final Future<String?> Function(String args, PluginContext context) run;
}

/// 房间生成器贡献：根据用户的提示词生成首个房间（需求方第 13 条）。
abstract class RoomGenerator {
  String get id;

  /// 给用户看的风格预设（"海边小屋""森林木屋"……）。
  List<String> get presets;

  /// 由设计 brief 生成房间布局。实现必须只产出布局数据，不执行下载或代码。
  Future<RoomLayout> generate(RoomBrief brief, PluginContext context);
}

/// 用户的房间设计 brief。字段取自 feiyu-room-template 的 brief 模板。
class RoomBrief {
  const RoomBrief({
    required this.style,
    required this.palette,
    required this.mood,
    this.rooms = const <String>[],
    this.notes = '',
  });

  final String style;
  final String palette;
  final String mood;
  final List<String> rooms;
  final String notes;
}

/// 生成的房间布局（服务端保存版本号，FR-35）。
class RoomLayout {
  const RoomLayout({
    required this.style,
    required this.rooms,
    this.furniture = const [],
  });

  final String style;
  final List<String> rooms;

  /// 每件家具：`{kind, room, x, y, rotation}`，坐标单位米。
  final List<Map<String, Object?>> furniture;
}

/// 插件运行时拿到的受限上下文。
abstract class PluginContext {
  String get pluginId;

  /// 是否持有某能力。
  bool has(PluginCapability capability);

  /// 插件私有存储；未申请 localStorage 时抛 [StateError]。
  Map<String, String> get storage;

  /// 发消息；未申请 sendMessage 时抛 [StateError]。
  Future<void> sendText(String conversationId, String text);

  /// Host callback must enforce server visibility for the signed-in user.
  Future<Result<List<MessageEventFrame>>> readConversation(
    String conversationId,
  ) {
    if (!has(PluginCapability.readConversation)) {
      throw StateError('readConversation not declared');
    }
    return Future.value(
      err(FailureCode.unavailable, 'Conversation access unavailable'),
    );
  }

  /// Host callback must enforce AI budget and disallow external invocation for
  /// ephemeral/private/group content. This context supplies no direct network.
  Future<Result<Map<String, Object?>>> modelInvoke(PluginModelRequest request) {
    if (!has(PluginCapability.modelInvoke)) {
      throw StateError('modelInvoke not declared');
    }
    return Future.value(
      err(FailureCode.unavailable, 'Model invocation unavailable'),
    );
  }
}

/// 插件入口。
abstract class ClientPlugin {
  PluginManifest get manifest;

  /// 激活：在这里注册贡献。不得做阻塞 IO。
  Future<void> activate(PluginRegistrar registrar);

  /// 停用：释放资源。需幂等。
  Future<void> deactivate() async {}
}

/// 激活时用于登记贡献的对象。每个方法会检查对应能力。
abstract class PluginRegistrar {
  PluginContext get context;

  void addSlashCommand(SlashCommand command);

  void addRoomGenerator(RoomGenerator generator);

  /// 自定义消息卡片：[cardType] 对应消息 body 里的 `cardType`。
  void addMessageCard(String cardType, Object renderer);

  /// 设置页分区；[builder] 由 Flutter 外壳解释（返回 Widget）。
  void addSettingsSection(String title, Object builder);
}
