import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

enum OwnerMemoryProblem { refused, unavailable, conflict, unknown }

/// The opaque target token is retained for an exact enable confirmation but is
/// never rendered or serialized by the UI.
final class OwnerMemoryTarget {
  const OwnerMemoryTarget._(
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

  factory OwnerMemoryTarget.fromJson(Object? value) {
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
    return OwnerMemoryTarget._(provider, model, origin, token);
  }

  bool matches(OwnerMemoryTarget? other) =>
      other != null &&
      providerId == other.providerId &&
      model == other.model &&
      origin == other.origin &&
      _token == other._token;
}

final class OwnerMemoryNote {
  const OwnerMemoryNote({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String text;
  final DateTime createdAt;
  final DateTime updatedAt;

  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  factory OwnerMemoryNote.fromJson(Object? value, {required int maxNoteBytes}) {
    if (value is! Map<String, Object?> ||
        value.length != 4 ||
        !{'id', 'text', 'createdAt', 'updatedAt'}.every(value.containsKey)) {
      throw const FormatException();
    }
    final id = value['id'];
    final text = value['text'];
    final createdRaw = value['createdAt'];
    final updatedRaw = value['updatedAt'];
    if (id is! String ||
        !_idPattern.hasMatch(id) ||
        text is! String ||
        createdRaw is! String ||
        updatedRaw is! String) {
      throw const FormatException();
    }
    final noteText = text;
    if (noteText.trim() != noteText ||
        noteText.isEmpty ||
        utf8.encode(noteText).length > maxNoteBytes ||
        OwnerMemoryNotes._hidden.hasMatch(noteText)) {
      throw const FormatException();
    }
    final createdAt = _utc(createdRaw);
    final updatedAt = _utc(updatedRaw);
    return OwnerMemoryNote(
      id: id,
      text: noteText,
      createdAt: createdAt,
      updatedAt: updatedAt,
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

final class OwnerMemoryNotes {
  const OwnerMemoryNotes({
    required this.profileId,
    required this.revision,
    required this.enabled,
    required this.maxNotes,
    required this.maxNoteBytes,
    required this.notes,
    required this.target,
  });

  final String profileId;
  final int revision;
  final bool enabled;
  final int maxNotes;
  final int maxNoteBytes;
  final List<OwnerMemoryNote> notes;
  final OwnerMemoryTarget? target;

  static final _hidden = RegExp(
    r'[\x00-\x1f\x7f-\x9f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]',
  );

  factory OwnerMemoryNotes.fromJson(String profile, Map<String, Object?> data) {
    const fields = {
      'revision',
      'enabled',
      'maxNotes',
      'maxNoteBytes',
      'notes',
      'target',
    };
    final revision = data['revision'];
    final enabled = data['enabled'];
    final maxNotes = data['maxNotes'];
    final maxNoteBytes = data['maxNoteBytes'];
    final rawNotes = data['notes'];
    if (data.length != fields.length ||
        !fields.every(data.containsKey) ||
        revision is! int ||
        revision < 0 ||
        enabled is! bool ||
        maxNotes is! int ||
        maxNotes < 1 ||
        maxNotes > 100 ||
        maxNoteBytes is! int ||
        maxNoteBytes < 1 ||
        maxNoteBytes > 4096 ||
        rawNotes is! List ||
        rawNotes.length > maxNotes) {
      throw const FormatException('Invalid memory notes response');
    }
    final target = data['target'] == null
        ? null
        : OwnerMemoryTarget.fromJson(data['target']);
    if (enabled && target == null) {
      throw const FormatException('Missing memory target');
    }
    final notes = <OwnerMemoryNote>[];
    final ids = <String>{};
    for (final raw in rawNotes) {
      final note = OwnerMemoryNote.fromJson(raw, maxNoteBytes: maxNoteBytes);
      if (!ids.add(note.id)) {
        throw const FormatException('Duplicate memory note');
      }
      notes.add(note);
    }
    AiId.parse(profile);
    return OwnerMemoryNotes(
      profileId: profile,
      revision: revision,
      enabled: enabled,
      maxNotes: maxNotes,
      maxNoteBytes: maxNoteBytes,
      notes: List.unmodifiable(notes),
      target: target,
    );
  }

  /// Mirrors the host's single-line text rule. The host rejects LF and other
  /// controls; the UI must not send text it cannot persist.
  static String? normalizeText(String raw, int maxNoteBytes) {
    final text = raw.trim();
    if (text.isEmpty ||
        utf8.encode(text).length > maxNoteBytes ||
        _hidden.hasMatch(text)) {
      return null;
    }
    return text;
  }
}

final class OwnerMemoryResult {
  const OwnerMemoryResult._(this.state, this.problem);
  const OwnerMemoryResult.loaded(OwnerMemoryNotes state) : this._(state, null);
  const OwnerMemoryResult.failed(OwnerMemoryProblem problem)
    : this._(null, problem);

  final OwnerMemoryNotes? state;
  final OwnerMemoryProblem? problem;
}

/// Owner-scoped manual notes. No chat history, group data, model, proactive
/// send or existing `ownerTextOnly` grant is read or changed here.
class OwnerMemoryNotesApi {
  const OwnerMemoryNotesApi(this.connection);
  final HostConnection connection;

  static const _maxResponseBytes = 64 * 1024;

  String _collection(String profile) => Routes.aiOwnerMemoryNotes.replaceFirst(
    '{aiId}',
    Uri.encodeComponent(AiId.parse(profile).value),
  );

  String _note(String profile, String noteId) => Routes.aiOwnerMemoryNote
      .replaceFirst('{aiId}', Uri.encodeComponent(AiId.parse(profile).value))
      .replaceFirst('{noteId}', Uri.encodeComponent(_checkId(noteId)));

  String _settings(String profile) => Routes.aiOwnerMemoryNoteSettings
      .replaceFirst('{aiId}', Uri.encodeComponent(AiId.parse(profile).value));

  static String _checkId(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value)) {
      throw const FormatException('Invalid note id');
    }
    return value;
  }

  Future<OwnerMemoryResult> read(
    String profile, {
    HostReadCancellation? cancellation,
  }) async {
    final String path;
    try {
      path = _collection(profile);
    } on FormatException {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.refused);
    }
    try {
      final data = await connection.getBoundedJson(
        path,
        maxResponseBytes: _maxResponseBytes,
        cancellation: cancellation,
      );
      return OwnerMemoryResult.loaded(OwnerMemoryNotes.fromJson(profile, data));
    } on HostRequestException catch (error) {
      return OwnerMemoryResult.failed(_problem(error, writing: false));
    } on FormatException {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.unavailable);
    } on TimeoutException {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.unavailable);
    } on IOException {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.unavailable);
    } on StateError {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.unavailable);
    }
  }

  Future<OwnerMemoryResult> add(
    String profile, {
    required OwnerMemoryNotes current,
    required String text,
  }) async {
    if (current.profileId != profile ||
        current.notes.length >= current.maxNotes) {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.refused);
    }
    final normalized = OwnerMemoryNotes.normalizeText(
      text,
      current.maxNoteBytes,
    );
    if (normalized == null) {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.refused);
    }
    return _write(
      profile,
      current,
      method: 'POST',
      path: _collection(profile),
      body: {'text': normalized, 'expectedRevision': current.revision},
      verify: (saved) {
        final oldIds = current.notes.map((note) => note.id).toSet();
        final added = saved.notes
            .where((note) => !oldIds.contains(note.id))
            .toList();
        return saved.revision == current.revision + 1 &&
            saved.enabled == current.enabled &&
            saved.notes.length == current.notes.length + 1 &&
            added.length == 1 &&
            added.single.text == normalized;
      },
    );
  }

  Future<OwnerMemoryResult> edit(
    String profile, {
    required OwnerMemoryNotes current,
    required String noteId,
    required String text,
  }) async {
    final before = current.notes.where((note) => note.id == noteId).firstOrNull;
    final normalized = OwnerMemoryNotes.normalizeText(
      text,
      current.maxNoteBytes,
    );
    if (current.profileId != profile || before == null || normalized == null) {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.refused);
    }
    final String path;
    try {
      path = _note(profile, noteId);
    } on FormatException {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.refused);
    }
    return _write(
      profile,
      current,
      method: 'PATCH',
      path: path,
      body: {'text': normalized, 'expectedRevision': current.revision},
      verify: (saved) =>
          _sameNoteSet(saved, current) &&
          saved.revision == current.revision + 1 &&
          saved.notes.singleWhere((note) => note.id == noteId).text ==
              normalized,
    );
  }

  Future<OwnerMemoryResult> delete(
    String profile, {
    required OwnerMemoryNotes current,
    required String noteId,
  }) async {
    final before = current.notes.where((note) => note.id == noteId).firstOrNull;
    if (current.profileId != profile || before == null) {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.refused);
    }
    final String path;
    try {
      path = _note(profile, noteId);
    } on FormatException {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.refused);
    }
    return _write(
      profile,
      current,
      method: 'DELETE',
      path: path,
      body: {'expectedRevision': current.revision},
      verify: (saved) {
        final expectedIds = current.notes
            .where((note) => note.id != noteId)
            .map((note) => note.id)
            .toSet();
        return saved.revision == current.revision + 1 &&
            saved.enabled == current.enabled &&
            saved.notes.length == current.notes.length - 1 &&
            saved.notes
                .map((note) => note.id)
                .toSet()
                .containsAll(expectedIds) &&
            !saved.notes.any((note) => note.id == noteId);
      },
    );
  }

  Future<OwnerMemoryResult> clear(
    String profile, {
    required OwnerMemoryNotes current,
  }) async {
    if (current.profileId != profile || current.notes.isEmpty) {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.refused);
    }
    return _write(
      profile,
      current,
      method: 'DELETE',
      path: _collection(profile),
      body: {'expectedRevision': current.revision},
      verify: (saved) =>
          saved.revision == current.revision + 1 &&
          saved.enabled == current.enabled &&
          saved.notes.isEmpty,
    );
  }

  Future<OwnerMemoryResult> setEnabled(
    String profile, {
    required OwnerMemoryNotes current,
    required bool enabled,
  }) async {
    if (current.profileId != profile ||
        current.enabled == enabled ||
        (enabled && current.target == null)) {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.refused);
    }
    final token = enabled ? current.target!._token : null;
    return _write(
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
          _sameNotes(saved, current) &&
          (!enabled || current.target!.matches(saved.target)),
    );
  }

  Future<OwnerMemoryResult> _write(
    String profile,
    OwnerMemoryNotes current, {
    required String method,
    required String path,
    required Map<String, Object?> body,
    required bool Function(OwnerMemoryNotes saved) verify,
  }) async {
    try {
      final data = await connection.request(
        method,
        path,
        body: body,
        retryAuthentication: false,
      );
      final saved = OwnerMemoryNotes.fromJson(profile, data);
      return verify(saved)
          ? OwnerMemoryResult.loaded(saved)
          : const OwnerMemoryResult.failed(OwnerMemoryProblem.unknown);
    } on HostRequestException catch (error) {
      return OwnerMemoryResult.failed(_problem(error, writing: true));
    } on FormatException {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.unknown);
    } on TimeoutException {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.unknown);
    } on IOException {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.unknown);
    } on StateError {
      return const OwnerMemoryResult.failed(OwnerMemoryProblem.unknown);
    }
  }

  static bool _sameNotes(OwnerMemoryNotes a, OwnerMemoryNotes b) =>
      a.maxNotes == b.maxNotes &&
      a.maxNoteBytes == b.maxNoteBytes &&
      a.notes.length == b.notes.length &&
      [
        for (var i = 0; i < a.notes.length; i++)
          a.notes[i].id == b.notes[i].id && a.notes[i].text == b.notes[i].text,
      ].every((same) => same);

  static bool _sameNoteSet(OwnerMemoryNotes a, OwnerMemoryNotes b) =>
      a.notes.length == b.notes.length &&
      a.notes
          .map((note) => note.id)
          .toSet()
          .containsAll(b.notes.map((note) => note.id));

  static OwnerMemoryProblem _problem(
    HostRequestException error, {
    required bool writing,
  }) => switch (error.failure.code) {
    FailureCode.invalidArgument ||
    FailureCode.unauthenticated ||
    FailureCode.forbidden ||
    FailureCode.notFound => OwnerMemoryProblem.refused,
    FailureCode.conflict => OwnerMemoryProblem.conflict,
    _ => writing ? OwnerMemoryProblem.unknown : OwnerMemoryProblem.unavailable,
  };
}
