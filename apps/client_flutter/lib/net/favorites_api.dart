import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

enum FavoriteKind { text, message, link, file }

/// Display-only projection. Never retains source JSON, URLs, attachment or
/// conversation references, tags, notes or arbitrary message body fields.
class FavoriteSummary {
  const FavoriteSummary._({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.title,
    required this.preview,
  });

  final String id;
  final FavoriteKind kind;
  final DateTime createdAt;
  final String? title;
  final String? preview;

  static const _fields = {
    'id',
    'kind',
    'messageId',
    'conversationId',
    'title',
    'content',
    'tags',
    'note',
    'createdAt',
  };
  static final _utc = RegExp(
    r'^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.\d{1,6})?Z$',
  );
  // Plain text only. Withhold previews that resemble structured payloads,
  // paths, URLs or credential assignments. This is not a secret detector.
  static final _opaque = RegExp(
    r'[{}\[\]\\]|/\S|\bwww\.|\b(?:file|https?|ftp|data|mailto):|'
    r'\b(?:api[_ -]?key|password|secret|(?:access[_ -]?|refresh[_ -]?)?token|authorization)\s*[:=]|'
    r'\bBearer\s+|[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',
    caseSensitive: false,
  );
  static final _spaces = RegExp(r'\s+');

  static String? _displayText(String? value, int maxLength) {
    if (value == null || _opaque.hasMatch(value)) return null;
    final text = value.trim().replaceAll(_spaces, ' ');
    if (text.isEmpty) return null;
    final sample = text.runes.take(maxLength + 1).toList();
    return sample.length <= maxLength
        ? text
        : '${String.fromCharCodes(sample.take(maxLength))}…';
  }

  factory FavoriteSummary._fromJson(Object? value) {
    if (value is! Map<String, Object?> ||
        value.length != _fields.length ||
        !value.keys.every(_fields.contains)) {
      throw const FormatException();
    }
    final id = value['id'];
    final title = value['title'];
    final content = value['content'];
    final note = value['note'];
    final tags = value['tags'];
    final created = value['createdAt'];
    final kind = switch (value['kind']) {
      'text' => FavoriteKind.text,
      'message' => FavoriteKind.message,
      'link' => FavoriteKind.link,
      'file' => FavoriteKind.file,
      _ => throw const FormatException(),
    };
    if (id is! String ||
        (title != null && (title is! String || title.length > 500)) ||
        content is! String ||
        content.trim().isEmpty ||
        (note != null && (note is! String || note.length > 2000)) ||
        (tags != null &&
            (tags is! List ||
                tags.length > 20 ||
                tags.any(
                  (tag) =>
                      tag is! String || tag.trim().isEmpty || tag.length > 50,
                ))) ||
        created is! String) {
      throw const FormatException();
    }
    validateId(id, kind: 'favorite');
    final timestamp = _utc.firstMatch(created);
    final createdAt = timestamp == null ? null : DateTime.tryParse(created);
    // DateTime.parse can normalize invalid calendar/clock components.
    if (createdAt == null ||
        !createdAt.toIso8601String().startsWith('${timestamp![1]}.')) {
      throw const FormatException();
    }

    final message = value['messageId'];
    final conversation = value['conversationId'];
    String? preview;
    if (kind == FavoriteKind.message) {
      if (message is! String || conversation is! String) {
        throw const FormatException();
      }
      validateId(message, kind: 'message');
      validateId(conversation, kind: 'conversation');
      // The host supplies the authorized source body as a *JSON string*.
      final body = jsonDecode(content);
      if (body is! Map<String, Object?>) throw const FormatException();
      final text = body['text'];
      if (text != null && text is! String) throw const FormatException();
      if (body['recalled'] != true) {
        preview = _displayText(text as String?, 160);
      }
    } else {
      if (message != null || conversation != null || content.length > 65536) {
        throw const FormatException();
      }
      if (kind == FavoriteKind.text) preview = _displayText(content, 160);
    }
    return FavoriteSummary._(
      id: id,
      kind: kind,
      createdAt: createdAt,
      title: kind == FavoriteKind.message || kind == FavoriteKind.text
          ? _displayText(title as String?, 100)
          : null,
      preview: preview,
    );
  }
}

sealed class FavoritesOutcome {
  const FavoritesOutcome();
}

final class FavoritesLoaded extends FavoritesOutcome {
  const FavoritesLoaded(this.favorites);
  final List<FavoriteSummary> favorites;
}

final class FavoritesDenied extends FavoritesOutcome {
  const FavoritesDenied();
}

final class FavoritesUnavailable extends FavoritesOutcome {
  const FavoritesUnavailable();
}

final class FavoritesMalformed extends FavoritesOutcome {
  const FavoritesMalformed();
}

/// Reads the authenticated caller's existing favorites. The host applies its
/// live visibility check; an omitted row is not a client-side tombstone.
class FavoritesApi {
  const FavoritesApi(this.connection);

  final HostConnection connection;
  static const _maxResponseBytes = 2 * 1024 * 1024;

  Future<FavoritesOutcome> readFavorites({
    HostReadCancellation? cancellation,
  }) async {
    try {
      // This route has no pagination. Fail closed on the byte limit rather than
      // presenting a truncated response as a complete list.
      final body = await connection.getBoundedJson(
        Routes.favorites,
        maxResponseBytes: _maxResponseBytes,
        cancellation: cancellation,
      );
      final rows = body['favorites'];
      if (body.length != 1 || rows is! List) return const FavoritesMalformed();
      final ids = <String>{};
      final favorites = <FavoriteSummary>[];
      for (final row in rows) {
        final favorite = FavoriteSummary._fromJson(row);
        if (!ids.add(favorite.id)) return const FavoritesMalformed();
        favorites.add(favorite);
      }
      return FavoritesLoaded(List.unmodifiable(favorites));
    } on HostRequestException catch (error) {
      return switch (error.failure.code) {
        FailureCode.unauthenticated ||
        FailureCode.forbidden => const FavoritesDenied(),
        _ => const FavoritesUnavailable(),
      };
    } on FormatException {
      return const FavoritesMalformed();
    } on IOException {
      return const FavoritesUnavailable();
    } on TimeoutException {
      return const FavoritesUnavailable();
    } on StateError {
      // The shared HttpClient can close before opening the request.
      return const FavoritesUnavailable();
    }
  }
}
