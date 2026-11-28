/// 插件包加载：把通过校验的 bundle 字节解析成运行期描述。
///
/// 纯 Dart、无 IO。完整规则见 `design/plugin-runtime-contract.md` §4（ticket 内部契约）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';

/// 加载问题代码。
enum PluginLoadIssueCode {
  packageInvalid,
  bundleInvalid,
  apiVersionMismatch,
  platformUnsupported,
  missingEntryFile,
  configInvalid,
  dependencyUnmet,
  duplicatePluginId,
}

/// 一条加载问题。
class PluginLoadIssue {
  const PluginLoadIssue(this.code, this.message, {this.path});

  final PluginLoadIssueCode code;
  final String message;
  final String? path;

  @override
  String toString() =>
      path == null ? '${code.name}: $message' : '${code.name}($path): $message';
}

/// 一个 bundle 内单行插件的运行期描述。
class LoadedPluginEntry {
  const LoadedPluginEntry({
    required this.id,
    required this.runtime,
    this.entry,
    this.slots = const <String>[],
    this.permissions = const <String>{},
    this.configSchema,
    this.configSchemaJson,
    this.network = 'deny',
  });

  final String id;
  final PluginRuntime runtime;
  final String? entry;
  final List<String> slots;
  final Set<String> permissions;
  final String? configSchema;
  final Map<String, Object?>? configSchemaJson;
  final String network;
}

/// 加载成功后的 bundle 及其文件内容。
class LoadedPluginBundle {
  const LoadedPluginBundle({
    required this.bundle,
    required this.files,
    required this.sha256Hex,
    required this.entries,
  });

  final PluginBundle bundle;
  final Map<String, Uint8List> files;
  final String sha256Hex;
  final List<LoadedPluginEntry> entries;
}

/// 加载结果。
class PluginBundleLoadResult {
  const PluginBundleLoadResult._({
    required this.ok,
    this.bundle,
    required this.issues,
    required this.sha256Hex,
  });

  final bool ok;
  final LoadedPluginBundle? bundle;
  final List<PluginLoadIssue> issues;
  final String sha256Hex;

  @override
  String toString() =>
      'PluginBundleLoadResult(ok=$ok, issues=${issues.length})';
}

/// 加载一个插件 bundle 的 zip 字节。
///
/// 流程：安全解包（[extractPluginPackage]）→ `plugin.json` 严格解析为
/// [PluginBundle] → API 版本 / 平台 / 入口文件 / configSchema / 依赖检查。
/// 只有全部检查通过才返回 `ok=true`；结果对象及其列表均不可修改。
PluginBundleLoadResult loadPluginBundle(
  Uint8List bytes, {
  required String platform,
  int hostApiVersion = pluginApiVersion,
  Map<String, String> installedVersions = const <String, String>{},
  PluginPackageLimits packageLimits = const PluginPackageLimits(),
  String? expectedSha256Hex,
}) {
  final extraction = extractPluginPackage(
    bytes,
    limits: packageLimits,
    expectedSha256Hex: expectedSha256Hex,
  );
  final issues = <PluginLoadIssue>[];

  PluginBundleLoadResult fail() => PluginBundleLoadResult._(
    ok: false,
    issues: List<PluginLoadIssue>.unmodifiable(issues),
    sha256Hex: extraction.sha256Hex,
  );

  if (!extraction.ok) {
    for (final issue in extraction.issues) {
      issues.add(
        PluginLoadIssue(
          PluginLoadIssueCode.packageInvalid,
          issue.message,
          path: issue.path,
        ),
      );
    }
    if (issues.isEmpty) {
      issues.add(
        const PluginLoadIssue(PluginLoadIssueCode.packageInvalid, '插件包校验失败'),
      );
    }
    return fail();
  }

  final manifestBytes = extraction.files['plugin.json'];
  if (manifestBytes == null) {
    issues.add(
      const PluginLoadIssue(
        PluginLoadIssueCode.packageInvalid,
        '插件包缺少根目录 plugin.json',
        path: 'plugin.json',
      ),
    );
    return fail();
  }

  final bundleJson = _decodeJsonObject(
    manifestBytes,
    PluginLoadIssueCode.bundleInvalid,
    'plugin.json',
    'plugin.json',
    issues,
  );
  if (bundleJson == null) return fail();

  PluginBundle bundle;
  try {
    bundle = PluginBundle.fromJson(bundleJson);
  } on FormatException catch (error) {
    issues.add(
      PluginLoadIssue(
        PluginLoadIssueCode.bundleInvalid,
        'plugin.json 不满足 bundle 契约：${error.message}',
        path: 'plugin.json',
      ),
    );
    return fail();
  } on Object catch (error) {
    // 非字符串字段等可能抛 TypeError；统一转成问题码，不向调用方抛未受控异常。
    issues.add(
      PluginLoadIssue(
        PluginLoadIssueCode.bundleInvalid,
        'plugin.json 不满足 bundle 契约：$error',
        path: 'plugin.json',
      ),
    );
    return fail();
  }

  if (bundle.apiVersion != hostApiVersion) {
    issues.add(
      PluginLoadIssue(
        PluginLoadIssueCode.apiVersionMismatch,
        'bundle apiVersion ${bundle.apiVersion} 与宿主 $hostApiVersion 不一致',
      ),
    );
  }
  if (!bundle.platforms.contains(platform)) {
    issues.add(
      PluginLoadIssue(
        PluginLoadIssueCode.platformUnsupported,
        '插件不支持平台 $platform（支持：${bundle.platforms.join(', ')}）',
      ),
    );
  }

  // 多行 bundle 必须每行都有稳定 id；单行 bundle 允许省略并回退为 bundle id。
  final entries = <LoadedPluginEntry>[];
  final seenIds = <String>{};
  for (final plugin in bundle.plugins) {
    var id = plugin.id;
    if (id == null) {
      if (bundle.plugins.length == 1) {
        id = bundle.id;
      } else {
        issues.add(
          const PluginLoadIssue(
            PluginLoadIssueCode.duplicatePluginId,
            '多行 bundle 中的插件缺少 id，无法稳定标识',
          ),
        );
        continue;
      }
    }
    if (!seenIds.add(id.toLowerCase())) {
      issues.add(
        PluginLoadIssue(
          PluginLoadIssueCode.duplicatePluginId,
          '插件 id 重复（不区分大小写）：$id',
        ),
      );
      continue;
    }

    final entry = plugin.entry;
    if (plugin.runtime != PluginRuntime.declarative) {
      // PluginBundle.fromJson 已保证非 declarative 有非空 entry；此处纵深防御。
      if (entry == null || entry.isEmpty) {
        issues.add(
          PluginLoadIssue(
            PluginLoadIssueCode.missingEntryFile,
            '${plugin.runtime.name} 插件缺少 entry',
            path: id,
          ),
        );
        continue;
      }
      if (!extraction.files.containsKey(entry)) {
        issues.add(
          PluginLoadIssue(
            PluginLoadIssueCode.missingEntryFile,
            '入口文件不存在：$entry',
            path: entry,
          ),
        );
        continue;
      }
    } else if (entry != null && !extraction.files.containsKey(entry)) {
      issues.add(
        PluginLoadIssue(
          PluginLoadIssueCode.missingEntryFile,
          '入口文件不存在：$entry',
          path: entry,
        ),
      );
      continue;
    }

    Map<String, Object?>? configSchemaJson;
    final configSchema = plugin.configSchema;
    if (configSchema != null) {
      final configBytes = extraction.files[configSchema];
      if (configBytes == null) {
        issues.add(
          PluginLoadIssue(
            PluginLoadIssueCode.configInvalid,
            'configSchema 文件不存在：$configSchema',
            path: configSchema,
          ),
        );
      } else {
        final decodedSchema = _decodeJsonObject(
          configBytes,
          PluginLoadIssueCode.configInvalid,
          'configSchema',
          configSchema,
          issues,
        );
        if (decodedSchema != null) {
          if (decodedSchema.containsKey('type') &&
              decodedSchema['type'] is! String) {
            issues.add(
              PluginLoadIssue(
                PluginLoadIssueCode.configInvalid,
                'configSchema 顶层 type 必须是字符串',
                path: configSchema,
              ),
            );
          } else {
            // 结果对象不可变：对外只暴露只读视图。
            configSchemaJson = Map<String, Object?>.unmodifiable(decodedSchema);
          }
        }
      }
    }

    entries.add(
      LoadedPluginEntry(
        id: id,
        runtime: plugin.runtime,
        entry: entry,
        slots: plugin.slots,
        permissions: plugin.permissions,
        configSchema: configSchema,
        configSchemaJson: configSchemaJson,
        network: plugin.network,
      ),
    );
  }

  for (final unmet in bundle.unmetDependencies(installedVersions)) {
    issues.add(
      PluginLoadIssue(
        PluginLoadIssueCode.dependencyUnmet,
        '依赖 ${unmet.id} 不满足：${unmet.reason}',
        path: unmet.id,
      ),
    );
  }

  if (issues.isNotEmpty) return fail();

  return PluginBundleLoadResult._(
    ok: true,
    bundle: LoadedPluginBundle(
      bundle: bundle,
      files: extraction.files,
      sha256Hex: extraction.sha256Hex,
      entries: List<LoadedPluginEntry>.unmodifiable(entries),
    ),
    issues: const <PluginLoadIssue>[],
    sha256Hex: extraction.sha256Hex,
  );
}

/// 把 JSON 字节解析为字符串键对象；失败时向 [issues] 追加对应问题并返回 null。
Map<String, Object?>? _decodeJsonObject(
  Uint8List bytes,
  PluginLoadIssueCode code,
  String label,
  String path,
  List<PluginLoadIssue> issues,
) {
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException catch (error) {
    issues.add(
      PluginLoadIssue(
        code,
        '$label 不是合法 JSON / UTF-8：${error.message}',
        path: path,
      ),
    );
    return null;
  } on Object catch (error) {
    issues.add(PluginLoadIssue(code, '$label 解析失败：$error', path: path));
    return null;
  }
  if (decoded is! Map) {
    issues.add(PluginLoadIssue(code, '$label 顶层必须是对象', path: path));
    return null;
  }
  final json = <String, Object?>{};
  for (final entry in decoded.entries) {
    final key = entry.key;
    if (key is! String) {
      issues.add(PluginLoadIssue(code, '$label 的键必须是字符串', path: path));
      return null;
    }
    json[key] = entry.value;
  }
  return json;
}
