import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

enum OwnerSocialLevel {
  l0('L0'),
  l1('L1'),
  l2('L2'),
  l3('L3'),
  l4('L4');

  const OwnerSocialLevel(this.wire);
  final String wire;
}

enum OwnerSocialLevelProblem {
  authenticationRequired,
  refused,
  unavailable,
  unknown,
}

sealed class OwnerSocialLevelResult {
  const OwnerSocialLevelResult();
}

/// An exact host view. Unconfigured is a successful view, not a failed read.
final class OwnerSocialLevelSnapshot extends OwnerSocialLevelResult {
  const OwnerSocialLevelSnapshot._(this.level, this.updatedAt);

  final OwnerSocialLevel? level;
  final DateTime? updatedAt;
  bool get configurationRequired => level == null;

  static OwnerSocialLevelSnapshot? _parse(Map<String, Object?> data) {
    const fields = {'configurationRequired', 'level', 'updatedAt'};
    if (data.length != fields.length || !fields.every(data.containsKey)) {
      return null;
    }
    final required = data['configurationRequired'];
    final level = data['level'];
    final at = data['updatedAt'];
    if (required == true && level == null && at == null) {
      return const OwnerSocialLevelSnapshot._(null, null);
    }
    if (required != false || level is! String || at is! String) return null;
    final configured = OwnerSocialLevel.values
        .where((value) => value.wire == level)
        .firstOrNull;
    final time = DateTime.tryParse(at);
    // DateTime.tryParse normalizes overflow and offsets. Require the exact
    // canonical UTC form emitted by SocialLevelView.toJson, including precision.
    if (configured == null ||
        time == null ||
        !time.isUtc ||
        time.toIso8601String() != at) {
      return null;
    }
    return OwnerSocialLevelSnapshot._(configured, time);
  }
}

final class OwnerSocialLevelFailure extends OwnerSocialLevelResult {
  const OwnerSocialLevelFailure(this.problem);

  final OwnerSocialLevelProblem problem;
}

/// Consumes the existing owner route via the authenticated host connection.
/// This adapter never grants proactive consent or replays credentials/writes.
class OwnerSocialLevelApi {
  const OwnerSocialLevelApi(this._connection);

  final HostConnection _connection;

  Future<OwnerSocialLevelResult> read(String profileId) => _request(profileId);

  Future<OwnerSocialLevelResult> write(
    String profileId,
    OwnerSocialLevel level,
  ) => _request(profileId, level: level);

  Future<OwnerSocialLevelResult> _request(
    String profileId, {
    OwnerSocialLevel? level,
  }) async {
    final String path;
    try {
      path = Routes.aiSocialLevel.replaceFirst(
        '{aiId}',
        Uri.encodeComponent(AiId.parse(profileId).value),
      );
    } on FormatException {
      return const OwnerSocialLevelFailure(OwnerSocialLevelProblem.refused);
    }
    final writing = level != null;
    final unconfirmed = OwnerSocialLevelFailure(
      writing
          ? OwnerSocialLevelProblem.unknown
          : OwnerSocialLevelProblem.unavailable,
    );
    try {
      // The shared host client supplies TLS/no redirects, a timeout and byte
      // limit, exact status, and no authentication renewal or replay.
      final data = await _connection.requestBoundedObject(
        writing ? 'PUT' : 'GET',
        path,
        body: level == null ? null : {'level': level.wire},
        maxResponseBytes: 1024,
        expectedStatus: 200,
      );
      final observed = OwnerSocialLevelSnapshot._parse(data);
      if (observed == null || (writing && observed.level != level)) {
        return unconfirmed;
      }
      return observed;
    } on HostRequestException catch (error) {
      return switch (error.failure.code) {
        FailureCode.unauthenticated => const OwnerSocialLevelFailure(
          OwnerSocialLevelProblem.authenticationRequired,
        ),
        FailureCode.invalidArgument ||
        FailureCode.forbidden ||
        FailureCode.notFound => const OwnerSocialLevelFailure(
          OwnerSocialLevelProblem.refused,
        ),
        // A server error (including audit failure) can follow a committed PUT.
        _ => unconfirmed,
      };
    } on FormatException {
      return unconfirmed;
    } on IOException {
      return unconfirmed;
    } on TimeoutException {
      return unconfirmed;
    } on StateError {
      return unconfirmed;
    }
  }
}
