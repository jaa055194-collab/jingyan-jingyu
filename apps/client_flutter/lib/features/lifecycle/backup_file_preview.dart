import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../../net/lifecycle_api.dart';
import '../../platform/native_platform.dart';

enum BackupFilePreviewProblem {
  unreadable,
  tooLarge,
  invalid,
  wrongOwner,
  interrupted,
}

/// Deliberately carries no path, raw text, digest, or underlying exception.
class BackupFilePreviewException implements Exception {
  const BackupFilePreviewException(this.problem);
  final BackupFilePreviewProblem problem;

  @override
  String toString() => 'BackupFilePreviewException(${problem.name})';
}

/// The only information allowed to leave local validation. This is not a bundle
/// and cannot be passed to import. Counts are declarations from the manifest.
class BackupFilePreviewSummary {
  BackupFilePreviewSummary._({
    required this.bytes,
    required this.fileCount,
    required this.generatedAt,
    required this.chatHistoryOnly,
    required Map<String, int> counts,
  }) : counts = Map.unmodifiable(counts);

  final int bytes;
  final int fileCount;
  final DateTime generatedAt;
  final bool chatHistoryOnly;
  final Map<String, int> counts;
}

/// Uses the existing Windows picker without staging an attachment or making a
/// copy. Refuse picker-owned temporary files and direct UNC/device paths.
Future<BackupFilePreviewSummary?> pickBackupFilePreview({
  required NativePlatform platform,
  required String expectedOwnerAccountId,
  required bool Function() isCurrent,
}) async {
  if (!Platform.isWindows) {
    throw const BackupFilePreviewException(BackupFilePreviewProblem.unreadable);
  }
  _checkCurrent(isCurrent);
  final PickedAttachment? picked;
  try {
    picked = await platform.pickAttachment('file');
  } catch (_) {
    throw const BackupFilePreviewException(BackupFilePreviewProblem.unreadable);
  }
  _checkCurrent(isCurrent);
  if (picked == null) return null;
  if (picked.temporary ||
      !_drivePath.hasMatch(picked.path) ||
      picked.path.substring(2).contains(':') ||
      picked.path.contains('\u0000')) {
    throw const BackupFilePreviewException(BackupFilePreviewProblem.unreadable);
  }
  return readBackupFilePreview(
    File(picked.path),
    expectedOwnerAccountId: expectedOwnerAccountId,
    isCurrent: isCurrent,
  );
}

final _drivePath = RegExp(r'^[a-zA-Z]:[\\/]');

void _checkCurrent(bool Function()? isCurrent) {
  if (isCurrent != null && !isCurrent()) {
    throw const BackupFilePreviewException(
      BackupFilePreviewProblem.interrupted,
    );
  }
}

/// Reads at most the save bridge's limit plus one byte from the open file. The
/// extra byte detects oversize at the actual read, independent of length/stat.
Future<BackupFilePreviewSummary> readBackupFilePreview(
  File file, {
  required String expectedOwnerAccountId,
  bool Function()? isCurrent,
}) async {
  const limit = LifecycleExportBundle.maxFileBytes;
  final buffer = BytesBuilder(copy: false);
  try {
    _checkCurrent(isCurrent);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    _checkCurrent(isCurrent);
    if (type != FileSystemEntityType.file) {
      throw const BackupFilePreviewException(
        BackupFilePreviewProblem.unreadable,
      );
    }
    final input = await file.open(mode: FileMode.read);
    try {
      while (true) {
        _checkCurrent(isCurrent);
        final chunk = await input.read(
          math.min(64 * 1024, limit + 1 - buffer.length),
        );
        _checkCurrent(isCurrent);
        if (chunk.isEmpty) break;
        buffer.add(chunk);
        if (buffer.length > limit) {
          throw const BackupFilePreviewException(
            BackupFilePreviewProblem.tooLarge,
          );
        }
      }
    } finally {
      await input.close();
    }
  } on FileSystemException {
    throw const BackupFilePreviewException(BackupFilePreviewProblem.unreadable);
  }
  _checkCurrent(isCurrent);
  try {
    return _validate(buffer.takeBytes(), expectedOwnerAccountId);
  } on FormatException {
    throw const BackupFilePreviewException(BackupFilePreviewProblem.invalid);
  }
}

const _countKeys = {
  'conversations',
  'messages',
  'memories',
  'attachments',
  'persona',
};
const _manifestKeys = {
  'formatVersion',
  'ownerAccountId',
  'generatedAt',
  'counts',
  'excluded',
};
const _coreFiles = {
  'manifest.json',
  'SHA256SUMS',
  'persona.json',
  'memories.json',
  'attachments.json',
};
const _pendingDomains = {'persona', 'memories', 'attachments'};

BackupFilePreviewSummary _validate(Uint8List bytes, String expectedOwner) {
  final envelope = _readObject(utf8.decode(bytes, allowMalformed: false));
  final bundle = LifecycleExportBundle.fromJson(envelope);
  AccountId.parse(bundle.ownerAccountId);
  final files = bundle.files;
  final manifest = bundle.manifest;
  if (!_coreFiles.every(files.containsKey) ||
      manifest.length !=
          _manifestKeys.length + (manifest.containsKey('coverage') ? 1 : 0) ||
      !_manifestKeys.every(manifest.containsKey) ||
      manifest['formatVersion'] is! int ||
      manifest['ownerAccountId'] != bundle.ownerAccountId ||
      bundle.sha256sums != files['SHA256SUMS'] ||
      !_sameJson(manifest, _readObject(files['manifest.json']!))) {
    _invalid();
  }

  final generated = manifest['generatedAt'];
  final when = generated is String ? DateTime.tryParse(generated) : null;
  if (when == null || !when.isUtc || when.toIso8601String() != generated) {
    _invalid();
  }

  final rawCounts = manifest['counts'];
  if (rawCounts is! Map || rawCounts.length != _countKeys.length) _invalid();
  final counts = <String, int>{};
  for (final key in _countKeys) {
    final count = rawCounts[key];
    if (count is! int || count < 0) _invalid();
    counts[key] = count;
  }
  final excluded = manifest['excluded'];
  if (excluded is! Map ||
      excluded.length != 2 ||
      excluded['t2Memories'] is! int ||
      (excluded['t2Memories'] as int) < 0 ||
      excluded['byokSecrets'] != 'stripped' ||
      counts['persona']! > 1) {
    _invalid();
  }
  final chatOnly = manifest.containsKey('coverage');
  if (chatOnly) {
    final coverage = manifest['coverage'];
    if (coverage is! Map ||
        coverage.length != 3 ||
        coverage['scope'] != 'chatHistory' ||
        coverage['completeAccountExport'] != false) {
      _invalid();
    }
    final pending = coverage['pendingDomains'];
    if (pending is! List ||
        pending.length != _pendingDomains.length ||
        !_pendingDomains.every(pending.contains)) {
      _invalid();
    }
  }

  var conversations = 0;
  for (final path in files.keys) {
    if (_coreFiles.contains(path)) continue;
    const prefix = 'conversations/', suffix = '.jsonl';
    if (!path.startsWith(prefix) ||
        !path.endsWith(suffix) ||
        path.length <= prefix.length + suffix.length) {
      _invalid();
    }
    ConversationId.parse(
      path.substring(prefix.length, path.length - suffix.length),
    );
    conversations++;
  }
  if (counts['conversations'] != conversations) _invalid();
  _verifySums(files, bundle.sha256sums);
  if (bundle.ownerAccountId != expectedOwner) {
    throw const BackupFilePreviewException(BackupFilePreviewProblem.wrongOwner);
  }
  return BackupFilePreviewSummary._(
    bytes: bytes.length,
    fileCount: files.length,
    generatedAt: when,
    chatHistoryOnly: chatOnly,
    counts: counts,
  );
}

void _verifySums(Map<String, String> files, String sums) {
  final remaining = files.keys.toSet()..remove('SHA256SUMS');
  var start = 0;
  while (true) {
    final end = sums.indexOf('\n', start);
    final row = sums.substring(start, end < 0 ? sums.length : end);
    if (row.length <= 66 || row.substring(64, 66) != '  ') _invalid();
    final path = row.substring(66);
    if (!remaining.remove(path) ||
        _digest(files[path]!) != row.substring(0, 64)) {
      _invalid();
    }
    if (end < 0) break;
    start = end + 1;
  }
  if (remaining.isNotEmpty) _invalid();
}

String _digest(String text) {
  // Escaped lone surrogates can survive jsonDecode. Utf8Encoder replaces them,
  // so reject lossy encoding instead of hashing a different string.
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0xd800 || unit > 0xdfff) continue;
    if (unit >= 0xdc00 || ++i == text.length) _invalid();
    final next = text.codeUnitAt(i);
    if (next < 0xdc00 || next > 0xdfff) _invalid();
  }
  return sha256.convert(utf8.encode(text)).toString();
}

bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _sameJson(a[key], b[key]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return (a is int) == (b is int) && a == b;
}

Map<String, Object?> _readObject(String text) {
  // jsonDecode accepts repeated object names (last value wins). Check names
  // before decoding, while leaving all JSON syntax validation to jsonDecode.
  final scopes = <Set<String>?>[];
  var i = 0;
  while (i < text.length) {
    final start = i;
    switch (text.codeUnitAt(i++)) {
      case 0x7b: // {
        scopes.add(<String>{});
      case 0x5b: // [
        scopes.add(null);
      case 0x7d || 0x5d: // } or ]
        if (scopes.isEmpty) _invalid();
        scopes.removeLast();
      case 0x22: // string
        var closed = false;
        while (i < text.length) {
          final char = text.codeUnitAt(i++);
          if (char == 0x5c) {
            i++; // Escaped character is not a terminating quote.
          } else if (char == 0x22) {
            closed = true;
            break;
          }
        }
        if (!closed) _invalid();
        final names = scopes.isEmpty ? null : scopes.last;
        if (names == null) continue;
        var next = i;
        while (next < text.length && _jsonSpace(text.codeUnitAt(next))) {
          next++;
        }
        if (next < text.length &&
            text.codeUnitAt(next) == 0x3a &&
            !names.add(jsonDecode(text.substring(start, i)) as String)) {
          _invalid();
        }
    }
    // The known envelope/manifest is flat. This also bounds comparisons of
    // unknown malformed metadata and avoids deeply nested decoder input.
    if (scopes.length > 16) _invalid();
  }
  if (scopes.isNotEmpty) _invalid();
  final result = jsonDecode(text);
  if (result is! Map<String, Object?>) _invalid();
  return result;
}

bool _jsonSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;
Never _invalid() => throw const FormatException('Invalid local v1 backup');
