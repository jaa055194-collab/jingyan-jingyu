import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

enum OwnerReplyLength { brief, detailed }

enum OwnerReplyFormat { paragraphs, bullets }

/// One host-provided offer. The opaque token is not part of the display model.
final class OwnerReplyTarget {
  const OwnerReplyTarget._(
    this.providerId,
    this.model,
    this.origin,
    this._token,
  );

  final String providerId;
  final String model;
  final String origin;
  final String _token;

  static final _hidden = RegExp(
    r'[\x00-\x1f\x7f-\x9f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]',
  );
  static final _tokenPattern = RegExp(r'^[a-zA-Z0-9_-]{1,128}$');
  static bool _label(String text, int max) =>
      text.trim().isNotEmpty && text.length <= max && !_hidden.hasMatch(text);

  factory OwnerReplyTarget._decode(Object value) {
    if (value is! Map<String, Object?> || value.length != 4) {
      throw const FormatException();
    }
    final provider = value['providerId'];
    final model = value['model'];
    final origin = value['origin'];
    final token = value['token'];
    if (provider is! String ||
        !_label(provider, 128) ||
        model is! String ||
        !_label(model, 256) ||
        origin is! String ||
        !_label(origin, 512) ||
        token is! String ||
        !_tokenPattern.hasMatch(token)) {
      throw const FormatException();
    }
    final uri = Uri.tryParse(origin);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.authority.contains('@') ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.origin != origin) {
      throw const FormatException();
    }
    return OwnerReplyTarget._(provider, model, origin, token);
  }

  bool _matches(OwnerReplyTarget? other) =>
      other != null &&
      providerId == other.providerId &&
      model == other.model &&
      origin == other.origin &&
      _token == other._token;
}

final class OwnerReplyPreferences {
  const OwnerReplyPreferences._(
    this._profileId,
    this.revision,
    this.enabled,
    this.length,
    this.format,
    this.target,
  );

  final String _profileId;
  final int revision;
  final bool enabled;
  final OwnerReplyLength? length;
  final OwnerReplyFormat? format;
  final OwnerReplyTarget? target;

  factory OwnerReplyPreferences._decode(
    String profile,
    Map<String, Object?> data,
  ) {
    const keys = {'revision', 'enabled', 'length', 'format', 'target'};
    final revision = data['revision'];
    final enabled = data['enabled'];
    if (data.length != keys.length ||
        !keys.every(data.containsKey) ||
        revision is! int ||
        revision < 0 ||
        enabled is! bool) {
      throw const FormatException();
    }
    final length = switch (data['length']) {
      null => null,
      'brief' => OwnerReplyLength.brief,
      'detailed' => OwnerReplyLength.detailed,
      _ => throw const FormatException(),
    };
    final format = switch (data['format']) {
      null => null,
      'paragraphs' => OwnerReplyFormat.paragraphs,
      'bullets' => OwnerReplyFormat.bullets,
      _ => throw const FormatException(),
    };
    final raw = data['target'];
    final target = raw == null ? null : OwnerReplyTarget._decode(raw);
    if (enabled && (target == null || (length == null && format == null))) {
      throw const FormatException();
    }
    return OwnerReplyPreferences._(
      profile,
      revision,
      enabled,
      length,
      format,
      target,
    );
  }
}

enum OwnerReplyPreferenceProblem { refused, unavailable, conflict, unknown }

final class OwnerReplyPreferenceResult {
  const OwnerReplyPreferenceResult._(this.state, this.problem);
  const OwnerReplyPreferenceResult._state(OwnerReplyPreferences state)
    : this._(state, null);
  const OwnerReplyPreferenceResult._failure(OwnerReplyPreferenceProblem problem)
    : this._(null, problem);

  final OwnerReplyPreferences? state;
  final OwnerReplyPreferenceProblem? problem;
}

/// Preference grants are a separate route: nothing here reads or writes the
/// legacy owner private-chat consent. No automatic auth or write replay.
class OwnerReplyPreferencesApi {
  const OwnerReplyPreferencesApi(this.connection);
  final HostConnection connection;

  String _path(String profile) => Routes.aiOwnerReplyPreferences.replaceFirst(
    '{aiId}',
    AiId.parse(profile).value,
  );

  Future<OwnerReplyPreferenceResult> read(
    String profile, {
    HostReadCancellation? cancellation,
  }) async {
    final String path;
    try {
      path = _path(profile);
    } on FormatException {
      return const OwnerReplyPreferenceResult._failure(
        OwnerReplyPreferenceProblem.refused,
      );
    }
    return _request(
      writing: false,
      run: () async {
        final data = await connection.getBoundedJson(
          path,
          maxResponseBytes: 8 * 1024,
          cancellation: cancellation,
        );
        return OwnerReplyPreferences._decode(profile, data);
      },
    );
  }

  Future<OwnerReplyPreferenceResult> save(
    String profile, {
    required OwnerReplyPreferences current,
    required bool enabled,
    required OwnerReplyLength? length,
    required OwnerReplyFormat? format,
  }) async {
    if (profile != current._profileId ||
        (enabled &&
            (current.target == null || (length == null && format == null)))) {
      return const OwnerReplyPreferenceResult._failure(
        OwnerReplyPreferenceProblem.refused,
      );
    }
    return _request(
      writing: true,
      run: () async {
        final data = await connection.request(
          'PUT',
          _path(profile),
          body: {
            'expectedRevision': current.revision,
            'enabled': enabled,
            'length': length?.name,
            'format': format?.name,
            'expectedTargetToken': enabled ? current.target!._token : null,
          },
          retryAuthentication: false,
        );
        final saved = OwnerReplyPreferences._decode(profile, data);
        if (saved.revision != current.revision + 1 ||
            saved.enabled != enabled ||
            saved.length != length ||
            saved.format != format ||
            (enabled && !current.target!._matches(saved.target))) {
          throw const FormatException();
        }
        return saved;
      },
    );
  }

  Future<OwnerReplyPreferenceResult> _request({
    required bool writing,
    required Future<OwnerReplyPreferences> Function() run,
  }) async {
    final failed = OwnerReplyPreferenceResult._failure(
      writing
          ? OwnerReplyPreferenceProblem.unknown
          : OwnerReplyPreferenceProblem.unavailable,
    );
    try {
      return OwnerReplyPreferenceResult._state(await run());
    } on HostRequestException catch (error) {
      return switch (error.failure.code) {
        FailureCode.invalidArgument ||
        FailureCode.unauthenticated ||
        FailureCode.forbidden ||
        FailureCode.notFound => const OwnerReplyPreferenceResult._failure(
          OwnerReplyPreferenceProblem.refused,
        ),
        FailureCode.conflict when writing =>
          const OwnerReplyPreferenceResult._failure(
            OwnerReplyPreferenceProblem.conflict,
          ),
        _ => failed,
      };
    } on TimeoutException {
      return failed;
    } on IOException {
      return failed;
    } on FormatException {
      return failed;
    } on StateError {
      return failed;
    }
  }
}
