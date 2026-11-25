import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

enum ProactiveProblem { refused, unavailable, conflict, unknown }

sealed class ProactiveResult {
  const ProactiveResult();
}

final class ProactiveUnavailable extends ProactiveResult {
  const ProactiveUnavailable(this.problem);
  final ProactiveProblem problem;
}

final class ProactiveSettingsLoaded extends ProactiveResult {
  const ProactiveSettingsLoaded(this.state);
  final OwnerModelProactiveSettings state;
}

final class ProactiveSettingsWritten extends ProactiveResult {
  const ProactiveSettingsWritten(this.state);
  final OwnerModelProactiveSettings state;
}

final class GlobalProactiveStopLoaded extends ProactiveResult {
  const GlobalProactiveStopLoaded(this.state);
  final GlobalProactiveStop state;
}

final class GlobalProactiveStopWritten extends ProactiveResult {
  const GlobalProactiveStopWritten(this.state);
  final GlobalProactiveStop state;
}

final class OwnerModelProactiveSettings {
  const OwnerModelProactiveSettings({
    required this.aiProfileId,
    required this.revision,
    required this.enabled,
    required this.localMinute,
    required this.offsetMinutes,
    required this.quietStartMinute,
    required this.quietEndMinute,
    required this.intervalMinutes,
    required this.globalBlocked,
    required this.globalRevision,
    required this.socialLevel,
    required this.chatRevision,
    required this.budgetReady,
    required this.lastSentAt,
  });

  final String aiProfileId;
  final int revision;
  final bool enabled;
  final int localMinute;
  final int? offsetMinutes;
  final int quietStartMinute;
  final int quietEndMinute;
  final int intervalMinutes;
  final bool globalBlocked;
  final int globalRevision;
  final String? socialLevel;
  final int? chatRevision;
  final bool budgetReady;
  final DateTime? lastSentAt;

  bool get prerequisitesReady =>
      !globalBlocked &&
      const {'L3', 'L4'}.contains(socialLevel) &&
      chatRevision != null;

  factory OwnerModelProactiveSettings.fromJson(
    String aiId,
    Map<String, Object?> json,
  ) {
    try {
      AiId.parse(aiId);
      const fields = {
        'revision',
        'enabled',
        'localMinute',
        'offsetMinutes',
        'quietStartMinute',
        'quietEndMinute',
        'intervalMinutes',
        'globalBlocked',
        'globalRevision',
        'socialLevel',
        'chatRevision',
        'budgetReady',
        'lastSentAt',
      };
      final revision = json['revision'];
      final enabled = json['enabled'];
      final local = json['localMinute'];
      final offset = json['offsetMinutes'];
      final quietStart = json['quietStartMinute'];
      final quietEnd = json['quietEndMinute'];
      final interval = json['intervalMinutes'];
      final blocked = json['globalBlocked'];
      final globalRevision = json['globalRevision'];
      final socialLevel = json['socialLevel'];
      final chatRevision = json['chatRevision'];
      final budgetReady = json['budgetReady'];
      final lastSentRaw = json['lastSentAt'];
      if (json.length != fields.length ||
          !fields.every(json.containsKey) ||
          revision is! int ||
          revision < 0 ||
          enabled is! bool ||
          !_minute(local) ||
          (offset != null && !_offset(offset)) ||
          !_minute(quietStart) ||
          !_minute(quietEnd) ||
          quietStart == quietEnd ||
          !_interval(interval) ||
          blocked is! bool ||
          globalRevision is! int ||
          globalRevision < 0 ||
          (socialLevel != null &&
              (socialLevel is! String ||
                  !const {
                    'L0',
                    'L1',
                    'L2',
                    'L3',
                    'L4',
                  }.contains(socialLevel))) ||
          (chatRevision != null &&
              (chatRevision is! int || chatRevision < 1)) ||
          budgetReady is! bool ||
          (lastSentRaw != null && lastSentRaw is! String)) {
        throw const FormatException();
      }
      DateTime? lastSentAt;
      if (lastSentRaw != null) {
        final raw = lastSentRaw as String;
        lastSentAt = DateTime.tryParse(raw);
        if (lastSentAt == null ||
            !lastSentAt.isUtc ||
            lastSentAt.toIso8601String() != raw) {
          throw const FormatException();
        }
      }
      if (enabled &&
          (offset == null ||
              blocked ||
              !const {'L3', 'L4'}.contains(socialLevel) ||
              chatRevision == null)) {
        throw const FormatException();
      }
      return OwnerModelProactiveSettings(
        aiProfileId: aiId,
        revision: revision,
        enabled: enabled,
        localMinute: local as int,
        offsetMinutes: offset as int?,
        quietStartMinute: quietStart as int,
        quietEndMinute: quietEnd as int,
        intervalMinutes: interval as int,
        globalBlocked: blocked,
        globalRevision: globalRevision,
        socialLevel: socialLevel as String?,
        chatRevision: chatRevision as int?,
        budgetReady: budgetReady,
        lastSentAt: lastSentAt,
      );
    } on FormatException {
      throw const FormatException('Proactive settings response invalid');
    }
  }

  static bool _minute(Object? value) =>
      value is int && value >= 0 && value < 1440;
  static bool _offset(Object? value) =>
      value is int && value >= -840 && value <= 840;
  static bool _interval(Object? value) =>
      value is int && value >= 60 && value <= 10080;
}

final class GlobalProactiveStop {
  const GlobalProactiveStop({required this.revision, required this.blocked});

  final int revision;
  final bool blocked;

  factory GlobalProactiveStop.fromJson(Map<String, Object?> json) {
    final revision = json['revision'];
    final blocked = json['blocked'];
    if (json.length != 2 ||
        revision is! int ||
        revision < 0 ||
        blocked is! bool) {
      throw const FormatException('Proactive stop response invalid');
    }
    return GlobalProactiveStop(revision: revision, blocked: blocked);
  }
}

class OwnerModelProactiveApi {
  const OwnerModelProactiveApi(this.connection);

  final HostConnection connection;

  String _settingsPath(String aiId) => Routes.aiOwnerModelProactive.replaceFirst(
    '{aiId}',
    Uri.encodeComponent(AiId.parse(aiId).value),
  );

  Future<ProactiveResult> readSettings(String aiId) async {
    final String path;
    try {
      path = _settingsPath(aiId);
    } on FormatException {
      return const ProactiveUnavailable(ProactiveProblem.refused);
    }
    try {
      final data = await connection.request(
        'GET',
        path,
        retryAuthentication: false,
      );
      return ProactiveSettingsLoaded(
        OwnerModelProactiveSettings.fromJson(aiId, data),
      );
    } on HostRequestException catch (error) {
      return ProactiveUnavailable(_problem(error, writing: false));
    } on FormatException {
      return const ProactiveUnavailable(ProactiveProblem.unavailable);
    } on IOException {
      return const ProactiveUnavailable(ProactiveProblem.unavailable);
    } on TimeoutException {
      return const ProactiveUnavailable(ProactiveProblem.unavailable);
    } on StateError {
      return const ProactiveUnavailable(ProactiveProblem.unavailable);
    }
  }

  Future<ProactiveResult> writeSettings(
    String aiId, {
    required OwnerModelProactiveSettings current,
    required bool enabled,
    required int localMinute,
    required int? offsetMinutes,
    required int quietStartMinute,
    required int quietEndMinute,
    required int intervalMinutes,
  }) async {
    if (current.aiProfileId != aiId ||
        localMinute < 0 ||
        localMinute > 1439 ||
        quietStartMinute < 0 ||
        quietStartMinute > 1439 ||
        quietEndMinute < 0 ||
        quietEndMinute > 1439 ||
        quietStartMinute == quietEndMinute ||
        intervalMinutes < 60 ||
        intervalMinutes > 10080 ||
        (offsetMinutes != null && !_offset(offsetMinutes)) ||
        (enabled &&
            (!current.prerequisitesReady ||
                !current.budgetReady ||
                offsetMinutes == null))) {
      return const ProactiveUnavailable(ProactiveProblem.refused);
    }
    final String path;
    try {
      path = _settingsPath(aiId);
    } on FormatException {
      return const ProactiveUnavailable(ProactiveProblem.refused);
    }
    try {
      final data = await connection.request(
        'PUT',
        path,
        body: {
          'expectedRevision': current.revision,
          'enabled': enabled,
          'localMinute': localMinute,
          'offsetMinutes': offsetMinutes,
          'quietStartMinute': quietStartMinute,
          'quietEndMinute': quietEndMinute,
          'intervalMinutes': intervalMinutes,
          'expectedChatRevision': enabled ? current.chatRevision : null,
          'expectedGlobalRevision': enabled ? current.globalRevision : null,
        },
        retryAuthentication: false,
      );
      final next = OwnerModelProactiveSettings.fromJson(aiId, data);
      if (next.revision != current.revision + 1 ||
          next.enabled != enabled ||
          next.localMinute != localMinute ||
          next.offsetMinutes != offsetMinutes ||
          next.quietStartMinute != quietStartMinute ||
          next.quietEndMinute != quietEndMinute ||
          next.intervalMinutes != intervalMinutes ||
          (enabled &&
              (next.globalRevision != current.globalRevision ||
                  next.chatRevision != current.chatRevision))) {
        return const ProactiveUnavailable(ProactiveProblem.unknown);
      }
      return ProactiveSettingsWritten(next);
    } on HostRequestException catch (error) {
      return ProactiveUnavailable(_problem(error, writing: true));
    } on FormatException {
      return const ProactiveUnavailable(ProactiveProblem.unknown);
    } on IOException {
      return const ProactiveUnavailable(ProactiveProblem.unknown);
    } on TimeoutException {
      return const ProactiveUnavailable(ProactiveProblem.unknown);
    } on StateError {
      return const ProactiveUnavailable(ProactiveProblem.unknown);
    }
  }

  Future<ProactiveResult> readGlobalStop() async {
    try {
      final data = await connection.request(
        'GET',
        Routes.ownerModelProactiveStop,
        retryAuthentication: false,
      );
      return GlobalProactiveStopLoaded(GlobalProactiveStop.fromJson(data));
    } on HostRequestException catch (error) {
      return ProactiveUnavailable(_problem(error, writing: false));
    } on FormatException {
      return const ProactiveUnavailable(ProactiveProblem.unavailable);
    } on IOException {
      return const ProactiveUnavailable(ProactiveProblem.unavailable);
    } on TimeoutException {
      return const ProactiveUnavailable(ProactiveProblem.unavailable);
    } on StateError {
      return const ProactiveUnavailable(ProactiveProblem.unavailable);
    }
  }

  Future<ProactiveResult> writeGlobalStop({
    required GlobalProactiveStop current,
    required bool blocked,
  }) async {
    try {
      final data = await connection.request(
        'PUT',
        Routes.ownerModelProactiveStop,
        body: {'expectedRevision': current.revision, 'blocked': blocked},
        retryAuthentication: false,
      );
      final next = GlobalProactiveStop.fromJson(data);
      if (next.revision != current.revision + 1 || next.blocked != blocked) {
        return const ProactiveUnavailable(ProactiveProblem.unknown);
      }
      return GlobalProactiveStopWritten(next);
    } on HostRequestException catch (error) {
      return ProactiveUnavailable(_problem(error, writing: true));
    } on FormatException {
      return const ProactiveUnavailable(ProactiveProblem.unknown);
    } on IOException {
      return const ProactiveUnavailable(ProactiveProblem.unknown);
    } on TimeoutException {
      return const ProactiveUnavailable(ProactiveProblem.unknown);
    } on StateError {
      return const ProactiveUnavailable(ProactiveProblem.unknown);
    }
  }

  static bool _offset(int value) => value >= -840 && value <= 840;

  static ProactiveProblem _problem(
    HostRequestException error, {
    required bool writing,
  }) => switch (error.failure.code) {
    FailureCode.invalidArgument ||
    FailureCode.unauthenticated ||
    FailureCode.forbidden ||
    FailureCode.notFound => ProactiveProblem.refused,
    FailureCode.conflict => ProactiveProblem.conflict,
    _ => writing ? ProactiveProblem.unknown : ProactiveProblem.unavailable,
  };
}
