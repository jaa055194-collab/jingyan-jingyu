/// 插件宿主：校验清单、按能力授权、收集贡献、隔离失败。
library;

import 'dart:async';

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
  const PluginEnvironment({
    required this.platform,
    required this.isHostMachine,
  });

  /// `android` 或 `windows`。
  final String platform;

  /// 是否运行在宿主机上（决定通用 hostOnly 插件能否加载）。
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
  bool has(PluginCapability capability) =>
      _active && _caps.contains(capability);

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
  final Map<String, SlashCommand> _commands = {};
  final List<RoomGenerator> _roomGenerators = [];
  final Map<String, Object> _cards = {};
  final List<MapEntry<String, Object>> _settings = [];

  @override
  void addSlashCommand(SlashCommand command) {
    context._require(PluginCapability.slashCommands);
    final owner = _host._commandOwners[command.name];
    if (owner != null) {
      throw StateError('斜杠指令 /${command.name} 已被 ${owner.context.pluginId} 注册');
    }
    _commands[command.name] = command;
    _host._commandOwners[command.name] = this;
    if (!_host._pending.containsValue(this)) {
      _host._commands[command.name] = command;
    }
  }

  @override
  void addRoomGenerator(RoomGenerator generator) {
    context._require(PluginCapability.roomScene);
    _roomGenerators.add(generator);
    if (!_host._pending.containsValue(this)) {
      _host._roomGenerators.add(generator);
    }
  }

  @override
  void addMessageCard(String cardType, Object renderer) {
    context._require(PluginCapability.messageRenderer);
    if (_host._cardOwners.containsKey(cardType)) {
      throw StateError('消息卡片 $cardType 已注册');
    }
    _cards[cardType] = renderer;
    _host._cardOwners[cardType] = this;
    if (!_host._pending.containsValue(this)) {
      _host._cards[cardType] = renderer;
    }
  }

  @override
  void addSettingsSection(String title, Object builder) {
    context._require(PluginCapability.settingsPage);
    final section = MapEntry(title, builder);
    _settings.add(section);
    if (!_host._pending.containsValue(this)) {
      _host._settings.add(section);
    }
  }
}

// Async descendants inherit this object, but lose reentrant status when cleanup ends.
class _CleanupScope {
  bool active = true;
}

/// 插件宿主。
class PluginHost {
  PluginHost({required this.environment, required SendText sendText})
    : _sendText = sendText;

  final PluginEnvironment environment;
  final SendText _sendText;

  final Map<String, ClientPlugin> _active = {};
  final Map<String, _Registrar> _registrars = {};
  final Map<String, _Registrar> _pending = {};
  // Keep cancelled activations reserved until their eventual resource cleanup ends.
  final Set<ClientPlugin> _instances = Set<ClientPlugin>.identity();
  final List<PluginLoadError> errors = [];

  // A reentrant unload from deactivate must not await its own completion.
  final Object _unloadZoneKey = Object();
  Future<void>? _unloading;

  final Map<String, SlashCommand> _commands = {};
  // Reservations include pending activations; only committed contributions are visible.
  final Map<String, _Registrar> _commandOwners = {};
  final Map<String, _Registrar> _cardOwners = {};
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
    } else if (_unloading != null) {
      reject = '插件宿主正在停用';
    } else if (_active.containsKey(m.id) || _pending.containsKey(m.id)) {
      reject = '插件 id 重复';
    } else if (_instances.contains(plugin)) {
      reject = '插件实例仍在激活或清理';
    }
    if (reject != null) {
      errors.add(PluginLoadError(m.id, reject));
      return false;
    }

    final context = _Context(m.id, m.capabilities, _sendText);
    final registrar = _Registrar(this, context);
    // Reserve before calling plugin code, including synchronous reentrant load.
    _pending[m.id] = registrar;
    _instances.add(plugin);
    try {
      await plugin.activate(registrar);
      if (!identical(_pending[m.id], registrar)) {
        throw StateError('激活已被停用取消');
      }
    } catch (error) {
      context.invalidate();
      // A stale activation must never remove a newer instance's reservations.
      _commandOwners.removeWhere((_, owner) => identical(owner, registrar));
      _cardOwners.removeWhere((_, owner) => identical(owner, registrar));
      final cancelled = !identical(_pending[m.id], registrar);
      if (!cancelled) _pending.remove(m.id);
      if (cancelled) {
        // unloadAll cannot wait for activate: activate may itself await unloadAll.
        // Once it settles, release resources exactly once before allowing object reuse.
        try {
          await _deactivate(plugin);
        } catch (_) {}
      }
      _instances.remove(plugin);
      errors.add(PluginLoadError(m.id, '激活失败：$error'));
      return false;
    }
    // No await between validation and publishing all contributions with their context.
    _pending.remove(m.id);
    _active[m.id] = plugin;
    _registrars[m.id] = registrar;
    _commands.addAll(registrar._commands);
    _roomGenerators.addAll(registrar._roomGenerators);
    _cards.addAll(registrar._cards);
    _settings.addAll(registrar._settings);
    return true;
  }

  Future<void> _deactivate(ClientPlugin plugin) async {
    // An active cleanup may be awaited by a different unload, even across
    // generations. Revoke its inherited reentrant status as soon as it settles.
    final scope = _CleanupScope();
    try {
      await runZoned(plugin.deactivate, zoneValues: {_unloadZoneKey: scope});
    } finally {
      scope.active = false;
    }
  }

  /// 停用全部插件（逆序），单个失败不阻断。
  ///
  /// 同步撤销 active/pending 上下文，不等待尚未结束的 activate。
  /// 停用期间拒绝 load；普通并发调用等待同一次清理，deactivate 内重入立即返回。
  Future<void> unloadAll() {
    final unloading = _unloading;
    if (unloading != null) {
      final scope = Zone.current[_unloadZoneKey];
      return scope is _CleanupScope && scope.active
          ? Future<void>.value()
          : unloading;
    }
    final completion = Completer<void>();
    _unloading = completion.future;
    final plugins = _active.values.toList().reversed.toList();
    for (final registrar in [..._registrars.values, ..._pending.values]) {
      registrar.context.invalidate();
    }
    _active.clear();
    _registrars.clear();
    _pending.clear();
    _commands.clear();
    _commandOwners.clear();
    _cardOwners.clear();
    _roomGenerators.clear();
    _cards.clear();
    _settings.clear();
    unawaited(() async {
      try {
        for (final plugin in plugins) {
          try {
            await _deactivate(plugin);
          } catch (_) {
            // One plugin's cleanup must not stop the remaining plugins.
          } finally {
            _instances.remove(plugin);
          }
        }
      } finally {
        _unloading = null;
        completion.complete();
      }
    }());
    return completion.future;
  }

  List<String> get activeIds => _active.keys.toList();

  /// 当前可用的斜杠指令。[boundCapabilities] 为当前 AI 已绑定的能力。
  List<SlashCommand> commandsFor(Set<String> boundCapabilities) => [
    for (final c in _commands.values)
      if (c.requiresAiCapability == null ||
          boundCapabilities.contains(c.requiresAiCapability))
        c,
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
    return command.run(args, owner.context);
  }

  List<RoomGenerator> get roomGenerators => List.unmodifiable(_roomGenerators);
  Object? cardRenderer(String cardType) => _cards[cardType];
  List<MapEntry<String, Object>> get settingsSections =>
      List.unmodifiable(_settings);
}
