/// 插件 bundle 描述模型（对应插件方案 v3 §4：bundle / 多行插件 / 依赖 / 完整性）。
///
/// 纯 Dart、不读文件系统：只把 `plugin.json`（bundle 形态）的结构解析成强类型，
/// 并用 OSS `pub_semver`（BSD-3-Clause）解析版本与依赖版本区间。
///
/// 与 [PluginManifest] 的关系：单插件清单（[PluginManifest]）描述“一个插件”；
/// 本文件的 [PluginBundle] 描述“一个可分发、可含多行插件、可声明依赖”的 bundle。
/// 两者互不替换、互不影响（唯一相关：`bundle` 也带 `id/version/apiVersion`）。
library;

import 'package:pub_semver/pub_semver.dart';

import 'plugin_package.dart';

/// 插件运行档位（v3 三档信任）。
enum PluginRuntime {
  /// 客户端 WebView / JS 沙箱插件。
  webview,

  /// 可信宿主插件（进程内 Dart，全能力）。
  dart,

  /// 声明式数据插件（纯数据，最安全）。
  declarative,
}

/// bundle 内单行插件声明（对应 `plugin.json` 的 `plugins[i]`）。
class PluginBundleEntry {
  const PluginBundleEntry({
    required this.runtime,
    this.id,
    this.entry,
    this.slots = const <String>[],
    this.permissions = const <String>{},
    this.configSchema,
    this.network = 'deny',
  });

  /// 运行档位。
  final PluginRuntime runtime;

  /// 该行插件的可选 id（bundle 内唯一）。
  final String? id;

  /// 入口（webview 为页面路径，dart 为导出名/入口）；declarative 可空。
  final String? entry;

  /// 贡献到的命名插槽（v3 §3 的 slot key）。
  final List<String> slots;

  /// 申请的权限 scope（v3 §5）。
  final Set<String> permissions;

  /// 配置 JSON Schema 的相对路径。
  final String? configSchema;

  /// 网络策略，`deny`（默认禁网）或 `host-gateway`（经宿主 UrlGuard 出站）。
  final String network;

  static const Set<String> _networks = {'deny', 'host-gateway'};

  /// 从 `plugins[i]` 解析。失败抛 [FormatException]，不做宽松兜底。
  factory PluginBundleEntry.fromJson(Map<String, Object?> json) {
    final rawRuntime = json['runtime'];
    final runtime = switch (rawRuntime) {
      'webview' => PluginRuntime.webview,
      'dart' => PluginRuntime.dart,
      'declarative' => PluginRuntime.declarative,
      _ => throw FormatException('未知 runtime: $rawRuntime'),
    };

    final id = json['id'];
    if (id != null && (id is! String || id.isEmpty)) {
      throw const FormatException('plugins[].id 必须是非空字符串');
    }

    final entry = json['entry'];
    if (entry != null && entry is! String) {
      throw const FormatException('plugins[].entry 必须是字符串');
    }
    if (runtime != PluginRuntime.declarative && (entry is! String || entry.isEmpty)) {
      throw FormatException('${runtime.name} 插件必须提供 entry');
    }
    if (entry is String) {
      _requireSafeRelativePath(entry, 'plugins[].entry');
    }

    final slots = _stringList(json['slots'], 'slots');
    final permissions = _stringList(json['permissions'], 'permissions');
    final configSchema = json['configSchema'];
    if (configSchema != null) {
      if (configSchema is! String) {
        throw const FormatException('plugins[].configSchema 必须是字符串');
      }
      _requireSafeRelativePath(configSchema, 'plugins[].configSchema');
    }

    final network = json['network'] ?? 'deny';
    if (network is! String || !_networks.contains(network)) {
      throw FormatException('plugins[].network 只允许 deny / host-gateway，收到 $network');
    }

    return PluginBundleEntry(
      runtime: runtime,
      id: id as String?,
      entry: entry as String?,
      slots: List.unmodifiable(slots),
      permissions: Set.unmodifiable(permissions),
      configSchema: configSchema as String?,
      network: network,
    );
  }
}

/// 依赖声明：被依赖插件 `id` + `pub_semver` 版本区间。
class PluginDependency {
  const PluginDependency({
    required this.id,
    required this.constraint,
    required this.raw,
  });

  final String id;
  final VersionConstraint constraint;

  /// 原始区间文本（用于提示与记录）。
  final String raw;

  /// 从 `dependencies[i]` 解析。支持两种写法：
  /// - 字符串 `"<id>@<range>"`，如 `"jingyu.room@^1.2.0"`；
  /// - 对象 `{"id": "...", "version": "<range>"}`（`constraint` 亦可）。
  factory PluginDependency.fromJson(Object? json) {
    String id;
    String range;
    if (json is String) {
      final at = json.indexOf('@');
      if (at <= 0 || at == json.length - 1) {
        throw FormatException('依赖字符串应为 id@range，收到 $json');
      }
      id = json.substring(0, at);
      range = json.substring(at + 1);
    } else if (json is Map) {
      final rawId = json['id'];
      final rawRange = json['version'] ?? json['constraint'];
      if (rawId is! String || rawId.isEmpty) {
        throw const FormatException('依赖对象缺少 id');
      }
      if (rawRange is! String || rawRange.isEmpty) {
        throw const FormatException('依赖对象缺少 version 区间');
      }
      id = rawId;
      range = rawRange;
    } else {
      throw const FormatException('依赖必须是字符串或对象');
    }

    if (!PluginBundle._idPattern.hasMatch(id)) {
      throw FormatException('依赖 id 非法', id);
    }
    final VersionConstraint constraint;
    try {
      constraint = VersionConstraint.parse(range);
    } on FormatException catch (error) {
      throw FormatException('依赖 $id 的版本区间非法：$range（${error.message}）');
    }
    return PluginDependency(id: id, constraint: constraint, raw: range);
  }
}

/// 一条未满足的依赖。
class UnmetDependency {
  const UnmetDependency(this.id, this.reason, {this.required});

  final String id;

  /// 中文原因（未安装 / 版本不满足 / 版本号非法）。
  final String reason;

  /// 依赖声明的原始区间。
  final String? required;

  @override
  String toString() => 'UnmetDependency($id: $reason)';
}

/// 插件 bundle 描述（`plugin.json`，`type` 通常为 `bundle`）。
class PluginBundle {
  const PluginBundle._({
    required this.id,
    required this.name,
    required this.version,
    required this.apiVersion,
    required this.type,
    required this.icon,
    required this.locales,
    required this.plugins,
    required this.dependencies,
    required this.platforms,
    required this.integritySha256,
  });

  final String id;
  final String name;
  final Version version;

  /// 依赖的插件 API 主版本。
  final int apiVersion;

  /// `bundle` 或 `plugin`。
  final String type;

  /// 图标相对路径。
  final String? icon;

  /// 多语言：locale -> 相对路径。
  final Map<String, String> locales;

  /// 多行插件声明。
  final List<PluginBundleEntry> plugins;

  /// 依赖声明。
  final List<PluginDependency> dependencies;

  /// 适用平台。
  final Set<String> platforms;

  /// 期望的整包 sha256（可选，用于完整性比对；与签名不同）。
  final String? integritySha256;

  static final RegExp _idPattern =
      RegExp(r'^[a-z][a-z0-9]*(\.[a-z][a-z0-9_-]*)+$');
  static final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');
  static const Set<String> _types = {'bundle', 'plugin'};

  /// 从 `plugin.json`（bundle 形态）解析。失败抛 [FormatException]，不宽松兜底。
  factory PluginBundle.fromJson(Map<String, Object?> json) {
    String reqString(String key) {
      final v = json[key];
      if (v is String && v.isNotEmpty) return v;
      throw FormatException('plugin.json 缺少字段 $key');
    }

    final id = reqString('id');
    if (!_idPattern.hasMatch(id)) throw FormatException('bundle id 非法', id);

    final rawVersion = reqString('version');
    final Version version;
    try {
      version = Version.parse(rawVersion);
    } on FormatException catch (error) {
      throw FormatException('version 不是合法语义化版本「$rawVersion」：${error.message}');
    }

    final apiVersion = json['apiVersion'];
    if (apiVersion is! int) throw const FormatException('apiVersion 必须是整数');

    final type = json['type'] ?? 'bundle';
    if (type is! String || !_types.contains(type)) {
      throw FormatException('type 只允许 bundle / plugin，收到 $type');
    }

    final icon = json['icon'];
    if (icon != null) {
      if (icon is! String) throw const FormatException('icon 必须是字符串');
      _requireSafeRelativePath(icon, 'icon');
    }

    final locales = <String, String>{};
    final rawLocales = json['locales'];
    if (rawLocales != null) {
      if (rawLocales is! Map) throw const FormatException('locales 必须是对象');
      for (final entry in rawLocales.entries) {
        final k = entry.key;
        final v = entry.value;
        if (k is! String || k.isEmpty || v is! String || v.isEmpty) {
          throw const FormatException('locales 的键与值都必须是非空字符串');
        }
        _requireSafeRelativePath(v, 'locales.$k');
        locales[k] = v;
      }
    }

    final rawPlugins = json['plugins'];
    if (rawPlugins is! List || rawPlugins.isEmpty) {
      throw const FormatException('plugins 必须是非空数组');
    }
    final plugins = <PluginBundleEntry>[];
    final seenIds = <String>{};
    for (final raw in rawPlugins) {
      if (raw is! Map) throw const FormatException('plugins[] 必须是对象');
      final entry = PluginBundleEntry.fromJson(
          raw.map((k, v) => MapEntry(k.toString(), v)));
      final entryId = entry.id;
      if (entryId != null && !seenIds.add(entryId.toLowerCase())) {
        throw FormatException('bundle 内插件 id 重复（不区分大小写）', entryId);
      }
      plugins.add(entry);
    }

    final rawDeps = json['dependencies'] ?? const <Object?>[];
    if (rawDeps is! List) throw const FormatException('dependencies 必须是数组');
    final dependencies = <PluginDependency>[
      for (final raw in rawDeps) PluginDependency.fromJson(raw),
    ];

    final rawPlatforms = json['platforms'] ?? const ['android', 'windows'];
    if (rawPlatforms is! List ||
        rawPlatforms.any((p) => p != 'android' && p != 'windows')) {
      throw const FormatException('platforms 只允许 android / windows');
    }

    String? integritySha256;
    final integrity = json['integrity'];
    if (integrity != null) {
      if (integrity is! Map) throw const FormatException('integrity 必须是对象');
      final rawSha = integrity['sha256'];
      if (rawSha is! String || !_sha256.hasMatch(rawSha)) {
        throw const FormatException('integrity.sha256 必须是 64 位小写十六进制');
      }
      integritySha256 = rawSha;
    }

    return PluginBundle._(
      id: id,
      name: reqString('name'),
      version: version,
      apiVersion: apiVersion,
      type: type,
      icon: icon as String?,
      locales: Map.unmodifiable(locales),
      plugins: List.unmodifiable(plugins),
      dependencies: List.unmodifiable(dependencies),
      platforms: {for (final p in rawPlatforms) p as String},
      integritySha256: integritySha256,
    );
  }

  /// 是否与宿主插件 API 主版本兼容（与 [PluginHost.load] 的语义一致：相等）。
  bool isApiCompatible(int hostApiVersion) => apiVersion == hostApiVersion;

  /// 检查依赖是否被满足。[installedVersions] 为已安装插件 id -> 版本字符串。
  ///
  /// 返回空列表表示全部满足；否则逐条给出未安装 / 版本不满足 / 版本非法的原因。
  List<UnmetDependency> unmetDependencies(
      Map<String, String> installedVersions) {
    final unmet = <UnmetDependency>[];
    for (final dep in dependencies) {
      final installed = installedVersions[dep.id];
      if (installed == null) {
        unmet.add(UnmetDependency(dep.id, '未安装', required: dep.raw));
        continue;
      }
      final Version parsed;
      try {
        parsed = Version.parse(installed);
      } on FormatException {
        unmet.add(
            UnmetDependency(dep.id, '已安装版本号非法：$installed', required: dep.raw));
        continue;
      }
      if (!dep.constraint.allows(parsed)) {
        unmet.add(UnmetDependency(
            dep.id, '已安装 $installed 不满足 ${dep.raw}',
            required: dep.raw));
      }
    }
    return unmet;
  }
}

List<String> _stringList(Object? value, String field) {
  if (value == null) return const <String>[];
  if (value is! List) {
    throw FormatException('plugins[].$field 必须是字符串数组');
  }
  final out = <String>[];
  for (final element in value) {
    if (element is! String || element.isEmpty) {
      throw FormatException('plugins[].$field 必须是非空字符串数组');
    }
    out.add(element);
  }
  return out;
}

/// 要求一个相对、可安全解压的路径（复用包校验的路径规则）；否则抛 [FormatException]。
/// 拦截绝对路径、盘符、`..`、Windows 尾点/尾空格与保留设备名。
String _requireSafeRelativePath(String raw, String field) {
  final safe = sanitizePackageEntryPath(raw);
  if (safe == null) {
    throw FormatException(
        '$field 路径不安全（绝对路径/盘符/.. /Windows 保留名）', raw);
  }
  return safe;
}
