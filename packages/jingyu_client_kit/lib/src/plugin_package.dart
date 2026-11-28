/// 插件包（bundle zip）安全校验。
///
/// 纯 Dart、不读文件系统：调用方把插件包 zip 的字节交给 [validatePluginPackage]，
/// 返回结构化结果。用于插件安装前做「条目 / 体积 / 压缩比 / 路径 / 清单 / 完整性」
/// 校验，对齐插件方案 v3 §7（安全模型）与 §8（包校验落点）。
///
/// 依赖方向：只依赖 `archive`（zip 解码，MIT）与 `crypto`（sha256，BSD-3-Clause），
/// 不引入 Flutter，也不 import `dart:io`，因此服务端与双端外壳都能直接复用。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'plugin.dart';

/// 校验上限。默认值参考 v3 §7 与 FR-39（防 zip 炸弹、超大包与路径穿越）。
///
/// 全部字段可注入，便于测试与后续按平台/来源调整；关闭某项校验时把对应上限调大即可。
class PluginPackageLimits {
  const PluginPackageLimits({
    this.maxEntries = 512,
    this.maxTotalUncompressedBytes = 64 * 1024 * 1024,
    this.maxEntryUncompressedBytes = 16 * 1024 * 1024,
    this.maxCompressionRatio = 100,
    this.maxManifestBytes = 256 * 1024,
    this.maxJsonDepth = 32,
  });

  /// 允许的条目（含目录）数量上限。
  final int maxEntries;

  /// 解压后总字节数上限。
  final int maxTotalUncompressedBytes;

  /// 单条目解压后字节数上限。
  final int maxEntryUncompressedBytes;

  /// 解压后总字节 / 包字节 的最大比值，超过视为疑似 zip 炸弹。
  final int maxCompressionRatio;

  /// 根 `plugin.json` 允许的最大字节数。
  final int maxManifestBytes;

  /// `plugin.json` 允许的最大 JSON 嵌套深度（防深层递归解析 DoS）。
  final int maxJsonDepth;
}

/// 校验问题代码。作为稳定字符串暴露，方便测试与 UI 映射文案。
enum PluginPackageIssueCode {
  /// 空字节或压缩包内没有任何条目。
  empty,

  /// 不是可解析的 zip。
  notZip,

  /// 条目数超过上限。
  tooManyEntries,

  /// 单条目解压后超过上限。
  entryTooLarge,

  /// 解压后总量超过上限。
  totalTooLarge,

  /// 解压/压缩比过高，疑似 zip 炸弹。
  compressionRatioTooHigh,

  /// 条目路径不安全（绝对路径、盘符或包含 `..`）。
  unsafeEntryPath,

  /// 重复条目（不区分大小写，按目标平台合并）。
  duplicateEntry,

  /// 包含符号链接条目（插件包不允许）。
  symbolicLink,

  /// 缺少根目录 `plugin.json`。
  missingManifest,

  /// `plugin.json` 超过体积上限。
  manifestTooLarge,

  /// `plugin.json` JSON 嵌套过深。
  manifestTooDeep,

  /// `plugin.json` 不是合法 JSON / UTF-8。
  manifestInvalidJson,

  /// `plugin.json` 结构不满足插件清单契约。
  manifestInvalid,

  /// sha256 完整性校验不通过。
  integrityMismatch,
}

/// 一条校验问题。[path] 为相关条目路径（若适用）。
class PluginPackageIssue {
  const PluginPackageIssue(this.code, this.message, {this.path});

  final PluginPackageIssueCode code;
  final String message;
  final String? path;

  @override
  String toString() =>
      path == null ? '${code.name}: $message' : '${code.name}($path): $message';
}

/// 校验结果。任一步失败都会在 [issues] 中记录，并令 [ok] 为 false。
class PluginPackageValidation {
  const PluginPackageValidation._({
    required this.ok,
    required this.manifest,
    required this.sha256Hex,
    required this.issues,
  });

  /// 是否可以通过安装校验（无 issue 且清单解析成功）。
  final bool ok;

  /// 解析出的插件清单；仅当清单成功解析时非 null。
  final PluginManifest? manifest;

  /// 整个插件包字节的 sha256（小写十六进制，64 字符），用于完整性比对与登记。
  final String sha256Hex;

  /// 全部问题。空表示没有问题。
  final List<PluginPackageIssue> issues;

  bool get hasIssues => issues.isNotEmpty;

  @override
  String toString() =>
      'PluginPackageValidation(ok=$ok, manifest=${manifest?.id}, sha256=$sha256Hex, '
      'issues=${issues.length})';
}

/// 校验一个插件包 zip 的字节。
///
/// - [expectedSha256Hex]：可选。给定时与包字节的 sha256 比对，便于安装/发布时做完整性校验。
/// - 纯函数：不读写文件、不联网；同一输入返回同一结果（sha256 亦稳定）。
///
/// 只做「包结构与清单结构」校验；`apiVersion` / `platforms` / `hostOnly` 是否可加载
/// 仍由 [PluginHost.load] 判定（关注点分离），避免两处重复策略。
PluginPackageValidation validatePluginPackage(
  Uint8List bytes, {
  PluginPackageLimits limits = const PluginPackageLimits(),
  String? expectedSha256Hex,
}) {
  final issues = <PluginPackageIssue>[];
  final sha256Hex = crypto.sha256.convert(bytes).toString();

  final expected = expectedSha256Hex?.trim().toLowerCase();
  if (expected != null && expected.isNotEmpty && expected != sha256Hex) {
    issues.add(PluginPackageIssue(
      PluginPackageIssueCode.integrityMismatch,
      '插件包 sha256 与期望值不一致：实际 $sha256Hex，期望 $expected',
    ));
  }

  PluginPackageValidation fail(PluginManifest? manifest) =>
      PluginPackageValidation._(
        ok: false,
        manifest: manifest,
        sha256Hex: sha256Hex,
        issues: issues,
      );

  if (bytes.isEmpty) {
    issues.add(
        const PluginPackageIssue(PluginPackageIssueCode.empty, '插件包为空'));
    return fail(null);
  }

  // 解码前先按中央目录预扫：符号链接必须在 decode 前拒绝（archive 解码会即时
  // 解压符号链接目标，早于任何限额，恶意小包可打爆内存）；同时用声明尺寸先做
  // 条目数/单条/总量限额，超限直接拒绝，不进入解码。
  final preScan = _preScanCentralDirectory(bytes, limits);
  issues.addAll(preScan.issues);
  if (!preScan.allowDecode) {
    return fail(null);
  }

  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (error) {
    issues.add(PluginPackageIssue(
        PluginPackageIssueCode.notZip, '不是有效的 zip 插件包：$error'));
    return fail(null);
  }

  final files = archive.files;
  if (files.isEmpty) {
    issues.add(const PluginPackageIssue(
        PluginPackageIssueCode.empty, '插件包里没有任何条目'));
    return fail(null);
  }
  if (files.length > limits.maxEntries) {
    issues.add(PluginPackageIssue(PluginPackageIssueCode.tooManyEntries,
        '条目数 ${files.length} 超过上限 ${limits.maxEntries}'));
  }

  var totalUncompressed = 0;
  final seen = <String>{};
  ArchiveFile? manifestFile;
  for (final file in files) {
    final rawName = file.name;
    if (file.isSymbolicLink) {
      issues.add(PluginPackageIssue(
          PluginPackageIssueCode.symbolicLink, '不允许的符号链接条目',
          path: rawName));
      continue;
    }
    final safe = sanitizePackageEntryPath(rawName);
    if (safe == null) {
      issues.add(PluginPackageIssue(
          PluginPackageIssueCode.unsafeEntryPath, '不安全的条目路径（绝对路径、盘符或包含 ..）',
          path: rawName));
      continue;
    }
    if (!seen.add(safe.toLowerCase())) {
      issues.add(PluginPackageIssue(
          PluginPackageIssueCode.duplicateEntry, '重复条目（不区分大小写）',
          path: rawName));
    }
    if (!file.isFile) continue;
    if (file.size > limits.maxEntryUncompressedBytes) {
      issues.add(PluginPackageIssue(PluginPackageIssueCode.entryTooLarge,
          '单条目解压后 ${file.size} 字节，超过上限 ${limits.maxEntryUncompressedBytes}',
          path: rawName));
    }
    totalUncompressed += file.size;
    if (safe == 'plugin.json' && manifestFile == null) {
      manifestFile = file;
    }
  }

  if (totalUncompressed > limits.maxTotalUncompressedBytes) {
    issues.add(PluginPackageIssue(PluginPackageIssueCode.totalTooLarge,
        '解压后总量 $totalUncompressed 字节，超过上限 ${limits.maxTotalUncompressedBytes}'));
  } else if (totalUncompressed > 0) {
    final ratio = totalUncompressed / bytes.length;
    if (ratio > limits.maxCompressionRatio) {
      issues.add(PluginPackageIssue(
          PluginPackageIssueCode.compressionRatioTooHigh,
          '解压/压缩比 ${ratio.toStringAsFixed(1)} 超过上限 ${limits.maxCompressionRatio}（疑似 zip 炸弹）'));
    }
  }

  if (manifestFile == null) {
    issues.add(const PluginPackageIssue(
        PluginPackageIssueCode.missingManifest, '缺少根目录 plugin.json'));
    return fail(null);
  }
  if (manifestFile.size > limits.maxManifestBytes) {
    issues.add(PluginPackageIssue(PluginPackageIssueCode.manifestTooLarge,
        'plugin.json ${manifestFile.size} 字节，超过上限 ${limits.maxManifestBytes}',
        path: 'plugin.json'));
    return fail(null);
  }

  // 头里声明的 size 可被伪造：绝不能“先完整 inflate 再复核”——伪造头（声明很小、
  // 实际 DEFLATE 输出巨大）会在复核前就分配完整输出，构成内存 DoS。这里用有界
  // 流式 inflate，在解压过程中按“真实输出字节”封顶，一旦超限立即中止（fail-closed）。
  // 清单条目同时受单条上限与清单上限约束，取二者较小值作为硬上限。
  final manifestCap = limits.maxManifestBytes < limits.maxEntryUncompressedBytes
      ? limits.maxManifestBytes
      : limits.maxEntryUncompressedBytes;
  PluginPackageIssueCode manifestCapCode() =>
      limits.maxManifestBytes <= limits.maxEntryUncompressedBytes
          ? PluginPackageIssueCode.manifestTooLarge
          : PluginPackageIssueCode.entryTooLarge;

  late final Uint8List manifestBytes;
  try {
    manifestBytes = _inflateEntryBounded(manifestFile, manifestCap);
  } on _OutputLimitExceeded {
    issues.add(PluginPackageIssue(manifestCapCode(),
        'plugin.json 实际解压超过上限 $manifestCap 字节（伪造头/压缩炸弹，已在解压中中止）',
        path: 'plugin.json'));
    return fail(null);
  } catch (error) {
    issues.add(PluginPackageIssue(PluginPackageIssueCode.manifestInvalidJson,
        'plugin.json 解压失败：$error',
        path: 'plugin.json'));
    return fail(null);
  }
  // 头里声明的 size 可被伪造：真实解压后再按真实字节数复核（纵深防御）。
  if (manifestBytes.length > limits.maxManifestBytes) {
    issues.add(PluginPackageIssue(PluginPackageIssueCode.manifestTooLarge,
        'plugin.json 解压后 ${manifestBytes.length} 字节，超过上限 ${limits.maxManifestBytes}',
        path: 'plugin.json'));
    return fail(null);
  }
  if (manifestBytes.length > limits.maxEntryUncompressedBytes) {
    issues.add(PluginPackageIssue(PluginPackageIssueCode.entryTooLarge,
        'plugin.json 解压后 ${manifestBytes.length} 字节，超过单条上限 ${limits.maxEntryUncompressedBytes}',
        path: 'plugin.json'));
    return fail(null);
  }
  // 用真实清单字节修正“解压总量”，避免伪造头把总量少算而绕过 totalTooLarge。
  final realTotal =
      totalUncompressed + (manifestBytes.length - manifestFile.size);
  if (realTotal > limits.maxTotalUncompressedBytes) {
    issues.add(PluginPackageIssue(PluginPackageIssueCode.totalTooLarge,
        '解压后总量（按真实清单长度）$realTotal 字节，超过上限 ${limits.maxTotalUncompressedBytes}'));
    return fail(null);
  }

  late final String manifestText;
  try {
    manifestText = utf8.decode(manifestBytes);
  } on FormatException catch (error) {
    issues.add(PluginPackageIssue(PluginPackageIssueCode.manifestInvalidJson,
        'plugin.json 不是合法 UTF-8：${error.message}',
        path: 'plugin.json'));
    return fail(null);
  }

  if (_jsonNestingDepth(manifestText) > limits.maxJsonDepth) {
    issues.add(PluginPackageIssue(PluginPackageIssueCode.manifestTooDeep,
        'plugin.json 嵌套深度超过上限 ${limits.maxJsonDepth}',
        path: 'plugin.json'));
    return fail(null);
  }

  Object? decoded;
  try {
    decoded = jsonDecode(manifestText);
  } on FormatException catch (error) {
    issues.add(PluginPackageIssue(PluginPackageIssueCode.manifestInvalidJson,
        'plugin.json 不是合法 JSON：${error.message}',
        path: 'plugin.json'));
    return fail(null);
  }

  if (decoded is! Map) {
    issues.add(const PluginPackageIssue(PluginPackageIssueCode.manifestInvalid,
        'plugin.json 顶层必须是对象', path: 'plugin.json'));
    return fail(null);
  }
  final json = <String, Object?>{};
  for (final entry in decoded.entries) {
    final key = entry.key;
    if (key is! String) {
      issues.add(const PluginPackageIssue(PluginPackageIssueCode.manifestInvalid,
          'plugin.json 的键必须是字符串', path: 'plugin.json'));
      return fail(null);
    }
    json[key] = entry.value;
  }

  PluginManifest manifest;
  try {
    manifest = PluginManifest.fromJson(json);
  } on FormatException catch (error) {
    issues.add(PluginPackageIssue(PluginPackageIssueCode.manifestInvalid,
        'plugin.json 不满足插件清单契约：${error.message}',
        path: 'plugin.json'));
    return fail(null);
  } on Object catch (error) {
    // 非字符串字段等会抛 TypeError 之类的非 FormatException；统一转成问题码，
    // 不向调用方抛出未受控异常（例如 license 为非字符串）。
    issues.add(PluginPackageIssue(PluginPackageIssueCode.manifestInvalid,
        'plugin.json 不满足插件清单契约：$error',
        path: 'plugin.json'));
    return fail(null);
  }

  final ok = issues.isEmpty;
  return PluginPackageValidation._(
    ok: ok,
    manifest: manifest,
    sha256Hex: sha256Hex,
    issues: issues,
  );
}

/// 把压缩包条目路径规范化为安全的相对路径（以 `/` 分隔、去掉 `.` 与空段）。
///
/// 不安全时返回 null：空串、绝对路径（`/` 开头）、盘符（`C:`）、包含 `..` 段、
/// 或段内含控制字符 / `:`（NTFS 备用数据流）。用于拦截 Zip Slip 与越界写入。
String? sanitizePackageEntryPath(String entryName) {
  if (entryName.isEmpty) return null;
  final normalized = entryName.replaceAll('\\', '/');
  if (normalized.startsWith('/')) return null;
  if (normalized.length >= 2 &&
      normalized[1] == ':' &&
      _isAsciiLetter(normalized.codeUnitAt(0))) {
    return null;
  }
  final segments = <String>[];
  for (final segment in normalized.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') return null;
    // Windows 会去掉尾随的点/空格，可能与其它条目撞名或绕过检查，直接拒绝。
    if (segment.endsWith('.') || segment.endsWith(' ')) return null;
    // Windows 保留设备名（CON/PRN/AUX/NUL/COM1-9/LPT1-9）不可作为文件名。
    final dot = segment.indexOf('.');
    final stem = (dot < 0 ? segment : segment.substring(0, dot)).toUpperCase();
    if (_windowsReservedNames.contains(stem)) return null;
    for (final code in segment.codeUnits) {
      if (code == 0 || code == 0x3A) return null; // NUL 或 ':'
      if (code < 0x20) return null; // 控制字符
    }
    segments.add(segment);
  }
  if (segments.isEmpty) return null;
  return segments.join('/');
}

/// Windows 保留设备名（不区分大小写）。
const Set<String> _windowsReservedNames = {
  'CON', 'PRN', 'AUX', 'NUL', 'CONIN\$', 'CONOUT\$', //
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

/// 中央目录预扫结论：[allowDecode] 为 false 时不得进入解码。
class _PreScanResult {
  const _PreScanResult(this.allowDecode, this.issues);
  final bool allowDecode;
  final List<PluginPackageIssue> issues;
}

/// 只读解析 zip 中央目录（不解压任何条目），在解码前完成：
/// - 拒绝符号链接条目（archive 解码会即时解压符号链接目标，早于限额检查）；
/// - 用声明的未压缩尺寸先做条目数/单条/总量限额（伪造尺寸的条目不会被解压，
///   但可提前拒绝明显超限的包）。
///
/// 无法解析出 EOCD 时返回 allowDecode=true，交由 [ZipDecoder] 报 notZip；
/// zip64（哨兵值）暂不支持，fail-closed 拒绝。
_PreScanResult _preScanCentralDirectory(
    Uint8List bytes, PluginPackageLimits limits) {
  final issues = <PluginPackageIssue>[];
  if (bytes.length < 22) return _PreScanResult(true, issues);
  final data = ByteData.sublistView(bytes);
  var eocd = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return _PreScanResult(true, issues);

  final rawEntries = data.getUint16(eocd + 10, Endian.little);
  final cdSize = data.getUint32(eocd + 12, Endian.little);
  final cdOffset = data.getUint32(eocd + 16, Endian.little);
  // zip64 触发与 archive 的 ZipDirectory.read 完全对齐：任一盘号/条目计数字段
  // 为 0xFFFF，或 CD 大小/偏移为 0xFFFFFFFF，都视为 zip64（fail-closed 拒绝）。
  if (data.getUint16(eocd + 4, Endian.little) == 0xFFFF ||
      data.getUint16(eocd + 6, Endian.little) == 0xFFFF ||
      data.getUint16(eocd + 8, Endian.little) == 0xFFFF ||
      rawEntries == 0xFFFF ||
      cdSize == 0xFFFFFFFF ||
      cdOffset == 0xFFFFFFFF) {
    issues.add(const PluginPackageIssue(
        PluginPackageIssueCode.notZip, '暂不支持 zip64 插件包'));
    return _PreScanResult(false, issues);
  }
  final cdEnd = cdOffset + cdSize;
  if (cdOffset < 0 || cdEnd > bytes.length) {
    // 合法 zip 的 cdEnd 必 ≤ EOCD 位置 ≤ 文件长度；越过 EOF 视为异常并 fail-closed。
    // 不能“交由解码器报 notZip”：archive 的 subset/toUint8List 会截断而不报错，可能仍
    // 解码出符号链接（解码期解压目标），从而绕过预扫。
    issues.add(const PluginPackageIssue(
        PluginPackageIssueCode.notZip, '中央目录超出文件边界'));
    return _PreScanResult(false, issues);
  }
  if (cdOffset + 46 > cdEnd) {
    // 空 / 超短中央目录（无条目）：交由解码器按 empty 处理。
    return _PreScanResult(true, issues);
  }

  // 与 archive 的 ZipDirectory.read 一致：在中央目录尺寸窗口 [cdOffset, cdEnd)
  // 内逐条解析，而不是相信 EOCD 的 16-bit 条目计数（该字段可被伪造）。
  var off = cdOffset;
  var count = 0;
  var total = 0;
  var blocking = false;
  var malformed = false;
  while (off + 46 <= cdEnd) {
    if (data.getUint32(off, Endian.little) != 0x02014b50) {
      malformed = true;
      break;
    }
    final versionMadeBy = data.getUint16(off + 4, Endian.little);
    final uncompressedSize = data.getUint32(off + 24, Endian.little);
    final nameLen = data.getUint16(off + 28, Endian.little);
    final extraLen = data.getUint16(off + 30, Endian.little);
    final commentLen = data.getUint16(off + 32, Endian.little);
    final externalAttrs = data.getUint32(off + 38, Endian.little);
    final nameStart = off + 46;
    final nameEnd = nameStart + nameLen;
    final nextOff = nameEnd + extraLen + commentLen;
    if (nameEnd > cdEnd || nextOff > cdEnd) {
      malformed = true;
      break;
    }
    final name =
        utf8.decode(bytes.sublist(nameStart, nameEnd), allowMalformed: true);
    count++;

    // UNIX 符号链接：versionMadeBy 高字节 3 且 mode 类型位 0xA000。
    if ((versionMadeBy >> 8) == 3 && ((externalAttrs >> 16) & 0xF000) == 0xA000) {
      issues.add(PluginPackageIssue(PluginPackageIssueCode.symbolicLink,
          '不允许的符号链接条目（解码前预扫）', path: name));
      blocking = true;
    }
    if (!name.endsWith('/') &&
        uncompressedSize > limits.maxEntryUncompressedBytes) {
      issues.add(PluginPackageIssue(PluginPackageIssueCode.entryTooLarge,
          '条目 $name 声明解压后 $uncompressedSize 字节，超过上限 ${limits.maxEntryUncompressedBytes}',
          path: name));
      blocking = true;
    }
    total += uncompressedSize;
    off = nextOff;
  }

  // 预扫必须与解码器看到完全一样的中央目录：结构异常、条目数与 EOCD 不符、
  // 或未恰好走完 cdSize 窗口时，一律 fail-closed，绝不进入解码。
  if (malformed || count != rawEntries || off != cdEnd) {
    issues.add(const PluginPackageIssue(PluginPackageIssueCode.notZip,
        '中央目录结构异常或条目数与 EOCD 不一致'));
    return _PreScanResult(false, issues);
  }

  if (count > limits.maxEntries) {
    issues.add(PluginPackageIssue(PluginPackageIssueCode.tooManyEntries,
        '条目数 $count 超过上限 ${limits.maxEntries}'));
    blocking = true;
  } else if (total > limits.maxTotalUncompressedBytes) {
    issues.add(PluginPackageIssue(PluginPackageIssueCode.totalTooLarge,
        '声明解压后总量 $total 字节，超过上限 ${limits.maxTotalUncompressedBytes}'));
    blocking = true;
  }
  return _PreScanResult(!blocking, issues);
}

/// 有界解压在中途超过上限时抛出的内部信号（用于在解压过程中 fail-closed）。
class _OutputLimitExceeded implements Exception {
  const _OutputLimitExceeded(this.limit);
  final int limit;

  @override
  String toString() => '解压输出超过上限 $limit 字节';
}

/// 带硬上限的输出流：任何一次写入会让累计长度超过 [limit] 时立即抛异常，
/// 使 inflate 在解压过程中中止，而不是先完整分配再检查（防伪造头/zip 炸弹）。
class _BoundedOutputStream extends OutputStream {
  _BoundedOutputStream(this.limit)
      : super(size: limit <= 0 ? 0 : (limit < 0x8000 ? limit : 0x8000));

  /// 允许的最大累计输出字节数。
  final int limit;

  void _ensure(int extra) {
    if (extra < 0 || length + extra > limit) {
      throw _OutputLimitExceeded(limit);
    }
  }

  @override
  void writeByte(int value) {
    _ensure(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    _ensure(len ?? bytes.length);
    super.writeBytes(bytes, len);
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    _ensure(stream.length);
    super.writeInputStream(stream);
  }
}

/// 对任意 zip 条目做有界解压：STORE 直接取原始字节（仍按上限校验），DEFLATE 走
/// 纯 Dart 流式 inflate 在解压过程中按真实输出字节封顶；超过 [maxBytes] 抛
/// [_OutputLimitExceeded]。不依赖中央目录里可伪造的“声明未压缩尺寸”。
Uint8List _inflateEntryBounded(ArchiveFile file, int maxBytes) {
  final cap = maxBytes < 0 ? 0 : maxBytes;
  final compression = file.compressionType;
  final raw = file.rawContent;
  if (compression == null || compression == ArchiveFile.STORE) {
    final stored = raw == null ? Uint8List(0) : raw.toUint8List();
    if (stored.length > cap) {
      throw _OutputLimitExceeded(cap);
    }
    return stored;
  }
  if (compression != ArchiveFile.DEFLATE) {
    throw FormatException('不支持的条目压缩方式 $compression');
  }
  if (raw == null) {
    throw const FormatException('条目缺少压缩数据');
  }
  return _inflateDeflateBounded(raw.toUint8List(), cap);
}

/// 纯 Dart 流式 inflate（raw DEFLATE）：输出字节数超过 [maxBytes] 时立即抛
/// [_OutputLimitExceeded]，绝不完整展开后再检查。
Uint8List _inflateDeflateBounded(Uint8List raw, int maxBytes) {
  final out = _BoundedOutputStream(maxBytes);
  Inflate.stream(InputStream(raw), out);
  final bytes = out.getBytes();
  return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
}

bool _isAsciiLetter(int code) =>
    (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);

/// 计算 JSON 文本的最大嵌套深度，忽略字符串字面量与转义。
/// 只读扫描，不真正解析，用于在 jsonDecode 前拒绝过深结构。
int _jsonNestingDepth(String text) {
  var depth = 0;
  var maxDepth = 0;
  var inString = false;
  var escaped = false;
  for (final code in text.codeUnits) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (code == 0x5C) {
        escaped = true;
      } else if (code == 0x22) {
        inString = false;
      }
      continue;
    }
    if (code == 0x22) {
      inString = true;
    } else if (code == 0x7B || code == 0x5B) {
      depth++;
      if (depth > maxDepth) maxDepth = depth;
    } else if (code == 0x7D || code == 0x5D) {
      if (depth > 0) depth--;
    }
  }
  return maxDepth;
}

/// 解包后的插件包内容（纯内存，不含目录条目）。
///
/// [files] 的 key 为经 [sanitizePackageEntryPath] 规范化的相对路径（含根
/// `plugin.json`），value 为条目真实解压后的字节。返回的 Map 与字节均为不可变
/// 语义：Map 为 [Map.unmodifiable]，字节为独立拷贝，不会泄漏输入 zip 的可变缓冲。
class PluginPackageExtraction {
  const PluginPackageExtraction._({
    required this.ok,
    required this.sha256Hex,
    required this.manifest,
    required this.files,
    required this.issues,
  });

  /// 是否成功解包（校验通过且所有条目都在限额内解压完成）。
  final bool ok;

  /// 整个插件包字节的 sha256（小写十六进制）。
  final String sha256Hex;

  /// 解析出的插件清单；仅当校验通过时非 null。
  final PluginManifest? manifest;

  /// 规范化路径 -> 真实解压字节。任何失败时为空 Map。
  final Map<String, Uint8List> files;

  /// 全部问题。空表示成功。
  final List<PluginPackageIssue> issues;

  @override
  String toString() =>
      'PluginPackageExtraction(ok=$ok, files=${files.length}, '
      'sha256=$sha256Hex, issues=${issues.length})';
}

/// 把通过校验的插件包 zip 安全解包为内存中的条目集合。
///
/// 安全约束（对齐插件方案 v3 §7 与 FR-39）：
/// - 先调用 [validatePluginPackage]；不通过时原样返回其 issues 与 sha256。
/// - 校验通过才进入 `ZipDecoder`；目录与符号链接条目不放入结果。
/// - 每个条目都复用 [_inflateEntryBounded] 的有界流式 inflate，按「真实输出字节」
///   封顶 `min(单条上限, 剩余总量上限)`；伪造头 / zip bomb 在解压过程中即
///   fail-closed，绝不先完整解压再检查。
/// - 任何失败：`ok=false`、`files` 为空、issues 至少一条。
PluginPackageExtraction extractPluginPackage(
  Uint8List bytes, {
  PluginPackageLimits limits = const PluginPackageLimits(),
  String? expectedSha256Hex,
}) {
  final validation = validatePluginPackage(
    bytes,
    limits: limits,
    expectedSha256Hex: expectedSha256Hex,
  );
  if (!validation.ok) {
    return PluginPackageExtraction._(
      ok: false,
      sha256Hex: validation.sha256Hex,
      manifest: validation.manifest,
      files: const <String, Uint8List>{},
      issues: List<PluginPackageIssue>.unmodifiable(validation.issues),
    );
  }

  PluginPackageExtraction fail(List<PluginPackageIssue> issues) =>
      PluginPackageExtraction._(
        ok: false,
        sha256Hex: validation.sha256Hex,
        manifest: validation.manifest,
        files: const <String, Uint8List>{},
        issues: List<PluginPackageIssue>.unmodifiable(issues),
      );

  final issues = <PluginPackageIssue>[];
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (error) {
    issues.add(
      PluginPackageIssue(PluginPackageIssueCode.notZip, '插件包解码失败：$error'),
    );
    return fail(issues);
  }

  final perEntryLimit = limits.maxEntryUncompressedBytes < 0
      ? 0
      : limits.maxEntryUncompressedBytes;
  final totalLimit = limits.maxTotalUncompressedBytes < 0
      ? 0
      : limits.maxTotalUncompressedBytes;
  var remainingTotal = totalLimit;
  final files = <String, Uint8List>{};
  final seen = <String>{};

  for (final file in archive.files) {
    // 校验阶段已拒绝符号链接；这里仍按契约跳过，避免任何解引用。
    if (!file.isFile || file.isSymbolicLink) continue;

    final safe = sanitizePackageEntryPath(file.name);
    if (safe == null) {
      issues.add(
        PluginPackageIssue(
          PluginPackageIssueCode.unsafeEntryPath,
          '不安全的条目路径（绝对路径、盘符或包含 ..）',
          path: file.name,
        ),
      );
      return fail(issues);
    }
    if (!seen.add(safe.toLowerCase())) {
      issues.add(
        PluginPackageIssue(
          PluginPackageIssueCode.duplicateEntry,
          '重复条目（不区分大小写）',
          path: file.name,
        ),
      );
      return fail(issues);
    }

    // 按真实解压字节封顶：单条上限与「扣除已解压内容后的剩余总量」取较小值。
    final cap = perEntryLimit < remainingTotal ? perEntryLimit : remainingTotal;
    final Uint8List content;
    try {
      content = _inflateEntryBounded(file, cap);
    } on _OutputLimitExceeded {
      if (perEntryLimit <= remainingTotal) {
        issues.add(
          PluginPackageIssue(
            PluginPackageIssueCode.entryTooLarge,
            '条目实际解压超过上限 $perEntryLimit 字节（伪造头/压缩炸弹，已在解压中中止）',
            path: file.name,
          ),
        );
      } else {
        issues.add(
          PluginPackageIssue(
            PluginPackageIssueCode.totalTooLarge,
            '解压后总量超过上限 $totalLimit 字节（伪造头/压缩炸弹，已在解压中中止）',
            path: file.name,
          ),
        );
      }
      return fail(issues);
    } catch (error) {
      issues.add(
        PluginPackageIssue(
          PluginPackageIssueCode.notZip,
          '条目解压失败：$error',
          path: file.name,
        ),
      );
      return fail(issues);
    }

    remainingTotal -= content.length;
    // 独立拷贝：STORE 条目的 rawContent 可能是输入 zip 的视图，绝不能泄漏。
    files[safe] = Uint8List.fromList(content);
  }

  if (!files.containsKey('plugin.json')) {
    issues.add(
      const PluginPackageIssue(
        PluginPackageIssueCode.missingManifest,
        '缺少根目录 plugin.json',
      ),
    );
    return fail(issues);
  }

  return PluginPackageExtraction._(
    ok: true,
    sha256Hex: validation.sha256Hex,
    manifest: validation.manifest,
    files: Map<String, Uint8List>.unmodifiable(files),
    issues: const <PluginPackageIssue>[],
  );
}
