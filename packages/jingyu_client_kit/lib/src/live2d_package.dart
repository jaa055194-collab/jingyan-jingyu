/// Device-local Live2D model package (`*.model3.json` bundle) safety checks.
///
/// Pure Dart, no file system or network: the caller hands the zip bytes in and
/// receives a structured preflight result, not a safe extraction guarantee.
/// The archive pre-scan checks declared sizes; reads of the manifest, MOC3,
/// and referenced textures also cap actual output and check ZIP CRC. This
/// checks headers, not complete model geometry or PNG image data, and does not
/// validate every optional payload or write files.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'live2d_model_info.dart';
import 'live2d_preview_inflate_stub.dart'
    if (dart.library.io) 'live2d_preview_inflate_io.dart';
import 'plugin_package.dart';

/// Checked renderer inputs only. Names are generated, never taken from the ZIP.
/// This is not a fully decoded model or a ready-to-render signal.
final class Live2DPreviewBundle {
  Live2DPreviewBundle._(
      Map<String, Uint8List> files, this.groups, this.warnings)
      : files = Map.unmodifiable(files);

  String get model3Name => 'model.model3.json';

  /// `model.model3.json`, `model.moc3`, `texture-N.png`, `physics.physics3.json`
  /// and `pose.pose3.json` when kept, and, for the expressions and motions
  /// kept, `expression-N.exp3.json` and `motion-N.motion3.json`, N counting
  /// from 0 in manifest order.
  final Map<String, Uint8List> files;

  /// The package manifest's `Groups`, as [Live2DPackageValidation.groups]
  /// reads them, for mapping suggestions (`Live2DParamProposal`). The
  /// generated manifest keeps only the first `EyeBlink` and the first
  /// `LipSync` of them, in that order, as `Parameter` groups, so the viewer
  /// blinks and lip-syncs with the model's own parameters; it has no `Groups`
  /// when the package has neither.
  final List<Live2DModelGroup> groups;

  /// Non-fatal problems: expressions, motions, physics or pose left out of the
  /// preview.
  final List<Live2DPackageIssue> warnings;
}

/// Prepare an isolated static preview, without extracting arbitrary ZIP entries.
/// Callers must cap file reads before passing their bytes here, and must not
/// expose these resources to a network-enabled or untrusted viewer.
Live2DPreviewBundle prepareLive2DPreview(
  Uint8List bytes, {
  Live2DPackageLimits limits = const Live2DPackageLimits(),
  int maxArchiveBytes = 160 * 1024 * 1024,
  int maxPreviewBytes = 96 * 1024 * 1024,
}) {
  if (maxArchiveBytes < 1 || bytes.length > maxArchiveBytes) {
    throw const FormatException('Live2D ZIP exceeds the preview input cap');
  }
  final output = <String, Uint8List>{};
  final result = _validateLive2DPackage(
    bytes, limits: limits, preview: output, maxPreviewBytes: maxPreviewBytes,
  );
  if (!result.ok) {
    throw FormatException('Live2D preview rejected: ${result.issues.first.code.name}');
  }
  return Live2DPreviewBundle._(output, result.groups, result.warnings);
}

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
    this.maxExpressionBytes = 1024 * 1024,
    this.maxMotionBytes = 8 * 1024 * 1024,
    this.maxPhysicsBytes = 1024 * 1024,
    this.maxPoseBytes = 1024 * 1024,
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

  /// Largest `*.exp3.json` file an expression may use. A larger one leaves
  /// only that expression out, with a warning.
  final int maxExpressionBytes;

  /// Largest `*.motion3.json` file a motion may use. A larger one leaves only
  /// that motion out, with a warning.
  final int maxMotionBytes;

  /// Largest `*.physics3.json` file the model may use. A larger one leaves the
  /// physics out, with a warning.
  final int maxPhysicsBytes;

  /// Largest `*.pose3.json` file the model may use. A larger one leaves the
  /// pose out, with a warning.
  final int maxPoseBytes;
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

  /// Warning: an expression left out. The message says why.
  expressionSkipped,

  /// Warning: a motion, a motion group or the rest of the motions left out.
  /// The message says why and names the group, if there is one.
  motionSkipped,

  /// Warning: the model's physics3 left out. The message says why.
  physicsSkipped,

  /// Warning: the model's pose3 left out. The message says why.
  poseSkipped,
}

class Live2DPackageIssue {
  const Live2DPackageIssue(this.code, this.message, {this.path, this.index});

  final Live2DPackageIssueCode code;
  final String message;
  final String? path;

  /// For an expression or motion warning, the entry's index in
  /// `FileReferences.Expressions` or in its motion group; null when the
  /// warning is about a whole list or group.
  final int? index;

  @override
  String toString() {
    final at = index == null ? '' : '[$index]';
    return path == null
        ? '${code.name}$at: $message'
        : '${code.name}$at($path): $message';
  }
}

/// A `Groups` entry of a model3 manifest.
///
/// The Cubism framework looks a group up by [name], such as `EyeBlink` or
/// `LipSync`, takes the first group with that name and drives every one of its
/// [ids]; it does not read the entry's `Target` (`CubismModelSettingJson` in
/// Live2D/CubismWebFramework).
final class Live2DModelGroup {
  Live2DModelGroup({required this.name, required Iterable<String> ids})
      : ids = List.unmodifiable(ids);

  final String name;

  /// The group's IDs in file order.
  final List<String> ids;

  @override
  String toString() => 'Live2DModelGroup($name, $ids)';
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
    this.groups = const [],
    this.warnings = const [],
  });

  final bool ok;
  final String? model3Path;
  final String? mocPath;
  final List<String> textures;

  /// Pixels counted before the budget was exhausted; exact for a valid package.
  final int totalPixels;
  final String sha256Hex;
  final List<Live2DPackageIssue> issues;

  /// The manifest's `Groups` in file order, or empty unless [ok].
  ///
  /// Groups only feed mapping suggestions, so they never fail validation. An
  /// entry without a string `Name` of 1 to [Live2DModelInfo.maxIdLength]
  /// characters is skipped, and so is any ID that is not such a string: no
  /// group lookup or runtime ID can match them. A `Groups` value that is not a
  /// list, or that holds more than [Live2DModelInfo.maxEntries] entries or IDs
  /// in total, gives no groups.
  final List<Live2DModelGroup> groups;

  /// Expressions and motions left out for a problem of that entry alone, in
  /// manifest order, or empty unless [ok]. They never fail validation. A
  /// preview leaves out at least these, and more if its byte cap needs it.
  final List<Live2DPackageIssue> warnings;

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

({int width, int height})? _pngDimensions(List<int> bytes) {
  // The first chunk must be a complete 13-byte IHDR, including its CRC.
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 33) return null;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  if (_u32be(bytes, 8) != 13 ||
      _u32be(bytes, 12) != 0x49484452 || // IHDR
      _u32be(bytes, 29) != getCrc32(bytes.sublist(12, 29))) {
    return null;
  }
  final width = _u32be(bytes, 16);
  final height = _u32be(bytes, 20);
  const maxPngDimension = 0x7fffffff;
  if (width <= 0 ||
      height <= 0 ||
      width > maxPngDimension ||
      height > maxPngDimension) {
    return null;
  }
  return (width: width, height: height);
}

bool _isMoc3(List<int> bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0x4D && // M
    bytes[1] == 0x4F && // O
    bytes[2] == 0x43 && // C
    bytes[3] == 0x33; // 3

int _u32be(List<int> bytes, int offset) =>
    bytes[offset] * 0x1000000 +
    bytes[offset + 1] * 0x10000 +
    bytes[offset + 2] * 0x100 +
    bytes[offset + 3];

bool _exceedsJsonDepth(String text, int limit) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (final c in text.codeUnits) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == 0x5c) {
        escaped = true;
      } else if (c == 0x22) {
        inString = false;
      }
    } else if (c == 0x22) {
      inString = true;
    } else if (c == 0x7b || c == 0x5b) {
      if (++depth > limit) return true;
    } else if ((c == 0x7d || c == 0x5d) && depth > 0) {
      depth--;
    }
  }
  return false;
}

class _LimitedEntryOutput extends OutputStream {
  _LimitedEntryOutput(this.limit) : super(size: 32768);

  final int limit;

  void _check(int count) {
    if (count < 0 || count > limit - length) {
      throw const FormatException('ZIP entry exceeds its declared length');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    _check(len ?? bytes.length);
    super.writeBytes(bytes, len);
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    _check(stream.length);
    super.writeInputStream(stream);
  }
}

// Do not use ArchiveFile.content: it materializes the entry before checking
// its declared size. Selected entries are read once and checked against CRC.
List<int> _readVerifiedEntry(ArchiveFile file, {required bool forPreview}) {
  final raw = file.rawContent;
  if (raw == null || file.size < 0) {
    throw const FormatException('missing ZIP entry data');
  }
  final List<int> bytes;
  switch (file.compressionType) {
    case ArchiveFile.STORE:
      if (raw.length != file.size) {
        throw const FormatException('stored ZIP entry length mismatch');
      }
      bytes = raw.toUint8List();
    case ArchiveFile.DEFLATE:
      final input = raw.toUint8List();
      if (forPreview) {
        bytes = inflatePreviewEntry(input, file.size);
      } else {
        final output = _LimitedEntryOutput(file.size);
        Inflate.stream(InputStream(input), output);
        bytes = output.getBytes();
      }
    default:
      throw const FormatException('unsupported ZIP entry compression');
  }
  if (bytes.length != file.size || getCrc32(bytes) != file.crc32) {
    throw const FormatException('ZIP entry length or checksum mismatch');
  }
  return bytes;
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
  const invalidEnd = Live2DPackageIssue(
      Live2DPackageIssueCode.notZip, 'missing or malformed ZIP end record');
  if (bytes.length < 22) return const _PreScan(false, [invalidEnd]);
  final data = ByteData.sublistView(bytes);
  var eocd = -1;
  // Match archive's last-signature selection, but reject a candidate that
  // cannot be a complete end record. Do not let the decoder select another.
  final minOffset = bytes.length > 65557 ? bytes.length - 65557 : 0;
  for (var i = bytes.length - 5; i >= minOffset; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0 || eocd + 22 > bytes.length ||
      eocd + 22 + data.getUint16(eocd + 20, Endian.little) != bytes.length) {
    return const _PreScan(false, [invalidEnd]);
  }

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
  if (rawEntries > limits.maxEntries) {
    return _PreScan(false, [Live2DPackageIssue(Live2DPackageIssueCode.tooManyEntries,
        '$rawEntries entries > ${limits.maxEntries}')]);
  }
  final cdEnd = cdOffset + cdSize;
  if (cdEnd != eocd || data.getUint16(eocd + 4, Endian.little) != 0 ||
      data.getUint16(eocd + 6, Endian.little) != 0 ||
      data.getUint16(eocd + 8, Endian.little) != rawEntries) {
    return const _PreScan(false, [invalidEnd]);
  }

  var off = cdOffset;
  var count = 0;
  var total = 0;
  var blocking = false;
  var malformed = false;
  while (off + 46 <= cdEnd) {
    if (count >= rawEntries ||
        data.getUint32(off, Endian.little) != 0x02014b50) {
      malformed = true;
      break;
    }
    final versionMadeBy = data.getUint16(off + 4, Endian.little);
    final compressedSize = data.getUint32(off + 20, Endian.little);
    final uncompressedSize = data.getUint32(off + 24, Endian.little);
    final localOffset = data.getUint32(off + 42, Endian.little);
    if (compressedSize == 0xffffffff || uncompressedSize == 0xffffffff ||
        data.getUint16(off + 34, Endian.little) != 0 || localOffset + 30 > cdOffset ||
        data.getUint32(localOffset, Endian.little) != 0x04034b50) {
      malformed = true;
      break;
    }
    final payloadOffset = localOffset + 30 +
        data.getUint16(localOffset + 26, Endian.little) +
        data.getUint16(localOffset + 28, Endian.little);
    if (payloadOffset + compressedSize > cdOffset) {
      malformed = true;
      break;
    }
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

/// Reads a model3 `Groups` value by the rules of
/// [Live2DPackageValidation.groups].
List<Live2DModelGroup> _readGroups(Object? raw) {
  const maxEntries = Live2DModelInfo.maxEntries;
  bool isId(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= Live2DModelInfo.maxIdLength;
  if (raw is! List || raw.length > maxEntries) return const [];
  final groups = <Live2DModelGroup>[];
  var idCount = 0;
  for (final entry in raw) {
    if (entry is! Map<String, Object?>) continue;
    final ids = entry['Ids'];
    final rawIds = ids is List ? ids : const <Object?>[];
    idCount += rawIds.length;
    if (idCount > maxEntries) return const [];
    final name = entry['Name'];
    if (name is! String || !isId(name)) continue;
    groups.add(
      Live2DModelGroup(name: name, ids: rawIds.whereType<String>().where(isId)),
    );
  }
  return List.unmodifiable(groups);
}

/// Validate a local Live2D package. Pure function: deterministic for one input.
Live2DPackageValidation validateLive2DPackage(
  Uint8List bytes, {
  Live2DPackageLimits limits = const Live2DPackageLimits(),
  String? expectedSha256Hex,
}) => _validateLive2DPackage(bytes, limits: limits, expectedSha256Hex: expectedSha256Hex);

// Caps on the expressions and motions a package keeps, matching what
// Live2DModelInfo accepts back from the viewer. Entries beyond a cap are left
// out with a warning.
const _maxExpressions = Live2DModelInfo.maxExpressions;
const _maxMotionsPerGroup = Live2DModelInfo.maxMotionsPerGroup;
const _maxMotions = 4096;
const _maxMotionGroups = Live2DModelInfo.maxEntries;
const _maxNameLength = Live2DModelInfo.maxIdLength;

// A motion's FadeInTime or FadeOutTime, kept only as a finite number >= 0.
num? _fadeTime(Object? value) =>
    value is num && value.isFinite && value >= 0 ? value : null;

Live2DPackageValidation _validateLive2DPackage(
  Uint8List bytes, {
  required Live2DPackageLimits limits,
  String? expectedSha256Hex,
  Map<String, Uint8List>? preview,
  int maxPreviewBytes = 0,
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

  // Check central-directory metadata before calling the decoder. Declared
  // sizes can reject obvious violations but do not bound actual output.
  final preScan = _preScanCentralDirectory(bytes, limits);
  issues.addAll(preScan.issues);
  if (!preScan.allowDecode) {
    return fail();
  }

  Archive archive;
  final headers = <String, ZipFileHeader>{};
  try {
    final ZipDirectory directory;
    if (preview == null) {
      final decoder = ZipDecoder();
      archive = decoder.decodeBytes(bytes);
      directory = decoder.directory;
    } else {
      // Read metadata and raw streams only; ZipDecoder eagerly expands links.
      directory = ZipDirectory.read(InputStream(bytes));
      archive = Archive();
      for (final header in directory.fileHeaders) {
        final entry = header.file!;
        final type = (header.externalFileAttributes! >> 16) & 0xf000;
        final unix = header.versionMadeBy >> 8 == 3;
        if (unix && type == 0xa000) {
          throw const FormatException('symbolic links are not preview inputs');
        }
        final file = ArchiveFile(entry.filename, entry.uncompressedSize!, entry,
            entry.compressionMethod)
          ..isFile = !entry.filename.endsWith('/') &&
              (!unix || type == 0 || type == 0x8000)
          ..crc32 = entry.crc32;
        archive.addFile(file);
      }
    }
    for (final header in directory.fileHeaders) {
      final path = sanitizePackageEntryPath(header.filename);
      if (path == null) continue;
      if (headers.containsKey(path)) {
        issues.add(Live2DPackageIssue(Live2DPackageIssueCode.duplicateEntry,
            'duplicate ZIP header', path: path));
        continue;
      }
      headers[path] = header;
    }
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

  if (issues.isNotEmpty) return fail();

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
  if (model3File.size > limits.maxModel3Bytes) {
    issues.add(Live2DPackageIssue(Live2DPackageIssueCode.model3TooLarge,
        'model3 manifest exceeds ${limits.maxModel3Bytes} bytes',
        path: model3Path));
    return fail(model3Path: model3Path);
  }

  // A read that is not fatal leaves reporting the failure to the caller.
  List<int>? verify(ArchiveFile file, String path, {bool fatal = true}) {
    try {
      final header = headers[path];
      final zipFile = header?.file;
      if (header == null || zipFile == null ||
          header.uncompressedSize != file.size ||
          header.compressedSize != file.rawContent?.length ||
          header.compressedSize != zipFile.compressedSize ||
          header.crc32 != file.crc32 ||
          header.compressionMethod != file.compressionType ||
          header.generalPurposeBitFlag != zipFile.flags ||
          (zipFile.flags & 1) != 0) {
        throw const FormatException('ZIP entry metadata mismatch');
      }
      return _readVerifiedEntry(file, forPreview: preview != null);
    } catch (_) {
      if (fatal) {
        issues.add(Live2DPackageIssue(Live2DPackageIssueCode.notZip,
            'invalid ZIP entry data', path: path));
      }
      return null;
    }
  }

  final model3Bytes = verify(model3File, model3Path);
  if (model3Bytes == null) return fail(model3Path: model3Path);
  Map<String, Object?> root;
  try {
    final text = utf8.decode(model3Bytes);
    if (_exceedsJsonDepth(text, limits.maxJsonDepth)) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.model3TooDeep,
          'model3 JSON nesting exceeds ${limits.maxJsonDepth}', path: model3Path));
      return fail(model3Path: model3Path);
    }
    final decoded = jsonDecode(text);
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

  final base = model3Path.substring(0, model3Path.lastIndexOf('/') + 1);
  final referenced = <String>[];

  String? requireReference(Object? value, String label, String suffix,
      {bool mustExist = true}) {
    if (value is! String || value.trim().isEmpty) {
      issues.add(
        Live2DPackageIssue(
          Live2DPackageIssueCode.model3Invalid,
          'invalid $label reference',
          path: model3Path,
        ),
      );
      return null;
    }
    // Validate the raw reference, not the combined path. The manifest is not
    // rewritten, so a normalized alias is not equivalent to a canonical path.
    if (sanitizePackageEntryPath(value) != value) {
      issues.add(
        Live2DPackageIssue(
          Live2DPackageIssueCode.unsafeEntryPath,
          '$label reference must be a canonical relative path',
          path: value,
        ),
      );
      return null;
    }
    if (!value.toLowerCase().endsWith(suffix)) {
      issues.add(
        Live2DPackageIssue(
          Live2DPackageIssueCode.model3Invalid,
          '$label reference must point to a $suffix file',
          path: value,
        ),
      );
      return null;
    }
    final resolved = '$base$value';
    if (mustExist) referenced.add(resolved);
    return resolved;
  }

  final mocPath = requireReference(mocRef, 'Moc', '.moc3');
  final texturePaths = <String>[];
  for (final raw in rawTextures) {
    final resolved = requireReference(raw, 'Texture', '.png');
    if (resolved != null) texturePaths.add(resolved);
  }

  const optionalSuffixes = {
    'Physics': '.physics3.json',
    'Pose': '.pose3.json',
    'DisplayInfo': '.cdi3.json',
  };
  // The resolved paths of the optional single-file references, for staging.
  final optionalResolved = <String, String>{};
  for (final entry in optionalSuffixes.entries) {
    final value = fileRefs[entry.key];
    if (value != null) {
      final resolved = requireReference(value, entry.key, entry.value);
      if (resolved != null) optionalResolved[entry.key] = resolved;
    }
  }
  // For an expression or motion, only an unsafe or wrongly suffixed File path
  // fails the package. Anything else wrong with one entry leaves just that
  // entry out, with a warning, once everything required has passed.
  final expressions = fileRefs['Expressions'];
  if (expressions is List) {
    for (final item in expressions) {
      if (item is Map<String, Object?> && item['File'] is String) {
        requireReference(item['File'], 'Expression', '.exp3.json',
            mustExist: false);
      }
    }
  }
  final motions = fileRefs['Motions'];
  if (motions is Map<String, Object?>) {
    for (final group in motions.values) {
      if (group is List) {
        for (final item in group) {
          if (item is Map<String, Object?> && item['File'] is String) {
            requireReference(item['File'], 'Motion', '.motion3.json',
                mustExist: false);
          }
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

  if (preview != null && issues.isNotEmpty) return fail(model3Path: model3Path);

  var previewBytes = 0;
  void checkPreviewBudget(int size) {
    if (preview != null && size > maxPreviewBytes - previewBytes) {
      throw const FormatException('Live2D preview exceeds its resource byte cap');
    }
  }

  void retain(String name, List<int> data) {
    checkPreviewBudget(data.length);
    // Stored ZIP bytes may alias the caller's original buffer.
    preview![name] = Uint8List.fromList(data).asUnmodifiableView();
    previewBytes += data.length;
  }

  int totalPixels = 0;
  if (mocPath != null && entries.containsKey(mocPath)) {
    final mocEntry = entries[mocPath]!;
    checkPreviewBudget(mocEntry.size);
    final mocBytes = verify(mocEntry, mocPath);
    if (mocBytes == null) return fail(model3Path: model3Path, mocPath: mocPath);
    if (!_isMoc3(mocBytes)) {
      issues.add(Live2DPackageIssue(Live2DPackageIssueCode.badMocMagic,
          'MOC3 magic missing', path: mocPath));
    } else {
      final version = mocBytes[4] | (mocBytes[5] << 8) | (mocBytes[6] << 16) |
          (mocBytes[7] << 24);
      if (version < 1 || version > 5) {
        issues.add(Live2DPackageIssue(Live2DPackageIssueCode.badMocMagic,
            'unsupported MOC3 version $version', path: mocPath));
      } else if (preview != null) {
        retain('model.moc3', mocBytes);
      }
    }
  }

  final previewNames = <String, String>{};
  final dimensionsByPath = <String, ({int width, int height})?>{};
  for (final path in texturePaths) {
    final file = entries[path];
    if (file == null) continue;
    List<int>? textureBytes;
    if (!dimensionsByPath.containsKey(path)) {
      checkPreviewBudget(file.size);
      textureBytes = verify(file, path);
      if (textureBytes == null) {
        return fail(model3Path: model3Path, mocPath: mocPath);
      }
      dimensionsByPath[path] = _pngDimensions(textureBytes);
    }
    final dimensions = dimensionsByPath[path];
    if (dimensions == null) {
      issues.add(
        Live2DPackageIssue(
          Live2DPackageIssueCode.badTextureMagic,
          'texture has an invalid PNG signature or IHDR',
          path: path,
        ),
      );
      continue;
    }
    final (width: width, height: height) = dimensions;
    final remaining = limits.maxTotalPixels - totalPixels;
    // Check the remaining budget before multiplying or adding dimensions.
    if (remaining < 0 || width > remaining ~/ height) {
      issues.add(
        Live2DPackageIssue(
          Live2DPackageIssueCode.textureBudgetExceeded,
          '${width}x$height texture exceeds remaining pixel budget of $remaining',
          path: path,
        ),
      );
      break;
    }
    totalPixels += width * height;
    if (preview != null && textureBytes != null) {
      final name = 'texture-${previewNames.length}.png';
      previewNames[path] = name;
      retain(name, textureBytes);
    }
  }

  final ok = issues.isEmpty;
  final modelGroups =
      ok ? _readGroups(root['Groups']) : const <Live2DModelGroup>[];
  final warnings = <Live2DPackageIssue>[];
  if (ok) {
    // Keep each usable expression and motion under a generated name. A problem
    // confined to one entry leaves only that entry out, with a warning.
    int jsonBytes(Object? value) => utf8.encode(jsonEncode(value)).length;
    void warn(Live2DPackageIssueCode code, String why,
            {String? path, int? index}) =>
        warnings.add(Live2DPackageIssue(code, why, path: path, index: index));

    final refs = <String, Object?>{
      'Moc': 'model.moc3',
      'Textures': [
        if (preview != null)
          for (final path in texturePaths) previewNames[path]!,
      ],
    };
    // The model's own blink and lip-sync parameters, which the viewer looks
    // up as Cubism does: the first EyeBlink group, then the first LipSync.
    final keptGroups = [
      for (final name in const ['EyeBlink', 'LipSync'])
        for (final group in modelGroups.where((g) => g.name == name).take(1))
          {'Target': 'Parameter', 'Name': name, 'Ids': group.ids},
    ];
    final generated = {
      'Version': 3,
      'FileReferences': refs,
      if (keptGroups.isNotEmpty) 'Groups': keptGroups,
    };
    // The generated model3's size so far: exact, so that no expression or
    // motion can push it over the preview byte cap.
    var generatedBytes = preview == null ? 0 : jsonBytes(generated);
    const noRoom = 'no room left under the preview byte cap';

    // Why the file cannot be used, or its bytes: none when only validating.
    Object readJson(ArchiveFile file, String path) {
      final data = verify(file, path, fatal: false);
      if (data == null) return 'invalid ZIP entry data';
      final String text;
      try {
        text = utf8.decode(data);
      } on FormatException {
        return 'file is not UTF-8';
      }
      if (_exceedsJsonDepth(text, limits.maxJsonDepth)) {
        return 'JSON nesting exceeds ${limits.maxJsonDepth}';
      }
      try {
        if (jsonDecode(text) is! Map<String, Object?>) {
          return 'file is not a JSON object';
        }
      } on FormatException catch (error) {
        return 'file is not valid JSON: ${error.message}';
      }
      return preview == null ? const <int>[] : data;
    }

    // Each file is read at most once, and in a preview only after the byte
    // cap has room for it. Once staged, its staged copy stands in for it.
    final reads = <String, Object>{};

    // Stages the file at [path] as [name] for an entry that adds [extra]
    // bytes to the generated model3. Returns why it cannot, or null.
    String? stage(String path, String name, int maxBytes, int extra) {
      final file = entries[path];
      if (file == null) return 'file is missing from the package';
      if (file.size > maxBytes) return 'file exceeds $maxBytes bytes';
      if (preview != null &&
          file.size + extra > maxPreviewBytes - previewBytes - generatedBytes) {
        return noRoom;
      }
      final data = reads.putIfAbsent(path, () => readJson(file, path));
      if (data is String) return data;
      if (preview != null) {
        retain(name, data as List<int>);
        reads[path] = preview[name]!;
        generatedBytes += extra;
      }
      return null;
    }

    // The optional single-file references (physics and pose) are staged under
    // fixed names. A problem with one leaves just it out, with a warning.
    const physicsSkipped = Live2DPackageIssueCode.physicsSkipped;
    const poseSkipped = Live2DPackageIssueCode.poseSkipped;
    void stageOptional(String key, String staged, int maxBytes,
        Live2DPackageIssueCode code) {
      final path = optionalResolved[key];
      if (path == null) return;
      final extra = jsonBytes(key) + jsonBytes(staged) + 2;
      final why = stage(path, staged, maxBytes, extra);
      if (why != null) {
        warn(code, why, path: path);
      } else {
        refs[key] = staged;
      }
    }

    stageOptional('Physics', 'physics.physics3.json',
        limits.maxPhysicsBytes, physicsSkipped);
    stageOptional('Pose', 'pose.pose3.json', limits.maxPoseBytes, poseSkipped);

    const expressionSkipped = Live2DPackageIssueCode.expressionSkipped;
    final keptExpressions = <Map<String, Object?>>[];
    if (expressions is List) {
      final names = <String>{};
      for (var i = 0; i < expressions.length; i++) {
        void skip(String why, [String? path]) =>
            warn(expressionSkipped, why, path: path, index: i);
        if (i == _maxExpressions) {
          skip('at most $_maxExpressions expressions are kept: '
              '${expressions.length - i} left out');
          break;
        }
        final item = expressions[i];
        if (item is! Map<String, Object?>) {
          skip('entry is not an object');
          continue;
        }
        final file = item['File'];
        if (file is! String) {
          skip('File is not a string');
          continue;
        }
        final path = '$base$file';
        final name = item['Name'];
        if (name is! String || name.isEmpty) {
          skip('Name is not a non-empty string', path);
          continue;
        }
        if (name.length > _maxNameLength) {
          skip('Name is longer than $_maxNameLength characters', path);
          continue;
        }
        if (names.contains(name)) {
          skip('duplicate Name ${jsonEncode(name)}', path);
          continue;
        }
        final staged = 'expression-${keptExpressions.length}.exp3.json';
        final entry = <String, Object?>{'Name': name, 'File': staged};
        // Its model3 bytes: the entry, then a comma or the list itself.
        final extra = jsonBytes(entry) +
            (keptExpressions.isEmpty ? jsonBytes('Expressions') + 4 : 1);
        final why = stage(path, staged, limits.maxExpressionBytes, extra);
        // The first entry with a usable file claims its Name. One left out
        // only for the byte cap claims it too, so that a preview keeps no
        // expression that validation leaves out.
        if (why == null || why == noRoom) names.add(name);
        if (why != null) {
          skip(why, path);
          continue;
        }
        keptExpressions.add(entry);
      }
    } else if (expressions != null) {
      warn(expressionSkipped, 'FileReferences.Expressions is not a list');
    }

    const motionSkipped = Live2DPackageIssueCode.motionSkipped;
    final keptMotions = <String, List<Map<String, Object?>>>{};
    var keptMotionCount = 0;
    if (motions is Map<String, Object?>) {
      var groupCount = 0;
      var motionCount = 0;
      groups:
      for (final MapEntry(key: group, value: list) in motions.entries) {
        if (groupCount == _maxMotionGroups) {
          warn(motionSkipped,
              'at most $_maxMotionGroups motion groups are kept: '
              '${motions.length - groupCount} left out');
          break;
        }
        groupCount++;
        if (group.length > _maxNameLength) {
          warn(motionSkipped,
              'motion group ${groupCount - 1} has a name longer than '
              '$_maxNameLength characters');
          continue;
        }
        final label = 'group ${jsonEncode(group)}';
        if (list is! List) {
          warn(motionSkipped, '$label is not a list');
          continue;
        }
        for (var j = 0; j < list.length; j++) {
          void skip(String why, [String? path]) =>
              warn(motionSkipped, '$label: $why', path: path, index: j);
          if (j == _maxMotionsPerGroup) {
            skip('at most $_maxMotionsPerGroup motions of a group are kept: '
                '${list.length - j} left out');
            break;
          }
          if (motionCount == _maxMotions) {
            skip('at most $_maxMotions motions are kept: the rest are left out');
            break groups;
          }
          motionCount++;
          final item = list[j];
          if (item is! Map<String, Object?>) {
            skip('entry is not an object');
            continue;
          }
          final file = item['File'];
          if (file is! String) {
            skip('File is not a string');
            continue;
          }
          final path = '$base$file';
          final staged = 'motion-$keptMotionCount.motion3.json';
          final entry = <String, Object?>{
            'File': staged,
            'FadeInTime': ?_fadeTime(item['FadeInTime']),
            'FadeOutTime': ?_fadeTime(item['FadeOutTime']),
          };
          // Its model3 bytes: the entry, then a comma or its group's list,
          // which needs a comma or the Motions object itself.
          final extra = jsonBytes(entry) +
              (keptMotions.containsKey(group)
                  ? 1
                  : jsonBytes(group) +
                      3 +
                      (keptMotions.isEmpty ? jsonBytes('Motions') + 4 : 1));
          final why = stage(path, staged, limits.maxMotionBytes, extra);
          if (why != null) {
            skip(why, path);
            continue;
          }
          (keptMotions[group] ??= []).add(entry);
          keptMotionCount++;
        }
      }
    } else if (motions != null) {
      warn(motionSkipped, 'FileReferences.Motions is not an object');
    }

    if (preview != null) {
      if (keptExpressions.isNotEmpty) refs['Expressions'] = keptExpressions;
      if (keptMotions.isNotEmpty) refs['Motions'] = keptMotions;
      retain('model.model3.json', utf8.encode(jsonEncode(generated)));
    }
  }
  return Live2DPackageValidation._(
    ok: ok,
    model3Path: model3Path,
    mocPath: mocPath,
    textures: List<String>.unmodifiable(texturePaths),
    totalPixels: totalPixels,
    sha256Hex: sha256Hex,
    issues: List<Live2DPackageIssue>.unmodifiable(issues),
    groups: modelGroups,
    warnings: List<Live2DPackageIssue>.unmodifiable(warnings),
  );
}
