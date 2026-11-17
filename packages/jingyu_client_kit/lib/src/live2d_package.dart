/// Device-local Live2D model package (`*.model3.json` bundle) safety checks.
///
/// Pure Dart, no file system or network: the caller hands the zip bytes in and
/// receives a structured result. This validates archive safety, the referenced
/// MOC3/PNG resources and texture memory budget. It pre-scans the central
/// directory using declared sizes before decompression; archive decoding is not
/// itself a bounded stream, so treat a forged header as residual risk and only
/// import user-selected local files. It does not render, decode full model
/// geometry, verify that a parameter name exists in the model, or prove that
/// the model will display correctly.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'plugin_package.dart';

/// Safety and resource limits for a local Live2D package.
class Live2DPackageLimits {
  const Live2DPackageLimits({
    this.maxEntries = 4096,
    this.maxTotalUncompressedBytes = 512 * 1024 * 1024,
    this.maxEntryUncompressedBytes = 256 * 1024 * 1024,
    this.maxCompressionRatio = 200,
    this.maxModel3Bytes = 4 * 1024 * 1024,
    this.maxJsonDepth = 64,
    this.maxTotalPixels = 200000000,
  });

  final int maxEntries;
  final int maxTotalUncompressedBytes;
  final int maxEntryUncompressedBytes;
  final int maxCompressionRatio;
  final int maxModel3Bytes;
  final int maxJsonDepth;

  /// Sum of referenced texture pixels. The supplied sample model totals about
  /// 155M pixels; the default permits it but callers on constrained devices
  /// should lower this (and/or downsample) after measuring GPU limits.
  final int maxTotalPixels;
}

enum Live2DPackageIssueCode {
  empty,
  notZip,
  tooManyEntries,
  entryTooLarge,
  totalTooLarge,
  compressionRatioTooHigh,
  unsafeEntryPath,
  symbolicLink,
  duplicateEntry,
  disallowedFileType,
  missingModel3,
  multipleModel3,
  model3TooLarge,
  model3TooDeep,
  model3InvalidJson,
  model3Invalid,
  missingMocReference,
  missingTextures,
  missingReferencedFile,
  badMocMagic,
  badTextureMagic,
  textureBudgetExceeded,
  integrityMismatch,
}

class Live2DPackageIssue {
  const Live2DPackageIssue(this.code, this.message, {this.path});

  final Live2DPackageIssueCode code;
  final String message;
  final String? path;

  @override
  String toString() =>
      path == null ? '${code.name}: $message' : '${code.name}($path): $message';
}

class Live2DPackageValidation {
  const Live2DPackageValidation._({
    required this.ok,
    required this.model3Path,
    required this.mocPath,
    required this.textures,
    required this.totalPixels,
    required this.sha256Hex,
    required this.issues,
  });

  final bool ok;
  final String? model3Path;
  final String? mocPath;
  final List<String> textures;
  final int totalPixels;
  final String sha256Hex;
  final List<Live2DPackageIssue> issues;

  bool get hasIssues => issues.isNotEmpty;

  @override
  String toString() =>
      'Live2DPackageValidation(ok=$ok, model3=$model3Path, textures=${textures.length}, '
      'pixels=$totalPixels, issues=${issues.length})';
}

const Set<String> _disallowedExtensions = {
  'js', 'mjs', 'cjs', 'html', 'htm', 'svg', 'wasm', 'exe', 'dll', 'so', //
  'bat', 'cmd', 'sh', 'ps1', 'py', 'jar', 'apk', 'dex',
};

bool _isPng(List<int> bytes) =>
    bytes.length >= 24 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47 &&
    bytes[4] == 0x0D &&
    bytes[5] == 0x0A &&
    bytes[6] == 0x1A &&
    bytes[7] == 0x0A;

bool _isMoc3(List<int> bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0x4D && // M
    bytes[1] == 0x4F && // O
    bytes[2] == 0x43 && // C
    bytes[3] == 0x33; // 3

int _u32be(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _jsonDepth(Object? value) {
  if (value is Map) {
    var max = 0;
    for (final v in value.values) {
      final d = _jsonDepth(v);
      if (d > max) max = d;
    }
    return max + 1;
  }
  if (value is List) {
    var max = 0;
    for (final v in value) {
      final d = _jsonDepth(v);
      if (d > max) max = d;
    }
    return max + 1;
  }
  return 0;
}

String? _dirName(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? null : path.substring(0, i);
}

String? _joinAndSanitize(String base, String relative) {
  final combined = base.isEmpty ? relative : '$base/$relative';
  return sanitizePackageEntryPath(combined);
}

class _PreScan {
  const _PreScan(this.allowDecode, this.issues);
  final bool allowDecode;
  final List<Live2DPackageIssue> issues;
}

/// Read only the zip central directory (no decompression) and reject declared
/// oversize/too-many entries and zip64 (unsupported, fail-closed).
_PreScan _preScanCentralDirectory(
    Uint8List bytes, Live2DPackageLimits limits) {
  final issues = <Live2DPackageIssue>[];
  if (bytes.length < 22) return _PreScan(true, issues);
  final data = ByteData.sublistView(bytes);
  var eocd = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return _PreScan(true, issues);

  final rawEntries = data.getUint16(eocd + 10, Endian.little);
  final cdSize = data.getUint32(eocd + 12, Endian.little);
  final cdOffset = data.getUint32(eocd + 16, Endian.little);
  if (data.getUint16(eocd + 4, Endian.little) == 0xFFFF ||
      data.getUint16(eocd + 6, Endian.little) == 0xFFFF ||
      data.getUint16(eocd + 8, Endian.little) == 0xFFFF ||
      rawEntries == 0xFFFF ||
      cdSize == 0xFFFFFFFF ||
      cdOffset == 0xFFFFFFFF) {
    issues.add(const Live2DPackageIssue(
        Live2DPackageIssueCode.notZip, 'zip64 packages are not supported'));
    return _PreScan(false, issues);
  }
  final cdEnd = cdOffset + cdSize;
  if (cdOffset < 0 || cdEnd > bytes.length || cdOffset + 46 > cdEnd) {
    if (cdOffset + 46 > cdEnd && cdEnd <= bytes.length) {
      return _PreScan(true, issues); // empty/short directory handled by decoder
    }
    issues.add(const Live2DPackageIssue(
        Live2DPackageIssueCode.notZip, 'central directory out of bounds'));
    return _PreScan(false, issues);
  }

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
    if ((versionMadeBy >> 8) == 3 &&
        ((externalAttrs >> 16) & 0xF000) == 0xA000) {
      issues.add(Live2DPackageIssue(
          Live2DPackageIssueCode.symbolicLink, 'symbolic link not allowed',
          path: name));
      blocking = true;
    }
    if (!name.endsWith('/') &&
        uncompressedSize > limits.maxEntryUncompressedBytes) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.entryTooLarge,
          'declared entry $uncompressedSize bytes > '
          '${limits.maxEntryUncompressedBytes}',
          path: name));
      blocking = true;
    }
    total += uncompressedSize;
    off = nextOff;
  }

  if (malformed || count != rawEntries || off != cdEnd) {
    issues.add(const Live2DPackageIssue(Live2DPackageIssueCode.notZip,
        'central directory malformed or entry count mismatch'));
    return _PreScan(false, issues);
  }
  if (count > limits.maxEntries) {
    issues.add(Live2DPackageIssue(Live2DPackageIssueCode.tooManyEntries,
        '$count entries > ${limits.maxEntries}'));
    blocking = true;
  } else if (total > limits.maxTotalUncompressedBytes) {
    issues.add(Live2DPackageIssue(Live2DPackageIssueCode.totalTooLarge,
        'declared total $total bytes > ${limits.maxTotalUncompressedBytes}'));
    blocking = true;
  }
  return _PreScan(!blocking, issues);
}

/// Validate a local Live2D package. Pure function: deterministic for one input.
Live2DPackageValidation validateLive2DPackage(
  Uint8List bytes, {
  Live2DPackageLimits limits = const Live2DPackageLimits(),
  String? expectedSha256Hex,
}) {
  final issues = <Live2DPackageIssue>[];
  final sha256Hex = crypto.sha256.convert(bytes).toString();

  final expected = expectedSha256Hex?.trim().toLowerCase();
  if (expected != null && expected.isNotEmpty && expected != sha256Hex) {
    issues.add(Live2DPackageIssue(
      Live2DPackageIssueCode.integrityMismatch,
      'package sha256 $sha256Hex != expected $expected',
    ));
  }

  Live2DPackageValidation fail({
    String? model3Path,
    String? mocPath,
    List<String> textures = const [],
    int totalPixels = 0,
  }) =>
      Live2DPackageValidation._(
        ok: false,
        model3Path: model3Path,
        mocPath: mocPath,
        textures: textures,
        totalPixels: totalPixels,
        sha256Hex: sha256Hex,
        issues: issues,
      );

  if (bytes.isEmpty) {
    issues.add(const Live2DPackageIssue(
        Live2DPackageIssueCode.empty, 'package is empty'));
    return fail();
  }

  // Fail-closed pre-scan of the central directory using declared sizes, so a
  // forged-header zip bomb is rejected before archive eagerly decompresses it.
  final preScan = _preScanCentralDirectory(bytes, limits);
  issues.addAll(preScan.issues);
  if (!preScan.allowDecode) {
    return fail();
  }

  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (error) {
    issues.add(Live2DPackageIssue(
        Live2DPackageIssueCode.notZip, 'not a valid zip: $error'));
    return fail();
  }

  final files = archive.files;
  if (files.isEmpty) {
    issues.add(const Live2DPackageIssue(
        Live2DPackageIssueCode.empty, 'zip has no entries'));
    return fail();
  }
  if (files.length > limits.maxEntries) {
    issues.add(Live2DPackageIssue(Live2DPackageIssueCode.tooManyEntries,
        '${files.length} entries > ${limits.maxEntries}'));
  }

  final entries = <String, ArchiveFile>{};
  final seen = <String>{};
  var totalUncompressed = 0;
  for (final file in files) {
    if (file.isSymbolicLink) {
      issues.add(Live2DPackageIssue(
          Live2DPackageIssueCode.symbolicLink, 'symbolic link not allowed',
          path: file.name));
      continue;
    }
    final safe = sanitizePackageEntryPath(file.name);
    if (safe == null) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.unsafeEntryPath,
          'unsafe entry path', path: file.name));
      continue;
    }
    if (!seen.add(safe.toLowerCase())) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.duplicateEntry,
          'duplicate entry (case-insensitive)', path: file.name));
      continue;
    }
    if (!file.isFile) continue;
    final dot = safe.lastIndexOf('.');
    final ext = dot < 0 ? '' : safe.substring(dot + 1).toLowerCase();
    if (_disallowedExtensions.contains(ext)) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.disallowedFileType,
          'disallowed file type .$ext', path: safe));
      continue;
    }
    if (file.size > limits.maxEntryUncompressedBytes) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.entryTooLarge,
          'entry ${file.size} bytes > ${limits.maxEntryUncompressedBytes}',
          path: safe));
      continue;
    }
    totalUncompressed += file.size;
    entries[safe] = file;
  }

  if (totalUncompressed > limits.maxTotalUncompressedBytes) {
    issues.add(Live2DPackageIssue(Live2DPackageIssueCode.totalTooLarge,
        'uncompressed total $totalUncompressed > ${limits.maxTotalUncompressedBytes}'));
  } else if (totalUncompressed > 0) {
    final ratio = totalUncompressed / bytes.length;
    if (ratio > limits.maxCompressionRatio) {
      issues.add(Live2DPackageIssue(
          Live2DPackageIssueCode.compressionRatioTooHigh,
          'compression ratio ${ratio.toStringAsFixed(1)} > ${limits.maxCompressionRatio}'));
    }
  }

  final model3Paths = entries.keys
      .where((name) => name.toLowerCase().endsWith('.model3.json'))
      .toList()
    ..sort();
  if (model3Paths.isEmpty) {
    issues.add(const Live2DPackageIssue(Live2DPackageIssueCode.missingModel3,
        'no *.model3.json manifest found'));
    return fail();
  }
  if (model3Paths.length > 1) {
    issues.add(Live2DPackageIssue(Live2DPackageIssueCode.multipleModel3,
        'expected one model3 manifest, found ${model3Paths.length}'));
    return fail();
  }
  final model3Path = model3Paths.single;
  final model3File = entries[model3Path]!;
  final model3Bytes = model3File.content as List<int>;
  if (model3Bytes.length > limits.maxModel3Bytes) {
    issues.add(Live2DPackageIssue(Live2DPackageIssueCode.model3TooLarge,
        'model3 manifest exceeds ${limits.maxModel3Bytes} bytes',
        path: model3Path));
    return fail(model3Path: model3Path);
  }

  Map<String, Object?> root;
  try {
    final decoded = jsonDecode(utf8.decode(model3Bytes));
    if (decoded is! Map<String, Object?>) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.model3Invalid,
          'model3 root is not an object', path: model3Path));
      return fail(model3Path: model3Path);
    }
    root = decoded;
  } on FormatException catch (error) {
    issues.add(Live2DPackageIssue(Live2DPackageIssueCode.model3InvalidJson,
        'model3 is not valid JSON: ${error.message}', path: model3Path));
    return fail(model3Path: model3Path);
  }
  if (_jsonDepth(root) > limits.maxJsonDepth) {
    issues.add(Live2DPackageIssue(Live2DPackageIssueCode.model3TooDeep,
        'model3 JSON nesting exceeds ${limits.maxJsonDepth}', path: model3Path));
    return fail(model3Path: model3Path);
  }

  final fileRefs = root['FileReferences'];
  if (fileRefs is! Map<String, Object?>) {
    issues.add(Live2DPackageIssue(Live2DPackageIssueCode.model3Invalid,
        'FileReferences missing', path: model3Path));
    return fail(model3Path: model3Path);
  }

  final mocRef = fileRefs['Moc'];
  if (mocRef is! String || mocRef.trim().isEmpty) {
    issues.add(Live2DPackageIssue(Live2DPackageIssueCode.missingMocReference,
        'FileReferences.Moc missing', path: model3Path));
    return fail(model3Path: model3Path);
  }
  final rawTextures = fileRefs['Textures'];
  if (rawTextures is! List || rawTextures.isEmpty) {
    issues.add(Live2DPackageIssue(Live2DPackageIssueCode.missingTextures,
        'FileReferences.Textures empty or missing', path: model3Path));
    return fail(model3Path: model3Path);
  }

  final base = _dirName(model3Path) ?? '';

  final referenced = <String>[];
  final mocPath = _joinAndSanitize(base, mocRef);
  if (mocPath == null) {
    issues.add(Live2DPackageIssue(Live2DPackageIssueCode.unsafeEntryPath,
        'unsafe Moc reference', path: mocRef));
  } else {
    referenced.add(mocPath);
  }

  final texturePaths = <String>[];
  for (final raw in rawTextures) {
    if (raw is! String || raw.trim().isEmpty) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.model3Invalid,
          'non-string texture reference', path: model3Path));
      continue;
    }
    final resolved = _joinAndSanitize(base, raw);
    if (resolved == null) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.unsafeEntryPath,
          'unsafe texture reference', path: raw));
    } else {
      texturePaths.add(resolved);
      referenced.add(resolved);
    }
  }

  void requireOptional(Object? value, String label) {
    if (value == null) return;
    if (value is! String || value.trim().isEmpty) {
      issues.add(Live2DPackageIssue(
          Live2DPackageIssueCode.model3Invalid, 'invalid $label reference',
          path: model3Path));
      return;
    }
    final resolved = _joinAndSanitize(base, value);
    if (resolved == null) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.unsafeEntryPath,
          'unsafe $label reference', path: value));
    } else {
      referenced.add(resolved);
    }
  }

  requireOptional(fileRefs['Physics'], 'Physics');
  requireOptional(fileRefs['Pose'], 'Pose');
  requireOptional(fileRefs['DisplayInfo'], 'DisplayInfo');
  final expressions = fileRefs['Expressions'];
  if (expressions is List) {
    for (final item in expressions) {
      if (item is Map<String, Object?>) requireOptional(item['File'], 'Expression');
    }
  }
  final motions = fileRefs['Motions'];
  if (motions is Map<String, Object?>) {
    for (final group in motions.values) {
      if (group is List) {
        for (final item in group) {
          if (item is Map<String, Object?>) requireOptional(item['File'], 'Motion');
        }
      }
    }
  }

  for (final path in referenced) {
    if (!entries.containsKey(path)) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.missingReferencedFile,
          'referenced file is missing from the package', path: path));
    }
  }

  int totalPixels = 0;
  if (mocPath != null && entries.containsKey(mocPath)) {
    final mocBytes = entries[mocPath]!.content as List<int>;
    if (!_isMoc3(mocBytes)) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.badMocMagic,
          'MOC3 magic missing', path: mocPath));
    } else {
      final version = mocBytes[4] | (mocBytes[5] << 8) | (mocBytes[6] << 16) |
          (mocBytes[7] << 24);
      if (version < 1 || version > 5) {
        issues.add(Live2DPackageIssue(Live2DPackageIssueCode.badMocMagic,
            'unsupported MOC3 version $version', path: mocPath));
      }
    }
  }

  for (final path in texturePaths) {
    final file = entries[path];
    if (file == null) continue;
    final tex = file.content as List<int>;
    if (!_isPng(tex)) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.badTextureMagic,
          'texture is not a PNG', path: path));
      continue;
    }
    final width = _u32be(tex, 16);
    final height = _u32be(tex, 20);
    if (width <= 0 || height <= 0) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.badTextureMagic,
          'invalid PNG dimensions ${width}x$height', path: path));
      continue;
    }
    totalPixels += width * height;
  }
  if (totalPixels > limits.maxTotalPixels) {
    issues.add(Live2DPackageIssue(
        Live2DPackageIssueCode.textureBudgetExceeded,
        'texture pixels $totalPixels > ${limits.maxTotalPixels}'));
  }

  final ok = issues.isEmpty;
  return Live2DPackageValidation._(
    ok: ok,
    model3Path: model3Path,
    mocPath: mocPath,
    textures: List<String>.unmodifiable(texturePaths),
    totalPixels: totalPixels,
    sha256Hex: sha256Hex,
    issues: List<Live2DPackageIssue>.unmodifiable(issues),
  );
}
