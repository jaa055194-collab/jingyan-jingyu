import 'dart:async';
import 'dart:io';

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
