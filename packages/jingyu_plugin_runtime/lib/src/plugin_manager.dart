/// 插件管理器：安装 / 更新 / 启用 / 停用 / 卸载 / 配置 / 状态持久化。
///
/// 纯 Dart、无 IO：状态读写通过注入的 [PluginManagerStore] 完成，平台适配器由
/// 调用方提供。所有变更都走 copy-on-write：先构造新状态并 `save` 成功，才替换
/// 内存快照；`save` 失败时内存状态保持不变。
///
/// 完整规则见 `design/plugin-runtime-contract.md` §5（ticket 内部契约）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:pub_semver/pub_semver.dart';

import 'plugin_loader.dart';

/// 插件安装来源。
enum PluginInstallSource { bundled, imported, market, generated }

/// 管理器问题代码。
enum PluginManagerIssueCode {
  alreadyInstalled,
  notFound,
  versionNotNewer,
  bundleIdChanged,
  dependencyUnmet,
  dependentsExist,
  permissionNotGranted,
  approvalRequired,
  loadFailed,
  storeFailed,
  invalidState,
}

/// 一条管理器问题。
class PluginManagerIssue {
  const PluginManagerIssue(this.code, this.message, {this.path});

  final PluginManagerIssueCode code;
  final String message;
  final String? path;

  @override
  String toString() =>
      path == null ? '${code.name}: $message' : '${code.name}($path): $message';
}

/// 已安装的 bundle 记录。
class InstalledPluginBundle {
  const InstalledPluginBundle({
    required this.bundleId,
    required this.name,
    required this.version,
    required this.entries,
    required this.sha256Hex,
    required this.source,
    required this.installedAt,
    required this.enabled,
    required this.grantedPermissions,
    this.dependencies = const <PluginDependency>[],
  });

  final String bundleId;
  final String name;

  /// 字符串语义化版本（由 `PluginBundle.version` 规范化后的字符串）。
  final String version;
  final List<LoadedPluginEntry> entries;
  final String sha256Hex;
  final PluginInstallSource source;
  final DateTime installedAt;
  final bool enabled;
  final Set<String> grantedPermissions;

  /// bundle 的依赖声明。用于启停时的依赖满足检查；
  /// 快照中持久化为 `{id, version}` 列表。
  final List<PluginDependency> dependencies;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'bundleId': bundleId,
      'name': name,
      'version': version,
      'entries': <Object?>[for (final entry in entries) _entryToJson(entry)],
      'sha256Hex': sha256Hex,
      'source': source.name,
      'installedAt': installedAt.toIso8601String(),
      'enabled': enabled,
      'grantedPermissions': grantedPermissions.toList()..sort(),
      'dependencies': <Object?>[
        for (final dependency in dependencies)
          <String, Object?>{'id': dependency.id, 'version': dependency.raw},
      ],
    };
  }

  /// 严格解析（坏数据抛 [FormatException]）。
  factory InstalledPluginBundle.fromJson(Map<String, Object?> json) {
    const allowed = <String>{
      'bundleId',
      'name',
      'version',
      'entries',
      'sha256Hex',
      'source',
      'installedAt',
      'enabled',
      'grantedPermissions',
      'dependencies',
    };
    for (final key in json.keys) {
      if (!allowed.contains(key)) {
        throw FormatException('InstalledPluginBundle 存在未知字段：$key');
      }
    }

    final bundleId = _requiredString(json, 'bundleId');
    final name = _requiredString(json, 'name');
    final version = _requiredString(json, 'version');
    try {
      Version.parse(version);
    } on FormatException catch (error) {
      throw FormatException('version 不是合法语义化版本：$version（${error.message}）');
    }

    final sha256Hex = _requiredString(json, 'sha256Hex');
    if (!_sha256Pattern.hasMatch(sha256Hex)) {
      throw const FormatException('sha256Hex 必须是 64 位小写十六进制');
    }

    final rawSource = _requiredString(json, 'source');
    final sourceMatches = PluginInstallSource.values.where(
      (value) => value.name == rawSource,
    );
    if (sourceMatches.isEmpty) {
      throw FormatException('未知的安装来源：$rawSource');
    }
    final source = sourceMatches.first;

    final rawInstalledAt = _requiredString(json, 'installedAt');
    final installedAt = DateTime.tryParse(rawInstalledAt);
    if (installedAt == null) {
      throw FormatException('installedAt 不是合法时间：$rawInstalledAt');
    }

    final rawEnabled = json['enabled'];
    if (rawEnabled is! bool) {
      throw const FormatException('enabled 必须是布尔值');
    }

    final rawEntries = json['entries'];
    if (rawEntries is! List<Object?> || rawEntries.isEmpty) {
      throw const FormatException('entries 必须是非空数组');
    }
    final entries = <LoadedPluginEntry>[];
    final seenEntryIds = <String>{};
    for (final rawEntry in rawEntries) {
      final entry = _loadedEntryFromJson(
        _stringKeyedMap(rawEntry, 'entries[]'),
      );
      if (!seenEntryIds.add(entry.id.toLowerCase())) {
        throw FormatException('bundle 内插件 id 重复：${entry.id}');
      }
      entries.add(entry);
    }

    final rawPermissions = json['grantedPermissions'] ?? const <Object?>[];
    if (rawPermissions is! List<Object?>) {
      throw const FormatException('grantedPermissions 必须是数组');
    }
    final grantedPermissions = <String>{};
    for (final rawPermission in rawPermissions) {
      if (rawPermission is! String || rawPermission.isEmpty) {
        throw const FormatException('grantedPermissions 必须是非空字符串数组');
      }
      grantedPermissions.add(rawPermission);
    }

    final rawDependencies = json['dependencies'] ?? const <Object?>[];
    if (rawDependencies is! List<Object?>) {
      throw const FormatException('dependencies 必须是数组');
    }
    final dependencies = <PluginDependency>[
      for (final rawDependency in rawDependencies)
        PluginDependency.fromJson(rawDependency),
    ];

    return InstalledPluginBundle(
      bundleId: bundleId,
      name: name,
      version: version,
      entries: List<LoadedPluginEntry>.unmodifiable(entries),
      sha256Hex: sha256Hex,
      source: source,
      installedAt: installedAt,
      enabled: rawEnabled,
      grantedPermissions: Set<String>.unmodifiable(grantedPermissions),
      dependencies: List<PluginDependency>.unmodifiable(dependencies),
    );
  }
}

/// 管理器状态快照（可整体持久化）。
class PluginManagerState {
  const PluginManagerState({
    this.schemaVersion = 1,
    this.bundles = const <InstalledPluginBundle>[],
    this.config = const <String, Map<String, Object?>>{},
  });

  final int schemaVersion;
  final List<InstalledPluginBundle> bundles;

  /// bundleId -> 插件配置（JSON 对象）。
  final Map<String, Map<String, Object?>> config;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'bundles': <Object?>[for (final bundle in bundles) bundle.toJson()],
      'config': <String, Object?>{
        for (final entry in config.entries)
          entry.key: _copyJsonValue(entry.value),
      },
    };
  }

  /// 严格解析（坏数据抛 [FormatException]）。
  factory PluginManagerState.fromJson(Map<String, Object?> json) {
    const allowed = <String>{'schemaVersion', 'bundles', 'config'};
    for (final key in json.keys) {
      if (!allowed.contains(key)) {
        throw FormatException('PluginManagerState 存在未知字段：$key');
      }
    }

    final schemaVersion = json['schemaVersion'];
    if (schemaVersion is! int) {
      throw const FormatException('schemaVersion 必须是整数');
    }
    if (schemaVersion != 1) {
      throw FormatException('不支持的快照 schemaVersion：$schemaVersion');
    }

    final rawBundles = json['bundles'] ?? const <Object?>[];
    if (rawBundles is! List<Object?>) {
      throw const FormatException('bundles 必须是数组');
    }
    final bundles = <InstalledPluginBundle>[];
    final seenBundleIds = <String>{};
    final seenEntryIds = <String>{};
    for (final rawBundle in rawBundles) {
      final bundle = InstalledPluginBundle.fromJson(
        _stringKeyedMap(rawBundle, 'bundles[]'),
      );
      if (!seenBundleIds.add(bundle.bundleId.toLowerCase())) {
        throw FormatException('bundleId 重复：${bundle.bundleId}');
      }
      for (final entry in bundle.entries) {
        if (!seenEntryIds.add(entry.id.toLowerCase())) {
          throw FormatException('插件 id 在多个 bundle 间重复：${entry.id}');
        }
      }
      bundles.add(bundle);
    }

    final rawConfig = json['config'] ?? const <String, Object?>{};
    final config = <String, Map<String, Object?>>{};
    for (final entry in _stringKeyedMap(rawConfig, 'config').entries) {
      final frozen = _freezeJsonValue(
        _stringKeyedMap(entry.value, 'config.${entry.key}'),
      );
      config[entry.key] = frozen! as Map<String, Object?>;
    }

    return PluginManagerState(
      schemaVersion: schemaVersion,
      bundles: List<InstalledPluginBundle>.unmodifiable(bundles),
      config: Map<String, Map<String, Object?>>.unmodifiable(config),
    );
  }
}

/// 插件管理器状态存储接口（调用方注入文件/数据库等实现）。
abstract class PluginManagerStore {
  Future<PluginManagerState?> load();

  Future<void> save(PluginManagerState state);
}

/// 内存 store，用于测试与演示。
class InMemoryPluginManagerStore implements PluginManagerStore {
  InMemoryPluginManagerStore([PluginManagerState? initial]) : _state = initial;

  PluginManagerState? _state;

  int loadCalls = 0;
  int saveCalls = 0;

  PluginManagerState? get state => _state;

  @override
  Future<PluginManagerState?> load() async {
    loadCalls++;
    return _state;
  }

  @override
  Future<void> save(PluginManagerState state) async {
    saveCalls++;
    _state = state;
  }
}

/// 管理器操作结果。
class PluginInstallOutcome {
  const PluginInstallOutcome({required this.ok, this.bundleId, this.issue});

  final bool ok;
  final String? bundleId;
  final PluginManagerIssue? issue;

  @override
  String toString() => ok
      ? 'PluginInstallOutcome(ok, $bundleId)'
      : 'PluginInstallOutcome(${issue?.code.name})';
}

/// 插件管理器。
class PluginManager {
  PluginManager({
    required PluginManagerStore store,
    required String platform,
    int hostApiVersion = pluginApiVersion,
    PluginPackageLimits packageLimits = const PluginPackageLimits(),
    DateTime Function()? clock,
  }) : _store = store,
       _platform = platform,
       _hostApiVersion = hostApiVersion,
       _packageLimits = packageLimits,
       _clock = clock ?? DateTime.now;

  final PluginManagerStore _store;
  final String _platform;
  final int _hostApiVersion;
  final PluginPackageLimits _packageLimits;
  final DateTime Function() _clock;

  PluginManagerState _state = const PluginManagerState();
  String? _lastLoadError;
  bool _restored = false;

  /// 最近一次 [restore] 失败的原因；成功或未调用时为 null。
  String? get lastLoadError => _lastLoadError;

  /// 当前已安装 bundle（不可变视图，按安装顺序）。
  List<InstalledPluginBundle> get installed =>
      List<InstalledPluginBundle>.unmodifiable(_state.bundles);

  /// 全部已安装 entry id -> bundle 版本（含未启用）。
  Map<String, String> get installedVersions {
    return Map<String, String>.unmodifiable(<String, String>{
      for (final bundle in _state.bundles)
        for (final entry in bundle.entries) entry.id: bundle.version,
    });
  }

  /// 仅已启用 entry id -> bundle 版本。
  Map<String, String> get enabledVersions {
    return Map<String, String>.unmodifiable(<String, String>{
      for (final bundle in _state.bundles)
        if (bundle.enabled)
          for (final entry in bundle.entries) entry.id: bundle.version,
    });
  }

  /// 已启用 bundle id（按安装顺序）。
  List<String> get enabledBundleIds => List<String>.unmodifiable(<String>[
    for (final bundle in _state.bundles)
      if (bundle.enabled) bundle.bundleId,
  ]);

  /// 插件（entry id 或 bundle id）是否处于启用状态。
  bool isPluginEnabled(String pluginId) {
    for (final bundle in _state.bundles) {
      if (!bundle.enabled) continue;
      if (bundle.bundleId == pluginId) return true;
      if (bundle.entries.any((entry) => entry.id == pluginId)) return true;
    }
    return false;
  }

  /// 当前状态快照（内部保持不可变）。
  PluginManagerState get snapshot => _state;

  /// 从 store 恢复状态。只允许调用一次；坏快照不会抛出，而是留在空状态并记录
  /// [lastLoadError]。
  Future<void> restore() async {
    if (_restored) {
      throw StateError('restore() 只能调用一次');
    }
    _restored = true;
    _lastLoadError = null;
    try {
      final loaded = await _store.load();
      if (loaded == null) {
        _state = const PluginManagerState();
        return;
      }
      if (loaded.schemaVersion != 1) {
        _lastLoadError = '不支持的快照 schemaVersion：${loaded.schemaVersion}';
        _state = const PluginManagerState();
        return;
      }
      // 通过 toJson/fromJson 复核并冻结，确保快照严格合法、不可变。
      _state = PluginManagerState.fromJson(loaded.toJson());
    } on FormatException catch (error) {
      _lastLoadError = error.message;
      _state = const PluginManagerState();
    } catch (error) {
      _lastLoadError = '读取插件状态失败：$error';
      _state = const PluginManagerState();
    }
  }

  /// 安装插件包。任何安装都要求 `userApproved == true`（审批是硬要求）。
  Future<PluginInstallOutcome> install(
    Uint8List bytes, {
    required PluginInstallSource source,
    Set<String> grantedPermissions = const <String>{},
    bool userApproved = false,
    String? expectedSha256Hex,
  }) async {
    if (!userApproved) {
      return _failure(
        PluginManagerIssueCode.approvalRequired,
        '安装插件必须由用户明确确认（userApproved=true）',
      );
    }

    final loadResult = _load(bytes, expectedSha256Hex);
    final loadFailure = _loadFailureOutcome(loadResult);
    if (loadFailure != null) return loadFailure;
    final loaded = loadResult.bundle!;
    final bundle = loaded.bundle;

    if (_findBundle(bundle.id) != null) {
      return _failure(
        PluginManagerIssueCode.alreadyInstalled,
        '插件包 ${bundle.id} 已安装',
      );
    }

    final conflict = _findEntryIdConflict(loaded.entries);
    if (conflict != null) {
      return _failure(
        PluginManagerIssueCode.invalidState,
        '插件 id $conflict 与已安装插件冲突',
      );
    }

    final requestedPermissions = _requestedPermissions(loaded.entries);
    final missingPermissions = requestedPermissions.difference(
      grantedPermissions,
    );
    if (missingPermissions.isNotEmpty) {
      return _failure(
        PluginManagerIssueCode.permissionNotGranted,
        '以下权限未被授予：${(missingPermissions.toList()..sort()).join(', ')}',
      );
    }

    final unmet = bundle.unmetDependencies(installedVersions);
    if (unmet.isNotEmpty) {
      return _failure(
        PluginManagerIssueCode.dependencyUnmet,
        '插件依赖未满足：${unmet.map((item) => '$item').join('；')}',
      );
    }

    final next = PluginManagerState(
      schemaVersion: 1,
      bundles: List<InstalledPluginBundle>.unmodifiable(<InstalledPluginBundle>[
        ..._state.bundles,
        InstalledPluginBundle(
          bundleId: bundle.id,
          name: bundle.name,
          version: bundle.version.toString(),
          entries: List<LoadedPluginEntry>.unmodifiable(loaded.entries),
          sha256Hex: loaded.sha256Hex,
          source: source,
          installedAt: _clock(),
          enabled: true,
          grantedPermissions: Set<String>.unmodifiable(requestedPermissions),
          dependencies: List<PluginDependency>.unmodifiable(
            bundle.dependencies,
          ),
        ),
      ]),
      config: _state.config,
    );

    final saveFailure = await _save(next);
    if (saveFailure != null) return saveFailure;
    _state = next;
    return _success(bundle.id);
  }

  /// 更新已安装插件。新包 bundleId 必须能对应到已安装 bundle。
  Future<PluginInstallOutcome> update(
    Uint8List bytes, {
    Set<String> grantedPermissions = const <String>{},
    bool userApproved = false,
    String? expectedSha256Hex,
  }) async {
    final loadResult = _load(bytes, expectedSha256Hex);
    final loadFailure = _loadFailureOutcome(loadResult);
    if (loadFailure != null) return loadFailure;
    final loaded = loadResult.bundle!;
    final bundle = loaded.bundle;
    final existing = _findBundle(bundle.id);
    if (existing == null) {
      final changedFrom = _entryOverlapBundle(loaded.entries);
      if (changedFrom != null) {
        return _failure(
          PluginManagerIssueCode.bundleIdChanged,
          '更新包 bundle id 由 ${changedFrom.bundleId} 变为 ${bundle.id}',
        );
      }
      return _failure(
        PluginManagerIssueCode.notFound,
        '未安装的插件包 ${bundle.id}，无法更新',
      );
    }

    final Version oldVersion;
    try {
      oldVersion = Version.parse(existing.version);
    } on FormatException {
      return _failure(
        PluginManagerIssueCode.invalidState,
        '已安装插件版本号损坏：${existing.version}',
      );
    }
    if (bundle.version.compareTo(oldVersion) <= 0) {
      return _failure(
        PluginManagerIssueCode.versionNotNewer,
        '新版本 ${bundle.version} 不高于已安装版本 ${existing.version}',
      );
    }

    final requestedPermissions = _requestedPermissions(loaded.entries);
    final oldGranted = existing.grantedPermissions;
    final missingPermissions = requestedPermissions.difference(
      oldGranted.union(grantedPermissions),
    );
    if (missingPermissions.isNotEmpty) {
      return _failure(
        PluginManagerIssueCode.permissionNotGranted,
        '以下新增权限未被授予：${(missingPermissions.toList()..sort()).join(', ')}',
      );
    }
    final newPermissions = requestedPermissions.difference(oldGranted);
    if (newPermissions.isNotEmpty && !userApproved) {
      return _failure(
        PluginManagerIssueCode.approvalRequired,
        '更新新增权限需用户确认：${(newPermissions.toList()..sort()).join(', ')}',
      );
    }

    // 新版本若删除其它已安装 bundle 依赖的 entry id，等同悄悄破坏依赖，拒绝更新。
    final newEntryIds = <String>{
      for (final entry in loaded.entries) entry.id.toLowerCase(),
    };
    final removedEntryIds = <String>{
      for (final entry in existing.entries)
        if (!newEntryIds.contains(entry.id.toLowerCase())) entry.id,
    };
    if (removedEntryIds.isNotEmpty) {
      final dependents = _dependentsOfEntryIds(
        removedEntryIds,
        excludingBundleId: existing.bundleId,
      );
      if (dependents.isNotEmpty) {
        return _failure(
          PluginManagerIssueCode.dependentsExist,
          '更新将移除被以下已安装插件依赖的入口：${dependents.join(', ')}'
          '（缺失 ${(removedEntryIds.toList()..sort()).join(', ')}）',
        );
      }
    }

    final conflict = _findEntryIdConflict(
      loaded.entries,
      excludingBundleId: existing.bundleId,
    );
    if (conflict != null) {
      return _failure(
        PluginManagerIssueCode.invalidState,
        '插件 id $conflict 与其它已安装插件冲突',
      );
    }

    final unmet = bundle.unmetDependencies(installedVersions);
    if (unmet.isNotEmpty) {
      return _failure(
        PluginManagerIssueCode.dependencyUnmet,
        '插件依赖未满足：${unmet.map((item) => '$item').join('；')}',
      );
    }

    final updated = InstalledPluginBundle(
      bundleId: existing.bundleId,
      name: bundle.name,
      version: bundle.version.toString(),
      entries: List<LoadedPluginEntry>.unmodifiable(loaded.entries),
      sha256Hex: loaded.sha256Hex,
      source: existing.source,
      installedAt: existing.installedAt,
      enabled: existing.enabled,
      grantedPermissions: Set<String>.unmodifiable(requestedPermissions),
      dependencies: List<PluginDependency>.unmodifiable(bundle.dependencies),
    );
    final next = PluginManagerState(
      schemaVersion: 1,
      bundles: List<InstalledPluginBundle>.unmodifiable(<InstalledPluginBundle>[
        for (final current in _state.bundles)
          if (current.bundleId == existing.bundleId) updated else current,
      ]),
      config: _state.config,
    );

    final saveFailure = await _save(next);
    if (saveFailure != null) return saveFailure;
    _state = next;
    return _success(existing.bundleId);
  }

  /// 启用 / 停用 bundle（含依赖检查）。
  Future<PluginInstallOutcome> setEnabled(String bundleId, bool enabled) async {
    final existing = _findBundle(bundleId);
    if (existing == null) {
      return _failure(PluginManagerIssueCode.notFound, '未找到插件包 $bundleId');
    }
    if (existing.enabled == enabled) {
      return _success(existing.bundleId);
    }

    if (!enabled) {
      final dependents = _dependentsOf(existing, onlyEnabled: true);
      if (dependents.isNotEmpty) {
        return _failure(
          PluginManagerIssueCode.dependentsExist,
          '以下已启用插件依赖 $bundleId，无法停用：${dependents.join(', ')}',
        );
      }
    } else {
      final unmet = _unmetDependencyMessages(
        existing.dependencies,
        enabledVersions,
      );
      if (unmet.isNotEmpty) {
        return _failure(
          PluginManagerIssueCode.dependencyUnmet,
          '插件依赖未启用：${unmet.join('；')}',
        );
      }
    }

    final next = PluginManagerState(
      schemaVersion: 1,
      bundles: List<InstalledPluginBundle>.unmodifiable(<InstalledPluginBundle>[
        for (final current in _state.bundles)
          if (current.bundleId == existing.bundleId)
            _copyBundle(current, enabled: enabled)
          else
            current,
      ]),
      config: _state.config,
    );

    final saveFailure = await _save(next);
    if (saveFailure != null) return saveFailure;
    _state = next;
    return _success(existing.bundleId);
  }

  /// 卸载 bundle（若其它 bundle 依赖则拒绝），同时删除其配置。
  Future<PluginInstallOutcome> uninstall(String bundleId) async {
    final existing = _findBundle(bundleId);
    if (existing == null) {
      return _failure(PluginManagerIssueCode.notFound, '未找到插件包 $bundleId');
    }
    final dependents = _dependentsOf(existing, onlyEnabled: false);
    if (dependents.isNotEmpty) {
      return _failure(
        PluginManagerIssueCode.dependentsExist,
        '以下插件依赖 $bundleId，无法卸载：${dependents.join(', ')}',
      );
    }

    final nextConfig = <String, Map<String, Object?>>{
      for (final entry in _state.config.entries)
        if (entry.key != existing.bundleId) entry.key: entry.value,
    };
    final next = PluginManagerState(
      schemaVersion: 1,
      bundles: List<InstalledPluginBundle>.unmodifiable(<InstalledPluginBundle>[
        for (final current in _state.bundles)
          if (current.bundleId != existing.bundleId) current,
      ]),
      config: Map<String, Map<String, Object?>>.unmodifiable(nextConfig),
    );

    final saveFailure = await _save(next);
    if (saveFailure != null) return saveFailure;
    _state = next;
    return _success(existing.bundleId);
  }

  /// 写入插件配置（必须是 JSON 可序列化对象）。
  Future<PluginInstallOutcome> setConfig(
    String bundleId,
    Map<String, Object?> config,
  ) async {
    final existing = _findBundle(bundleId);
    if (existing == null) {
      return _failure(PluginManagerIssueCode.notFound, '未找到插件包 $bundleId');
    }

    final Map<String, Object?> frozenConfig;
    try {
      frozenConfig = _jsonObjectFromUser(config);
    } on FormatException catch (error) {
      return _failure(
        PluginManagerIssueCode.invalidState,
        '配置不是合法的 JSON 对象：${error.message}',
      );
    }

    final nextConfig = <String, Map<String, Object?>>{
      for (final entry in _state.config.entries) entry.key: entry.value,
      existing.bundleId: frozenConfig,
    };
    final next = PluginManagerState(
      schemaVersion: 1,
      bundles: _state.bundles,
      config: Map<String, Map<String, Object?>>.unmodifiable(nextConfig),
    );

    final saveFailure = await _save(next);
    if (saveFailure != null) return saveFailure;
    _state = next;
    return _success(existing.bundleId);
  }

  PluginBundleLoadResult _load(Uint8List bytes, String? expectedSha256Hex) {
    return loadPluginBundle(
      bytes,
      platform: _platform,
      hostApiVersion: _hostApiVersion,
      installedVersions: installedVersions,
      packageLimits: _packageLimits,
      expectedSha256Hex: expectedSha256Hex,
    );
  }

  /// 把加载失败映射为管理器问题；依赖类问题保留 `dependencyUnmet` 代码。
  PluginInstallOutcome? _loadFailureOutcome(PluginBundleLoadResult result) {
    if (result.ok) return null;
    final dependencyIssues = result.issues
        .where((issue) => issue.code == PluginLoadIssueCode.dependencyUnmet)
        .toList();
    if (dependencyIssues.length == result.issues.length &&
        dependencyIssues.isNotEmpty) {
      return _failure(
        PluginManagerIssueCode.dependencyUnmet,
        dependencyIssues.map((issue) => issue.message).join('；'),
        path: dependencyIssues.first.path,
      );
    }
    final message = result.issues.isEmpty
        ? '插件包加载失败'
        : result.issues.map((issue) => issue.toString()).join('；');
    return _failure(
      PluginManagerIssueCode.loadFailed,
      message,
      path: result.issues.isEmpty ? null : result.issues.first.path,
    );
  }

  Future<PluginInstallOutcome?> _save(PluginManagerState next) async {
    try {
      await _store.save(next);
    } catch (error) {
      return _failure(PluginManagerIssueCode.storeFailed, '保存插件状态失败：$error');
    }
    return null;
  }

  PluginInstallOutcome _failure(
    PluginManagerIssueCode code,
    String message, {
    String? path,
  }) {
    return PluginInstallOutcome(
      ok: false,
      issue: PluginManagerIssue(code, message, path: path),
    );
  }

  PluginInstallOutcome _success(String bundleId) {
    return PluginInstallOutcome(ok: true, bundleId: bundleId);
  }

  InstalledPluginBundle? _findBundle(String bundleId) {
    final normalized = bundleId.toLowerCase();
    for (final bundle in _state.bundles) {
      if (bundle.bundleId.toLowerCase() == normalized) return bundle;
    }
    return null;
  }

  /// 查找与已安装其它 bundle 冲突的 entry id（不区分大小写）。
  String? _findEntryIdConflict(
    List<LoadedPluginEntry> entries, {
    String? excludingBundleId,
  }) {
    final excluded = excludingBundleId?.toLowerCase();
    final existing = <String>{
      for (final bundle in _state.bundles)
        if (bundle.bundleId.toLowerCase() != excluded)
          for (final entry in bundle.entries) entry.id.toLowerCase(),
    };
    for (final entry in entries) {
      if (existing.contains(entry.id.toLowerCase())) return entry.id;
    }
    return null;
  }

  /// 若新包 entry ids 与某个已安装 bundle 有交集（但 bundleId 不同），返回该 bundle。
  InstalledPluginBundle? _entryOverlapBundle(List<LoadedPluginEntry> entries) {
    final incoming = <String>{
      for (final entry in entries) entry.id.toLowerCase(),
    };
    for (final bundle in _state.bundles) {
      if (bundle.entries.any(
        (entry) => incoming.contains(entry.id.toLowerCase()),
      )) {
        return bundle;
      }
    }
    return null;
  }

  Set<String> _requestedPermissions(List<LoadedPluginEntry> entries) {
    return <String>{for (final entry in entries) ...entry.permissions};
  }

  /// 返回依赖本 bundle entry ids 的其它 bundle id（可按启用状态过滤）。
  List<String> _dependentsOf(
    InstalledPluginBundle target, {
    required bool onlyEnabled,
  }) {
    return _dependentsOfEntryIds(
      <String>{for (final entry in target.entries) entry.id},
      excludingBundleId: target.bundleId,
      onlyEnabled: onlyEnabled,
    );
  }

  /// 返回依赖给定 entry ids 的其它已安装 bundle id（可按启用状态过滤）。
  List<String> _dependentsOfEntryIds(
    Set<String> entryIds, {
    String? excludingBundleId,
    bool onlyEnabled = false,
  }) {
    final targetIds = <String>{
      for (final entryId in entryIds) entryId.toLowerCase(),
    };
    final dependents = <String>[];
    for (final bundle in _state.bundles) {
      if (excludingBundleId != null &&
          bundle.bundleId.toLowerCase() == excludingBundleId.toLowerCase()) {
        continue;
      }
      if (onlyEnabled && !bundle.enabled) continue;
      final depends = bundle.dependencies.any(
        (dependency) => targetIds.contains(dependency.id.toLowerCase()),
      );
      if (depends) dependents.add(bundle.bundleId);
    }
    return dependents;
  }

  List<String> _unmetDependencyMessages(
    List<PluginDependency> dependencies,
    Map<String, String> versions,
  ) {
    final unmet = <String>[];
    for (final dependency in dependencies) {
      final installed = versions[dependency.id];
      if (installed == null) {
        unmet.add('${dependency.id} 未启用或未安装（需要 ${dependency.raw}）');
        continue;
      }
      try {
        final version = Version.parse(installed);
        if (!dependency.constraint.allows(version)) {
          unmet.add('${dependency.id} $installed 不满足 ${dependency.raw}');
        }
      } on FormatException {
        unmet.add('${dependency.id} 已安装版本号非法：$installed');
      }
    }
    return unmet;
  }

  InstalledPluginBundle _copyBundle(
    InstalledPluginBundle bundle, {
    required bool enabled,
  }) {
    return InstalledPluginBundle(
      bundleId: bundle.bundleId,
      name: bundle.name,
      version: bundle.version,
      entries: bundle.entries,
      sha256Hex: bundle.sha256Hex,
      source: bundle.source,
      installedAt: bundle.installedAt,
      enabled: enabled,
      grantedPermissions: bundle.grantedPermissions,
      dependencies: bundle.dependencies,
    );
  }
}

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key 必须是非空字符串');
  }
  return value;
}

Map<String, Object?> _stringKeyedMap(Object? raw, String what) {
  if (raw is! Map<Object?, Object?>) {
    throw FormatException('$what 必须是 JSON 对象');
  }
  final out = <String, Object?>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String) {
      throw FormatException('$what 的键必须是字符串');
    }
    out[key] = entry.value;
  }
  return out;
}

Map<String, Object?> _entryToJson(LoadedPluginEntry entry) {
  return <String, Object?>{
    'id': entry.id,
    'runtime': entry.runtime.name,
    'entry': entry.entry,
    'slots': entry.slots,
    'permissions': entry.permissions.toList()..sort(),
    'configSchema': entry.configSchema,
    'configSchemaJson': _copyJsonValue(entry.configSchemaJson),
    'network': entry.network,
  };
}

LoadedPluginEntry _loadedEntryFromJson(Map<String, Object?> json) {
  const allowed = <String>{
    'id',
    'runtime',
    'entry',
    'slots',
    'permissions',
    'configSchema',
    'configSchemaJson',
    'network',
  };
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('LoadedPluginEntry 存在未知字段：$key');
    }
  }

  final id = _requiredString(json, 'id');
  final runtimeName = _requiredString(json, 'runtime');
  final runtime = switch (runtimeName) {
    'webview' => PluginRuntime.webview,
    'dart' => PluginRuntime.dart,
    'declarative' => PluginRuntime.declarative,
    _ => throw FormatException('未知的插件 runtime：$runtimeName'),
  };

  final rawEntry = json['entry'];
  if (rawEntry != null && (rawEntry is! String || rawEntry.isEmpty)) {
    throw const FormatException('entry 必须是非空字符串或 null');
  }

  final slots = <String>[];
  final rawSlots = json['slots'] ?? const <Object?>[];
  if (rawSlots is! List<Object?>) {
    throw const FormatException('slots 必须是字符串数组');
  }
  for (final rawSlot in rawSlots) {
    if (rawSlot is! String || rawSlot.isEmpty) {
      throw const FormatException('slots 必须是非空字符串数组');
    }
    slots.add(rawSlot);
  }

  final permissions = <String>{};
  final rawPermissions = json['permissions'] ?? const <Object?>[];
  if (rawPermissions is! List<Object?>) {
    throw const FormatException('permissions 必须是字符串数组');
  }
  for (final rawPermission in rawPermissions) {
    if (rawPermission is! String || rawPermission.isEmpty) {
      throw const FormatException('permissions 必须是非空字符串数组');
    }
    permissions.add(rawPermission);
  }

  final rawConfigSchema = json['configSchema'];
  if (rawConfigSchema != null &&
      (rawConfigSchema is! String || rawConfigSchema.isEmpty)) {
    throw const FormatException('configSchema 必须是非空字符串或 null');
  }

  Map<String, Object?>? configSchemaJson;
  final rawSchemaJson = json['configSchemaJson'];
  if (rawSchemaJson != null) {
    final frozen = _freezeJsonValue(
      _stringKeyedMap(rawSchemaJson, 'configSchemaJson'),
    );
    configSchemaJson = frozen! as Map<String, Object?>;
  }

  final network = json['network'] ?? 'deny';
  if (network is! String || (network != 'deny' && network != 'host-gateway')) {
    throw FormatException('network 只允许 deny / host-gateway，收到 $network');
  }

  return LoadedPluginEntry(
    id: id,
    runtime: runtime,
    entry: rawEntry as String?,
    slots: List<String>.unmodifiable(slots),
    permissions: Set<String>.unmodifiable(permissions),
    configSchema: rawConfigSchema as String?,
    configSchemaJson: configSchemaJson,
    network: network,
  );
}

/// 校验用户传入的配置是 JSON 对象并返回深拷贝后的不可变结构。
Map<String, Object?> _jsonObjectFromUser(Map<String, Object?> value) {
  final String encoded;
  try {
    encoded = jsonEncode(value);
  } catch (error) {
    throw FormatException('配置无法序列化为 JSON：$error');
  }
  final decoded = jsonDecode(encoded);
  final map = _stringKeyedMap(decoded, 'config');
  return _freezeJsonValue(map)! as Map<String, Object?>;
}

/// 递归冻结 JSON 值（Map/List 不可变），拒绝非 JSON 值。
Object? _freezeJsonValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Map<Object?, Object?>) {
    final out = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw FormatException('JSON 对象的键必须是字符串：$key');
      }
      out[key] = _freezeJsonValue(entry.value);
    }
    return Map<String, Object?>.unmodifiable(out);
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(<Object?>[
      for (final item in value) _freezeJsonValue(item),
    ]);
  }
  throw FormatException('不是合法的 JSON 值：${value.runtimeType}');
}

/// 递归复制 JSON 值（用于 toJson 向外暴露可变副本）。
Object? _copyJsonValue(Object? value) {
  if (value is Map<Object?, Object?>) {
    final out = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw FormatException('JSON 对象的键必须是字符串：$key');
      }
      out[key] = _copyJsonValue(entry.value);
    }
    return out;
  }
  if (value is List<Object?>) {
    return <Object?>[for (final item in value) _copyJsonValue(item)];
  }
  return value;
}
