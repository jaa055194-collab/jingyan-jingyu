import 'dart:async';
import 'dart:io';

import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// Current-account quota/disk metadata from the merged host lifecycle route.
///
/// Bytes are raw counts, not a permission or an upload admission decision.
class LifecycleQuotaStatus {
  const LifecycleQuotaStatus._({
    required this.usedBytes,
    required this.quotaBytes,
    required this.diskFreeBytes,
    required this.diskTotalBytes,
  });

  final int usedBytes;
  final int quotaBytes;
  final int diskFreeBytes;
  final int diskTotalBytes;

  factory LifecycleQuotaStatus.fromJson(Map<String, Object?> json) {
    const keys = {'usedBytes', 'quotaBytes', 'diskFreeBytes', 'diskTotalBytes'};
    final used = json['usedBytes'];
    final quota = json['quotaBytes'];
    final free = json['diskFreeBytes'];
    final total = json['diskTotalBytes'];
    if (json.length != keys.length ||
        json.keys.any((key) => !keys.contains(key)) ||
        used is! int ||
        used < 0 ||
        quota is! int ||
        quota <= 0 ||
        free is! int ||
        free < 0 ||
        total is! int ||
        total <= 0 ||
        free > total) {
      throw const FormatException('Lifecycle quota response invalid');
    }
    return LifecycleQuotaStatus._(
      usedBytes: used,
      quotaBytes: quota,
      diskFreeBytes: free,
      diskTotalBytes: total,
    );
  }
}

/// Read-only retention cleanup preview from the host (M12 task-72 route).
///
/// Counts media the caller still holds that retention policy will remind about
/// or delete. This is **not** an execution and never deletes anything.
class LifecycleCleanupPreview {
  const LifecycleCleanupPreview._({
    required this.dayKey,
    required this.remindSoon,
    required this.expiring,
    required this.totalHeld,
  });

  final String dayKey;
  final Map<String, int> remindSoon;
  final Map<String, int> expiring;
  final Map<String, int> totalHeld;

  static const Set<String> _kinds = {'video', 'voice'};

  static Map<String, int> _counts(Object? value) {
    if (value is! Map ||
        value.keys.any((key) => key is! String || !_kinds.contains(key))) {
      throw const FormatException();
    }
    final result = <String, int>{};
    for (final kind in _kinds) {
      final count = value[kind];
      if (count is! int || count < 0) throw const FormatException();
      result[kind] = count;
    }
    return result;
  }

  factory LifecycleCleanupPreview.fromJson(Map<String, Object?> json) {
    const keys = {'dayKey', 'remindSoon', 'expiring', 'totalHeld'};
    final dayKey = json['dayKey'];
    try {
      if (json.length != keys.length ||
          json.keys.any((key) => !keys.contains(key)) ||
          dayKey is! String ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dayKey)) {
        throw const FormatException();
      }
      return LifecycleCleanupPreview._(
        dayKey: dayKey,
        remindSoon: _counts(json['remindSoon']),
        expiring: _counts(json['expiring']),
        totalHeld: _counts(json['totalHeld']),
      );
    } on FormatException {
      throw const FormatException('Lifecycle cleanup preview invalid');
    }
  }
}

/// Read-only current-account departure object counts. Not a deletion receipt.
class LifecycleDepartureSurvey {
  LifecycleDepartureSurvey._({
    required Map<String, int> objectCounts,
    required this.momentsToAnonymize,
    required this.totalObjects,
  }) : objectCounts = Map.unmodifiable(objectCounts);

  final Map<String, int> objectCounts;
  final int momentsToAnonymize;
  final int totalObjects;

  factory LifecycleDepartureSurvey.fromJson(Map<String, Object?> json) {
    const keys = {'objectCounts', 'momentsToAnonymize', 'totalObjects'};
    final rawCounts = json['objectCounts'];
    final moments = json['momentsToAnonymize'];
    final total = json['totalObjects'];
    if (json.length != keys.length ||
        json.keys.any((key) => !keys.contains(key)) ||
        rawCounts is! Map ||
        moments is! int ||
        moments < 0 ||
        total is! int ||
        total < 0) {
      throw const FormatException(
        'Lifecycle departure survey response invalid',
      );
    }
    final counts = <String, int>{};
    var sum = 0;
    for (final entry in rawCounts.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! int || value < 0) {
        throw const FormatException(
          'Lifecycle departure survey response invalid',
        );
      }
      counts[key] = value;
      sum += value;
    }
    if (sum != total) {
      throw const FormatException(
        'Lifecycle departure survey response invalid',
      );
    }
    return LifecycleDepartureSurvey._(
      objectCounts: counts,
      momentsToAnonymize: moments,
      totalObjects: total,
    );
  }
}

/// Typed export package metadata for the merged host lifecycle export route.
///
/// Only summary metadata is exposed by this class; file contents stay in the
/// bundle for explicit import and are never rendered by the UI.
class LifecycleExportBundle {
  LifecycleExportBundle._({
    required this.ownerAccountId,
    required Map<String, String> files,
    required Map<String, Object?> manifest,
    required this.sha256sums,
  }) : files = Map.unmodifiable(files),
       manifest = Map.unmodifiable(manifest);

  final String ownerAccountId;
  final Map<String, String> files;
  final Map<String, Object?> manifest;
  final String sha256sums;

  /// Maximum serialized envelope accepted by the local save bridge.
  static const int maxFileBytes = 4 * 1024 * 1024;

  int get fileCount => files.length;

  /// The exact version-1 package envelope, for an explicit local save only.
  /// Callers must not render the returned content.
  String exportFileContents() {
    final content = jsonEncode({
      'ownerAccountId': ownerAccountId,
      'files': files,
      'manifest': manifest,
      'sha256sums': sha256sums,
    });
    if (utf8.encode(content).length > maxFileBytes) {
      throw const FormatException('导出文件超出本地保存上限');
    }
    // Refuse to hand out a package this client could not read back.
    LifecycleExportBundle.fromJson(
      (jsonDecode(content) as Map).cast<String, Object?>(),
    );
    return content;
  }

  bool get hasChecksums => sha256sums.isNotEmpty;
  Map<String, Object?> get counts {
    final value = manifest['counts'];
    return value is Map ? value.cast<String, Object?>() : const {};
  }

  factory LifecycleExportBundle.fromJson(Map<String, Object?> json) {
    const keys = {'ownerAccountId', 'files', 'manifest', 'sha256sums'};
    final owner = json['ownerAccountId'];
    final rawFiles = json['files'];
    final rawManifest = json['manifest'];
    final sums = json['sha256sums'];
    if (json.length != keys.length ||
        json.keys.any((key) => !keys.contains(key)) ||
        owner is! String ||
        owner.isEmpty ||
        rawFiles is! Map ||
        rawManifest is! Map ||
        sums is! String ||
        sums.isEmpty ||
        rawManifest['formatVersion'] != 1 ||
        rawManifest['counts'] is! Map) {
      throw const FormatException('Lifecycle export response invalid');
    }
    final files = <String, String>{};
    for (final entry in rawFiles.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! String) {
        throw const FormatException('Lifecycle export response invalid');
      }
      files[key] = value;
    }
    return LifecycleExportBundle._(
      ownerAccountId: owner,
      files: files,
      manifest: rawManifest.cast<String, Object?>(),
      sha256sums: sums,
    );
  }
}

enum LifecycleImportMode { personaOnly, personaAndConversations }

class LifecycleImportConflict {
  const LifecycleImportConflict({
    required this.kind,
    required this.oldId,
    required this.newId,
  });
  final String kind;
  final String oldId;
  final String newId;
}

/// Typed import result from the merged host lifecycle import route.
class LifecycleImportReport {
  LifecycleImportReport._({
    required this.mode,
    required this.checksumVerified,
    required this.imported,
    required List<LifecycleImportConflict> conflicts,
  }) : conflicts = List.unmodifiable(conflicts);

  final LifecycleImportMode mode;
  final bool checksumVerified;
  final Map<String, int> imported;
  final List<LifecycleImportConflict> conflicts;

  int get importedPersona => imported['persona'] ?? 0;
  int get importedConversations => imported['conversations'] ?? 0;
  int get importedMessages => imported['messages'] ?? 0;
  int get importedMemories => imported['memories'] ?? 0;
  int get importedAttachments => imported['attachments'] ?? 0;

  factory LifecycleImportReport.fromJson(Map<String, Object?> json) {
    const keys = {'mode', 'checksumVerified', 'imported', 'conflicts'};
    final rawMode = json['mode'];
    final verified = json['checksumVerified'];
    final rawImported = json['imported'];
    final rawConflicts = json['conflicts'];
    final mode = switch (rawMode) {
      'personaOnly' => LifecycleImportMode.personaOnly,
      'personaAndConversations' => LifecycleImportMode.personaAndConversations,
      _ => null,
    };
    if (json.length != keys.length ||
        json.keys.any((key) => !keys.contains(key)) ||
        mode == null ||
        verified is! bool ||
        rawImported is! Map ||
        rawConflicts is! List) {
      throw const FormatException('Lifecycle import response invalid');
    }
    const importedKeys = {
      'persona',
      'conversations',
      'messages',
      'memories',
      'attachments',
    };
    final imported = <String, int>{};
    for (final entry in rawImported.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String ||
          !importedKeys.contains(key) ||
          value is! int ||
          value < 0) {
        throw const FormatException('Lifecycle import response invalid');
      }
      imported[key] = value;
    }
    if (imported.length != importedKeys.length) {
      throw const FormatException('Lifecycle import response invalid');
    }
    final conflicts = <LifecycleImportConflict>[];
    for (final raw in rawConflicts) {
      if (raw is! Map) {
        throw const FormatException('Lifecycle import response invalid');
      }
      final entry = raw.cast<String, Object?>();
      final kind = entry['kind'];
      final oldId = entry['oldId'];
      final newId = entry['newId'];
      if (entry.length != 3 ||
          kind is! String ||
          oldId is! String ||
          newId is! String) {
        throw const FormatException('Lifecycle import response invalid');
      }
      conflicts.add(
        LifecycleImportConflict(kind: kind, oldId: oldId, newId: newId),
      );
    }
    return LifecycleImportReport._(
      mode: mode,
      checksumVerified: verified,
      imported: imported,
      conflicts: conflicts,
    );
  }
}

/// Typed GET-only adapter for the merged host lifecycle read routes.
///
/// Only [Routes.lifecycleQuota] and [Routes.lifecycleDepartureSurvey] are
/// read-only today; upload/export/import/departure mutations are intentionally
/// not exposed. Existing [HostConnection] bounded 401 renewal is retained. No
/// UI, secret, discovery, other module or write behavior is added.
class LifecycleApi {
  LifecycleApi(this.connection);
  final HostConnection connection;

  Future<LifecycleQuotaStatus> readQuota({bool retryAuthentication = true}) =>
      _read(
        Routes.lifecycleQuota,
        retryAuthentication,
        LifecycleQuotaStatus.fromJson,
      );

  Future<LifecycleDepartureSurvey> readDepartureSurvey({
    bool retryAuthentication = true,
  }) => _read(
    Routes.lifecycleDepartureSurvey,
    retryAuthentication,
    LifecycleDepartureSurvey.fromJson,
  );

  /// Read-only retention cleanup preview (what a cleanup WOULD remove).
  /// Never executes a cleanup and never deletes anything.
  Future<LifecycleCleanupPreview> readCleanupPreview({
    bool retryAuthentication = true,
  }) => _read(
    Routes.lifecycleCleanupPreview,
    retryAuthentication,
    LifecycleCleanupPreview.fromJson,
  );

  /// Explicit export (POST) of the current account bundle. Not a mutation.
  Future<LifecycleExportBundle> exportBundle({
    bool retryAuthentication = true,
  }) => _post(
    Routes.lifecycleExport,
    null,
    retryAuthentication,
    LifecycleExportBundle.fromJson,
  );

  /// Explicit import (POST). Callers must confirm before invoking; uncertain
  /// results are not automatically retried here beyond bounded 401 renewal.
  Future<LifecycleImportReport> importBundle(
    LifecycleExportBundle bundle, {
    required LifecycleImportMode mode,
    bool retryAuthentication = true,
  }) => _post(
    Routes.lifecycleImport,
    {'mode': mode.name, 'files': bundle.files},
    retryAuthentication,
    LifecycleImportReport.fromJson,
  );

  Future<T> _post<T>(
    String path,
    Map<String, Object?>? body,
    bool retryAuthentication,
    T Function(Map<String, Object?>) parse,
  ) async {
    try {
      final json = await connection.request(
        'POST',
        path,
        body: body,
        retryAuthentication: retryAuthentication,
      );
      return parse(json);
    } on FormatException {
      throw const FormatException('Lifecycle 响应无效');
    } on SocketException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on HttpException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TlsException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    }
  }

  Future<T> _read<T>(
    String path,
    bool retryAuthentication,
    T Function(Map<String, Object?>) parse,
  ) async {
    try {
      final json = await connection.request(
        'GET',
        path,
        retryAuthentication: retryAuthentication,
      );
      return parse(json);
    } on FormatException {
      // Never echo malformed upstream text or parser source.
      throw const FormatException('Lifecycle 响应无效');
    } on SocketException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on HttpException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TlsException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    }
  }
}
