import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

enum OwnerAutoMemoryProblem { refused, unavailable, conflict, unknown }

/// The opaque target token is retained for an exact enable confirmation but is
/// never rendered or serialized by the UI.
final class OwnerAutoMemoryTarget {
  const OwnerAutoMemoryTarget._(
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
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  static bool _label(String text, int max) =>
      text.trim().isNotEmpty && text.length <= max && !_hidden.hasMatch(text);

  factory OwnerAutoMemoryTarget.fromJson(Object? value) {
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
    return OwnerAutoMemoryTarget._(provider, model, origin, token);
  }

  bool matches(OwnerAutoMemoryTarget? other) =>
      other != null &&
      providerId == other.providerId &&
      model == other.model &&
      origin == other.origin &&
      _token == other._token;
}

/// One captured owner statement as shown in the manager. Never contains T2 or
/// non-private content because the host never collects it.
final class OwnerAutoMemoryEntry {
  const OwnerAutoMemoryEntry({
    required this.id,
    required this.text,
    required this.tier,
    required this.status,
    required this.createdAt,
  });

  final String id;
  final String text;

  /// `t0` (explicit instruction, active) or `t1` (other owner text).
  final String tier;

  /// `active` or `pending`; pending is never injected.
  final String status;
  final DateTime createdAt;

  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static final _hidden = RegExp(
    r'[\x00-\x1f\x7f-\x9f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]',
  );

  factory OwnerAutoMemoryEntry.fromJson(
    Object? value, {
    required int maxEntryBytes,
  }) {
    if (value is! Map<String, Object?> ||
        value.length != 5 ||
        !{'id', 'text', 'tier', 'status', 'createdAt'}.every(
          value.containsKey,
        )) {
      throw const FormatException();
    }
    final id = value['id'];
    final text = value['text'];
    final tier = value['tier'];
    final status = value['status'];
    final createdAt = value['createdAt'];
    if (id is! String ||
        !_idPattern.hasMatch(id) ||
        text is! String ||
        tier is! String ||
        status is! String ||
        createdAt is! String) {
      throw const FormatException();
    }
    final entryText = text;
    if (entryText.trim() != entryText ||
        entryText.isEmpty ||
        utf8.encode(entryText).length > maxEntryBytes ||
        _hidden.hasMatch(entryText) ||
        (tier != 't0' && tier != 't1') ||
        (status != 'active' && status != 'pending')) {
      throw const FormatException();
    }
    return OwnerAutoMemoryEntry(
      id: id,
      text: entryText,
      tier: tier,
      status: status,
      createdAt: _utc(createdAt),
    );
  }

  static DateTime _utc(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null || !parsed.isUtc || parsed.toIso8601String() != raw) {
      throw const FormatException();
    }
    return parsed;
  }
}

/// The default-off, per-AI grant state. Never reads chat history here.
final class OwnerAutoMemorySettings {
  const OwnerAutoMemorySettings({
    required this.profileId,
    required this.revision,
    required this.enabled,
    required this.target,
  });

  final String profileId;
  final int revision;
  final bool enabled;
  final OwnerAutoMemoryTarget? target;

  factory OwnerAutoMemorySettings.fromJson(
    String profile,
    Map<String, Object?> data,
  ) {
    const fields = {'revision', 'enabled', 'target'};
    final revision = data['revision'];
    final enabled = data['enabled'];
    if (data.length != fields.length ||
        !fields.every(data.containsKey) ||
        revision is! int ||
        revision < 0 ||
        enabled is! bool) {
      throw const FormatException('Invalid auto memory settings response');
    }
    final target = data['target'] == null
        ? null
        : OwnerAutoMemoryTarget.fromJson(data['target']);
    if (enabled && target == null) {
      throw const FormatException('Missing auto memory target');
    }
    AiId.parse(profile);
    return OwnerAutoMemorySettings(
      profileId: profile,
      revision: revision,
      enabled: enabled,
      target: target,
    );
  }
}

/// The bounded manager view: at most [maxEntries] active/pending entries.
final class OwnerAutoMemoryList {
  const OwnerAutoMemoryList({
    required this.profileId,
    required this.revision,
    required this.maxEntries,
    required this.entries,
  });

  final String profileId;
  final int revision;
  final int maxEntries;
  final List<OwnerAutoMemoryEntry> entries;

  factory OwnerAutoMemoryList.fromJson(
    String profile,
    Map<String, Object?> data,
  ) {
    const fields = {'revision', 'maxEntries', 'entries'};
    final revision = data['revision'];
    final maxEntries = data['maxEntries'];
    final rawEntries = data['entries'];
    if (data.length != fields.length ||
        !fields.every(data.containsKey) ||
        revision is! int ||
        revision < 0 ||
        maxEntries is! int ||
        maxEntries < 1 ||
        maxEntries > 100 ||
        rawEntries is! List ||
        rawEntries.length > maxEntries) {
      throw const FormatException('Invalid auto memory list response');
    }
    final entries = <OwnerAutoMemoryEntry>[];
    final ids = <String>{};
    for (final raw in rawEntries) {
      final entry = OwnerAutoMemoryEntry.fromJson(
        raw,
        maxEntryBytes: OwnerAutoMemoryApi.maxEntryBytes,
      );
      if (!ids.add(entry.id)) {
        throw const FormatException('Duplicate auto memory entry');
      }
      entries.add(entry);
    }
    AiId.parse(profile);
    return OwnerAutoMemoryList(
      profileId: profile,
      revision: revision,
      maxEntries: maxEntries,
      entries: List.unmodifiable(entries),
    );
  }
}

final class OwnerAutoMemoryResult<T> {
  const OwnerAutoMemoryResult._(this.state, this.problem);
  const OwnerAutoMemoryResult.loaded(T state) : this._(state, null);
  const OwnerAutoMemoryResult.failed(OwnerAutoMemoryProblem problem)
    : this._(null, problem);

  final T? state;
  final OwnerAutoMemoryProblem? problem;
}

/// Owner-scoped default-off auto chat-history memory manager. No group data,
/// third-party content, or other AI is ever read; only the owner's own private
/// scope is listed, deleted or cleared.
class OwnerAutoMemoryApi {
  const OwnerAutoMemoryApi(this.connection);
  final HostConnection connection;

  static const _maxResponseBytes = 64 * 1024;
  static const maxEntryBytes = 512;
  static const maxEntries = 50;

  String _collection(String profile) => Routes.aiOwnerAutoMemory.replaceFirst(
    '{aiId}',
    Uri.encodeComponent(AiId.parse(profile).value),
  );

  String _entry(String profile, String memoryId) =>
      Routes.aiOwnerAutoMemoryEntry
          .replaceFirst(
            '{aiId}',
            Uri.encodeComponent(AiId.parse(profile).value),
          )
          .replaceFirst('{memoryId}', Uri.encodeComponent(_checkId(memoryId)));

  String _settings(String profile) =>
      Routes.aiOwnerAutoMemorySettings.replaceFirst(
        '{aiId}',
        Uri.encodeComponent(AiId.parse(profile).value),
      );

  static String _checkId(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value)) {
      throw const FormatException('Invalid memory id');
    }
    return value;
  }

  Future<OwnerAutoMemoryResult<OwnerAutoMemorySettings>> readSettings(
    String profile, {
    HostReadCancellation? cancellation,
  }) async {
    final String path;
    try {
      path = _settings(profile);
    } on FormatException {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.refused,
      );
    }
    try {
      final data = await connection.getBoundedJson(
        path,
        maxResponseBytes: _maxResponseBytes,
        cancellation: cancellation,
      );
      return OwnerAutoMemoryResult.loaded(
        OwnerAutoMemorySettings.fromJson(profile, data),
      );
    } on HostRequestException catch (error) {
      return OwnerAutoMemoryResult.failed(_problem(error, writing: false));
    } on FormatException {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.unavailable,
      );
    } on TimeoutException {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.unavailable,
      );
    } on IOException {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.unavailable,
      );
    } on StateError {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.unavailable,
      );
    }
  }

  Future<OwnerAutoMemoryResult<OwnerAutoMemoryList>> readEntries(
    String profile, {
    HostReadCancellation? cancellation,
  }) async {
    final String path;
    try {
      path = _collection(profile);
    } on FormatException {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.refused,
      );
    }
    try {
      final data = await connection.getBoundedJson(
        path,
        maxResponseBytes: _maxResponseBytes,
        cancellation: cancellation,
      );
      return OwnerAutoMemoryResult.loaded(
        OwnerAutoMemoryList.fromJson(profile, data),
      );
    } on HostRequestException catch (error) {
      return OwnerAutoMemoryResult.failed(_problem(error, writing: false));
    } on FormatException {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.unavailable,
      );
    } on TimeoutException {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.unavailable,
      );
    } on IOException {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.unavailable,
      );
    } on StateError {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.unavailable,
      );
    }
  }

  Future<OwnerAutoMemoryResult<OwnerAutoMemorySettings>> setEnabled(
    String profile, {
    required OwnerAutoMemorySettings current,
    required bool enabled,
  }) async {
    if (current.profileId != profile ||
        current.enabled == enabled ||
        (enabled && current.target == null)) {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.refused,
      );
    }
    final token = enabled ? current.target!._token : null;
    return _writeSettings(
      profile,
      current,
      method: 'PUT',
      path: _settings(profile),
      body: {
        'expectedRevision': current.revision,
        'enabled': enabled,
        'expectedTargetToken': token,
      },
      verify: (saved) =>
          saved.revision == current.revision + 1 &&
          saved.enabled == enabled &&
          (!enabled || current.target!.matches(saved.target)),
    );
  }

  Future<OwnerAutoMemoryResult<OwnerAutoMemoryList>> deleteEntry(
    String profile, {
    required OwnerAutoMemoryList current,
    required String memoryId,
  }) async {
    final before = current.entries
        .where((entry) => entry.id == memoryId)
        .firstOrNull;
    if (current.profileId != profile || before == null) {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.refused,
      );
    }
    final String path;
    try {
      path = _entry(profile, memoryId);
    } on FormatException {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.refused,
      );
    }
    return _writeList(
      profile,
      current,
      method: 'DELETE',
      path: path,
      body: {'expectedRevision': current.revision},
      verify: (saved) {
        final expectedIds = current.entries
            .where((entry) => entry.id != memoryId)
            .map((entry) => entry.id)
            .toSet();
        return saved.revision == current.revision + 1 &&
            saved.entries.length == current.entries.length - 1 &&
            saved.entries
                .map((entry) => entry.id)
                .toSet()
                .containsAll(expectedIds) &&
            !saved.entries.any((entry) => entry.id == memoryId);
      },
    );
  }

  Future<OwnerAutoMemoryResult<OwnerAutoMemoryList>> clear(
    String profile, {
    required OwnerAutoMemoryList current,
  }) async {
    if (current.profileId != profile || current.entries.isEmpty) {
      return const OwnerAutoMemoryResult.failed(
        OwnerAutoMemoryProblem.refused,
      );
    }
    return _writeList(
      profile,
      current,
      method: 'DELETE',
      path: _collection(profile),
      body: {'expectedRevision': current.revision},
      verify: (saved) =>
          saved.revision == current.revision + 1 && saved.entries.isEmpty,
    );
  }

  Future<OwnerAutoMemoryResult<OwnerAutoMemorySettings>> _writeSettings(
    String profile,
    OwnerAutoMemorySettings current, {
    required String method,
    required String path,
    required Map<String, Object?> body,
    required bool Function(OwnerAutoMemorySettings saved) verify,
  }) async {
    try {
      final data = await connection.request(
        method,
        path,
        body: body,
        retryAuthentication: false,
      );
      final saved = OwnerAutoMemorySettings.fromJson(profile, data);
      return verify(saved)
          ? OwnerAutoMemoryResult.loaded(saved)
          : const OwnerAutoMemoryResult.failed(OwnerAutoMemoryProblem.unknown);
    } on HostRequestException catch (error) {
      return OwnerAutoMemoryResult.failed(_problem(error, writing: true));
    } on FormatException {
      return const OwnerAutoMemoryResult.failed(OwnerAutoMemoryProblem.unknown);
    } on TimeoutException {
      return const OwnerAutoMemoryResult.failed(OwnerAutoMemoryProblem.unknown);
    } on IOException {
      return const OwnerAutoMemoryResult.failed(OwnerAutoMemoryProblem.unknown);
    } on StateError {
      return const OwnerAutoMemoryResult.failed(OwnerAutoMemoryProblem.unknown);
    }
  }

  Future<OwnerAutoMemoryResult<OwnerAutoMemoryList>> _writeList(
    String profile,
    OwnerAutoMemoryList current, {
    required String method,
    required String path,
    required Map<String, Object?> body,
    required bool Function(OwnerAutoMemoryList saved) verify,
  }) async {
    try {
      final data = await connection.request(
        method,
        path,
        body: body,
        retryAuthentication: false,
      );
      final saved = OwnerAutoMemoryList.fromJson(profile, data);
      return verify(saved)
          ? OwnerAutoMemoryResult.loaded(saved)
          : const OwnerAutoMemoryResult.failed(OwnerAutoMemoryProblem.unknown);
    } on HostRequestException catch (error) {
      return OwnerAutoMemoryResult.failed(_problem(error, writing: true));
    } on FormatException {
      return const OwnerAutoMemoryResult.failed(OwnerAutoMemoryProblem.unknown);
    } on TimeoutException {
      return const OwnerAutoMemoryResult.failed(OwnerAutoMemoryProblem.unknown);
    } on IOException {
      return const OwnerAutoMemoryResult.failed(OwnerAutoMemoryProblem.unknown);
    } on StateError {
      return const OwnerAutoMemoryResult.failed(OwnerAutoMemoryProblem.unknown);
    }
  }

  static OwnerAutoMemoryProblem _problem(
    HostRequestException error, {
    required bool writing,
  }) => switch (error.failure.code) {
    FailureCode.invalidArgument ||
    FailureCode.unauthenticated ||
    FailureCode.forbidden ||
    FailureCode.notFound => OwnerAutoMemoryProblem.refused,
    FailureCode.conflict => OwnerAutoMemoryProblem.conflict,
    _ => writing ? OwnerAutoMemoryProblem.unknown : OwnerAutoMemoryProblem.unavailable,
  };
}
