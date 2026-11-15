/// 插件包（bundle zip）构建。纯 Dart、无 IO。
///
/// 与 [validatePluginPackage] 互为逆操作：本文件把「清单 + 文件集合」打包成
/// 一个可通过校验的 zip 字节，并给出整包 sha256，用于发布/安装前的完整性比对。
///
/// 依赖 `archive`（zip 编码，MIT）与 `crypto`（sha256，BSD-3-Clause）；
/// 路径安全复用 `plugin_package.dart` 的 [sanitizePackageEntryPath]。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'plugin_package.dart';

/// 1980-01-01T00:00:00Z 的秒数。作为固定条目时间，保证同输入产出相同字节。
const int _deterministicModTime = 315532800;

/// 构建失败（路径不安全、重复条目、与 plugin.json 冲突、清单不可序列化等）。
class PluginPackageBuildException implements Exception {
  const PluginPackageBuildException(this.message);

  final String message;

  @override
  String toString() => 'PluginPackageBuildException: $message';
}

/// 构建结果：zip 字节与整包 sha256（小写十六进制，64 字符）。
class BuiltPluginPackage {
  const BuiltPluginPackage({required this.bytes, required this.sha256Hex});

  final Uint8List bytes;
  final String sha256Hex;

  @override
  String toString() =>
      'BuiltPluginPackage(${bytes.length} bytes, sha256=$sha256Hex)';
}

/// 由清单与文件集合构建插件包 zip 字节。
///
/// - [manifest]：任意 JSON 可序列化对象，序列化后写入根 `plugin.json`。
/// - [files]：相对路径 -> 字节（`plugin.json` 以外）。
/// - [modifiedSecondsSinceEpoch]：固定条目时间（默认 1980-01-01），保证可复现。
///
/// 每个条目路径经 [sanitizePackageEntryPath] 规范化；不安全、重复（不区分大小写）
/// 或显式提供 `plugin.json` 时抛 [PluginPackageBuildException]。
/// 同一个输入（含同一 [modifiedSecondsSinceEpoch]）产出相同字节与相同 sha256。
BuiltPluginPackage buildPluginPackage({
  required Map<String, Object?> manifest,
  Map<String, List<int>> files = const {},
  int modifiedSecondsSinceEpoch = _deterministicModTime,
}) {
  final List<int> manifestBytes;
  try {
    manifestBytes = utf8.encode(jsonEncode(manifest));
  } catch (error) {
    throw PluginPackageBuildException('清单无法序列化为 JSON：$error');
  }

  // 规范化并校验附加条目；按规范化路径排序，保证输出稳定。
  final normalized = <String, List<int>>{};
  final seen = <String>{'plugin.json'};
  for (final entry in files.entries) {
    final rawPath = entry.key;
    final safe = sanitizePackageEntryPath(rawPath);
    if (safe == null) {
      throw PluginPackageBuildException('不安全的条目路径：$rawPath');
    }
    if (safe.toLowerCase() == 'plugin.json') {
      throw const PluginPackageBuildException(
          '不能显式提供 plugin.json（由 manifest 生成）');
    }
    if (!seen.add(safe.toLowerCase())) {
      throw PluginPackageBuildException('重复条目（不区分大小写）：$rawPath');
    }
    normalized[safe] = entry.value;
  }
  final sortedPaths = normalized.keys.toList()..sort();

  final archive = Archive();
  archive.addFile(_entry('plugin.json', manifestBytes, modifiedSecondsSinceEpoch));
  for (final path in sortedPaths) {
    archive.addFile(_entry(path, normalized[path]!, modifiedSecondsSinceEpoch));
  }

  // 关键：显式传入 UTC 的固定时间给编码器。archive 的 ZipEncoder 若只依赖
  // 文件 lastModTime，会用本地时区换算 DOS 时间，导致不同机器/时区产出不同字节；
  // 传入 `modified`（UTC）后 _data.time/_data.date 取自 UTC，跨时区可复现。
  final List<int>? encoded;
  try {
    encoded = ZipEncoder().encode(
      archive,
      modified: DateTime.fromMillisecondsSinceEpoch(
          modifiedSecondsSinceEpoch * 1000,
          isUtc: true),
    );
  } catch (error) {
    throw PluginPackageBuildException('zip 编码失败：$error');
  }
  if (encoded == null) {
    throw const PluginPackageBuildException('zip 编码失败');
  }
  final bytes = Uint8List.fromList(encoded);
  final sha256Hex = crypto.sha256.convert(bytes).toString();
  return BuiltPluginPackage(bytes: bytes, sha256Hex: sha256Hex);
}

ArchiveFile _entry(String name, List<int> bytes, int modified) {
  final file = ArchiveFile(name, 0, Uint8List.fromList(bytes))
    ..lastModTime = modified;
  return file;
}
