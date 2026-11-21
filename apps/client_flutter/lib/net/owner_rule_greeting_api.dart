import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

enum GreetingProblem { refused, unavailable, conflict, unknown }

sealed class GreetingResult {
  const GreetingResult();
}

final class GreetingUnavailable extends GreetingResult {
  const GreetingUnavailable(this.problem);
  final GreetingProblem problem;
}

final class GreetingSettingsLoaded extends GreetingResult {
  const GreetingSettingsLoaded(this.state);
  final OwnerRuleGreetingSettings state;
}

final class GreetingSettingsWritten extends GreetingResult {
  const GreetingSettingsWritten(this.state);
  final OwnerRuleGreetingSettings state;
}

final class GlobalGreetingStopLoaded extends GreetingResult {
  const GlobalGreetingStopLoaded(this.state);
  final GlobalGreetingStop state;
}

final class GlobalGreetingStopWritten extends GreetingResult {
  const GlobalGreetingStopWritten(this.state);
  final GlobalGreetingStop state;
}

final class OwnerRuleGreetingSettings {
  const OwnerRuleGreetingSettings({
    required this.aiProfileId,
    required this.revision,
    required this.enabled,
    required this.localMinute,
    required this.offsetMinutes,
    required this.quietStartMinute,
    required this.quietEndMinute,
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

  factory OwnerRuleGreetingSettings.fromJson(
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
      return OwnerRuleGreetingSettings(
        aiProfileId: aiId,
        revision: revision,
        enabled: enabled,
        localMinute: local as int,
        offsetMinutes: offset as int?,
        quietStartMinute: quietStart as int,
        quietEndMinute: quietEnd as int,
        globalBlocked: blocked,
        globalRevision: globalRevision,
        socialLevel: socialLevel as String?,
        chatRevision: chatRevision as int?,
        budgetReady: budgetReady,
        lastSentAt: lastSentAt,
      );
    } on FormatException {
      throw const FormatException('Greeting settings response invalid');
    }
  }

  static bool _minute(Object? value) =>
      value is int && value >= 0 && value < 1440;
  static bool _offset(Object? value) =>
      value is int && value >= -840 && value <= 840;
}

final class GlobalGreetingStop {
  const GlobalGreetingStop({required this.revision, required this.blocked});

  final int revision;
  final bool blocked;

  factory GlobalGreetingStop.fromJson(Map<String, Object?> json) {
    final revision = json['revision'];
    final blocked = json['blocked'];
    if (json.length != 2 ||
        revision is! int ||
        revision < 0 ||
        blocked is! bool) {
      throw const FormatException('Greeting stop response invalid');
    }
    return GlobalGreetingStop(revision: revision, blocked: blocked);
  }
}

class OwnerRuleGreetingApi {
  const OwnerRuleGreetingApi(this.connection);

  final HostConnection connection;

  String _settingsPath(String aiId) => Routes.aiOwnerRuleGreeting.replaceFirst(
    '{aiId}',
    Uri.encodeComponent(AiId.parse(aiId).value),
  );

  Future<GreetingResult> readSettings(String aiId) async {
    final String path;
    try {
      path = _settingsPath(aiId);
    } on FormatException {
      return const GreetingUnavailable(GreetingProblem.refused);
    }
    try {
      final data = await connection.request(
        'GET',
        path,
        retryAuthentication: false,
      );
      return GreetingSettingsLoaded(
        OwnerRuleGreetingSettings.fromJson(aiId, data),
      );
    } on HostRequestException catch (error) {
      return GreetingUnavailable(_problem(error, writing: false));
    } on FormatException {
      return const GreetingUnavailable(GreetingProblem.unavailable);
    } on IOException {
      return const GreetingUnavailable(GreetingProblem.unavailable);
    } on TimeoutException {
      return const GreetingUnavailable(GreetingProblem.unavailable);
    } on StateError {
      return const GreetingUnavailable(GreetingProblem.unavailable);
    }
  }

  Future<GreetingResult> writeSettings(
    String aiId, {
    required OwnerRuleGreetingSettings current,
    required bool enabled,
    required int localMinute,
    required int? offsetMinutes,
    required int quietStartMinute,
    required int quietEndMinute,
  }) async {
    if (current.aiProfileId != aiId ||
        localMinute < 0 ||
        localMinute > 1439 ||
        quietStartMinute < 0 ||
        quietStartMinute > 1439 ||
        quietEndMinute < 0 ||
        quietEndMinute > 1439 ||
        quietStartMinute == quietEndMinute ||
        (offsetMinutes != null && !_offset(offsetMinutes)) ||
        (enabled &&
            (!current.prerequisitesReady ||
                !current.budgetReady ||
                offsetMinutes == null))) {
      return const GreetingUnavailable(GreetingProblem.refused);
    }
    final String path;
    try {
      path = _settingsPath(aiId);
    } on FormatException {
      return const GreetingUnavailable(GreetingProblem.refused);
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
          'expectedChatRevision': enabled ? current.chatRevision : null,
          'expectedGlobalRevision': enabled ? current.globalRevision : null,
        },
        retryAuthentication: false,
      );
      final next = OwnerRuleGreetingSettings.fromJson(aiId, data);
      if (next.revision != current.revision + 1 ||
          next.enabled != enabled ||
          next.localMinute != localMinute ||
          next.offsetMinutes != offsetMinutes ||
          next.quietStartMinute != quietStartMinute ||
          next.quietEndMinute != quietEndMinute ||
          (enabled &&
              (next.globalRevision != current.globalRevision ||
                  next.chatRevision != current.chatRevision))) {
        return const GreetingUnavailable(GreetingProblem.unknown);
      }
      return GreetingSettingsWritten(next);
    } on HostRequestException catch (error) {
      return GreetingUnavailable(_problem(error, writing: true));
    } on FormatException {
      return const GreetingUnavailable(GreetingProblem.unknown);
    } on IOException {
      return const GreetingUnavailable(GreetingProblem.unknown);
    } on TimeoutException {
      return const GreetingUnavailable(GreetingProblem.unknown);
    } on StateError {
      return const GreetingUnavailable(GreetingProblem.unknown);
    }
  }

  Future<GreetingResult> readGlobalStop() async {
    try {
      final data = await connection.request(
        'GET',
        Routes.ownerRuleGreetingStop,
        retryAuthentication: false,
      );
      return GlobalGreetingStopLoaded(GlobalGreetingStop.fromJson(data));
    } on HostRequestException catch (error) {
      return GreetingUnavailable(_problem(error, writing: false));
    } on FormatException {
      return const GreetingUnavailable(GreetingProblem.unavailable);
    } on IOException {
      return const GreetingUnavailable(GreetingProblem.unavailable);
    } on TimeoutException {
      return const GreetingUnavailable(GreetingProblem.unavailable);
    } on StateError {
      return const GreetingUnavailable(GreetingProblem.unavailable);
    }
  }

  Future<GreetingResult> writeGlobalStop({
    required GlobalGreetingStop current,
    required bool blocked,
  }) async {
    try {
      final data = await connection.request(
        'PUT',
        Routes.ownerRuleGreetingStop,
        body: {'expectedRevision': current.revision, 'blocked': blocked},
        retryAuthentication: false,
      );
      final next = GlobalGreetingStop.fromJson(data);
      if (next.revision != current.revision + 1 || next.blocked != blocked) {
        return const GreetingUnavailable(GreetingProblem.unknown);
      }
      return GlobalGreetingStopWritten(next);
    } on HostRequestException catch (error) {
      return GreetingUnavailable(_problem(error, writing: true));
    } on FormatException {
      return const GreetingUnavailable(GreetingProblem.unknown);
    } on IOException {
      return const GreetingUnavailable(GreetingProblem.unknown);
    } on TimeoutException {
      return const GreetingUnavailable(GreetingProblem.unknown);
    } on StateError {
      return const GreetingUnavailable(GreetingProblem.unknown);
    }
  }

  static bool _offset(int value) => value >= -840 && value <= 840;

  static GreetingProblem _problem(
    HostRequestException error, {
    required bool writing,
  }) => switch (error.failure.code) {
    FailureCode.invalidArgument ||
    FailureCode.unauthenticated ||
    FailureCode.forbidden ||
    FailureCode.notFound => GreetingProblem.refused,
    FailureCode.conflict => GreetingProblem.conflict,
    _ => writing ? GreetingProblem.unknown : GreetingProblem.unavailable,
  };
}
