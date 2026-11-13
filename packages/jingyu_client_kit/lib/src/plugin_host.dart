/// 插件宿主：校验清单、按能力授权、收集贡献、隔离失败。
library;

import 'plugin.dart';

/// 加载失败原因。
class PluginLoadError {
  const PluginLoadError(this.pluginId, this.reason);

  final String pluginId;
  final String reason;

  @override
  String toString() => 'PluginLoadError($pluginId: $reason)';
}

/// 运行环境描述。
class PluginEnvironment {
  const PluginEnvironment({required this.platform, required this.isHostMachine});

  /// `android` 或 `windows`。
  final String platform;

  /// 是否运行在宿主机上（决定 hostOnly 插件能否加载，FR-38/39）。
  final bool isHostMachine;
}

/// 发送消息的回调，由外壳接到发件箱上。
typedef SendText = Future<void> Function(String conversationId, String text);

class _Context implements PluginContext {
  _Context(this.pluginId, Set<PluginCapability> caps, this._send)
      : _caps = Set.unmodifiable(caps);

  @override
  final String pluginId;
  final Set<PluginCapability> _caps;
  final SendText _send;
  final Map<String, String> _storage = {};
  bool _active = true;

  void invalidate() {
    _active = false;
    _storage.clear();
  }

  @override
  bool has(PluginCapability capability) => _active && _caps.contains(capability);

  void _require(PluginCapability capability) {
    if (!has(capability)) {
      throw StateError('插件 $pluginId 未在清单中声明能力 ${capability.name}');
    }
  }

  @override
  Map<String, String> get storage {
    _require(PluginCapability.localStorage);
    return _storage;
  }

  @override
  Future<void> sendText(String conversationId, String text) {
    _require(PluginCapability.sendMessage);
    return _send(conversationId, text);
  }
}

class _Registrar implements PluginRegistrar {
  _Registrar(this._host, this.context);

  final PluginHost _host;
  @override
  final _Context context;

  @override
  void addSlashCommand(SlashCommand command) {
    context._require(PluginCapability.slashCommands);
    if (_host._commands.containsKey(command.name)) {
      throw StateError('斜杠指令 /${command.name} 已被 ${_host._commandOwners[command.name]} 注册');
    }
    _host._commands[command.name] = command;
    _host._commandOwners[command.name] = context.pluginId;
  }

  @override
  void addRoomGenerator(RoomGenerator generator) {
    context._require(PluginCapability.roomScene);
    _host._roomGenerators.add(generator);
  }

  @override
  void addMessageCard(String cardType, Object renderer) {
    context._require(PluginCapability.messageRenderer);
    if (_host._cards.containsKey(cardType)) {
      throw StateError('消息卡片 $cardType 已注册');
    }
    _host._cards[cardType] = renderer;
  }

  @override
  void addSettingsSection(String title, Object builder) {
    context._require(PluginCapability.settingsPage);
    _host._settings.add(MapEntry(title, builder));
  }
}

/// 插件宿主。
class PluginHost {
  PluginHost({required this.environment, required SendText sendText}) : _sendText = sendText;

  final PluginEnvironment environment;
  final SendText _sendText;

  final Map<String, ClientPlugin> _active = {};
  final Map<String, _Context> _contexts = {};
  final List<PluginLoadError> errors = [];

  final Map<String, SlashCommand> _commands = {};
  final Map<String, String> _commandOwners = {};
  final List<RoomGenerator> _roomGenerators = [];
  final Map<String, Object> _cards = {};
  final List<MapEntry<String, Object>> _settings = [];

  /// 加载一个插件。失败时记录到 [errors] 并返回 false，不影响其他插件。
  ///
  /// 激活中途失败时，本次已登记的贡献会全部回滚。
  Future<bool> load(ClientPlugin plugin) async {
    final m = plugin.manifest;
    String? reject;
    if (m.apiVersion != pluginApiVersion) {
      reject = '插件 API 版本 ${m.apiVersion} 与宿主 $pluginApiVersion 不兼容';
    } else if (!m.platforms.contains(environment.platform)) {
      reject = '不支持平台 ${environment.platform}';
    } else if (m.hostOnly && !environment.isHostMachine) {
      reject = '仅宿主机可用';
    } else if (_active.containsKey(m.id)) {
      reject = '插件 id 重复';
    }
    if (reject != null) {
      errors.add(PluginLoadError(m.id, reject));
      return false;
    }

    final snapshot = _snapshot();
    final context = _Context(m.id, m.capabilities, _sendText);
    final registrar = _Registrar(this, context);
    try {
      await plugin.activate(registrar);
    } catch (error) {
      context.invalidate();
      _restore(snapshot);
      errors.add(PluginLoadError(m.id, '激活失败：$error'));
      return false;
    }
    _active[m.id] = plugin;
    _contexts[m.id] = context;
    return true;
  }

  /// 停用全部插件（逆序），单个失败不阻断。
  Future<void> unloadAll() async {
    for (final plugin in _active.values.toList().reversed) {
      try {
        await plugin.deactivate();
      } catch (_) {}
    }
    _active.clear();
    for (final context in _contexts.values) {
      context.invalidate();
    }
    _contexts.clear();
    _commands.clear();
    _commandOwners.clear();
    _roomGenerators.clear();
    _cards.clear();
    _settings.clear();
  }

  List<String> get activeIds => _active.keys.toList();

  /// 当前可用的斜杠指令。[boundCapabilities] 为当前 AI 已绑定的能力。
  List<SlashCommand> commandsFor(Set<String> boundCapabilities) => [
        for (final c in _commands.values)
          if (c.requiresAiCapability == null || boundCapabilities.contains(c.requiresAiCapability)) c,
      ];

  /// 执行斜杠指令。输入形如 `/画图 一只猫`。未知指令返回 null。
  Future<String?> runSlash(String input) async {
    if (!input.startsWith('/')) return null;
    final body = input.substring(1);
    final space = body.indexOf(' ');
    final name = space < 0 ? body : body.substring(0, space);
    final args = space < 0 ? '' : body.substring(space + 1).trim();
    final command = _commands[name];
    if (command == null) return null;
    final owner = _commandOwners[name]!;
    return command.run(args, _contexts[owner]!);
  }

  List<RoomGenerator> get roomGenerators => List.unmodifiable(_roomGenerators);
  Object? cardRenderer(String cardType) => _cards[cardType];
  List<MapEntry<String, Object>> get settingsSections => List.unmodifiable(_settings);

  ({Map<String, SlashCommand> c, Map<String, String> o, List<RoomGenerator> r, Map<String, Object> k, List<MapEntry<String, Object>> s})
      _snapshot() => (c: {..._commands}, o: {..._commandOwners}, r: [..._roomGenerators], k: {..._cards}, s: [..._settings]);

  void _restore(
      ({Map<String, SlashCommand> c, Map<String, String> o, List<RoomGenerator> r, Map<String, Object> k, List<MapEntry<String, Object>> s})
          snap) {
    _commands
      ..clear()
      ..addAll(snap.c);
    _commandOwners
      ..clear()
      ..addAll(snap.o);
    _roomGenerators
      ..clear()
      ..addAll(snap.r);
    _cards
      ..clear()
      ..addAll(snap.k);
    _settings
      ..clear()
      ..addAll(snap.s);
  }
}
