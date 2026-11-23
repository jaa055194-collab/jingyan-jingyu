import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

typedef AndroidPrivateChatItem = ({
  int seq,
  String exchangeId,
  String user,
  String assistant,
});

/// One owner-private exchange page for the Android self-AI transcript.
typedef AndroidPrivateChatPage = ({
  List<AndroidPrivateChatItem> items,
  bool hasMore,
});

/// Explicit, bounded transport for the isolated Android private-chat transcript.
///
/// This adapter is deliberately separate from the ordinary message/outbox path:
/// it never enqueues a normal message, never replays a mutation automatically and
/// never follows a redirect. Each call is one bounded request; a caller that is
/// unsure whether a push was applied must read the page back instead of retrying
/// blindly. The route carries only the exchange envelope: no provider key, URL,
/// persona, model setting, owner ID or other context is ever sent.
final class AndroidPrivateChatSyncApi {
  const AndroidPrivateChatSyncApi(this._connection);

  final HostConnection _connection;

  /// Engineering limits of this transport slice, mirrored by the host.
  static const int maxUserBytes = 4096;
  static const int maxAssistantBytes = 8192;
  static const int pageSize = 16;

  /// A page can contain [pageSize] pairs of both bounded texts plus JSON
  /// escaping. JSON may expand a control byte to six bytes; leave 256
  /// envelope bytes per row for the sequence, ID and field names.
  static const int _maxPageResponseBytes =
      256 + pageSize * (6 * (maxUserBytes + maxAssistantBytes) + 256);

  /// The push receipt is exactly `{"seq":<positive int>}`.
  static const int _maxPushResponseBytes = 128;

  static const FormatException _malformed = FormatException(
    'Invalid private transcript response',
  );

  String _path(String profileId) => Routes.androidPrivateChat.replaceFirst(
    '{aiId}',
    Uri.encodeComponent(AiId.parse(profileId).value),
  );

  static bool _text(String value, int maxBytes) =>
      value.length <= maxBytes &&
      value.trim().isNotEmpty &&
      !value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff) &&
      utf8.encode(value).length <= maxBytes;

  static void _checkExchangeId(String value) {
    validateId(value, kind: 'exchange');
  }

  /// One bounded GET strictly after [after], in ascending sequence order.
  Future<AndroidPrivateChatPage> list(String profileId, int after) async {
    final path = _path(profileId);
    if (after < 0) {
      throw const FormatException('Invalid private transcript cursor');
    }
    final data = await _call(
      'GET',
      path,
      query: {'after': '$after'},
      maxResponseBytes: _maxPageResponseBytes,
    );
    const fields = {'items', 'hasMore'};
    if (data.length != fields.length || !fields.every(data.containsKey)) {
      throw _malformed;
    }
    final rows = data['items'];
    final hasMore = data['hasMore'];
    if (rows is! List || hasMore is! bool || rows.length > pageSize) {
      throw _malformed;
    }
    if (hasMore && rows.isEmpty) throw _malformed;
    final items = <AndroidPrivateChatItem>[];
    final seenIds = <String>{};
    var previous = after;
    for (final row in rows) {
      if (row is! Map<String, Object?>) throw _malformed;
      const itemFields = {'seq', 'exchangeId', 'user', 'assistant'};
      if (row.length != itemFields.length ||
          !itemFields.every(row.containsKey)) {
        throw _malformed;
      }
      final seq = row['seq'];
      final exchangeId = row['exchangeId'];
      final user = row['user'];
      final assistant = row['assistant'];
      if (seq is! int ||
          seq <= previous ||
          exchangeId is! String ||
          user is! String ||
          assistant is! String) {
        throw _malformed;
      }
      try {
        _checkExchangeId(exchangeId);
      } on FormatException {
        throw _malformed;
      }
      if (!_text(user, maxUserBytes) || !_text(assistant, maxAssistantBytes)) {
        throw _malformed;
      }
      if (!seenIds.add(exchangeId)) throw _malformed;
      items.add((
        seq: seq,
        exchangeId: exchangeId,
        user: user,
        assistant: assistant,
      ));
      previous = seq;
    }
    return (
      items: List<AndroidPrivateChatItem>.unmodifiable(items),
      hasMore: hasMore,
    );
  }

  /// One bounded POST with exactly the exchange envelope. Returns the host's
  /// positive profile-local sequence. There is no automatic retry.
  Future<int> push(
    String profileId, {
    required String exchangeId,
    required String user,
    required String assistant,
  }) async {
    final path = _path(profileId);
    _checkExchangeId(exchangeId);
    if (!_text(user, maxUserBytes) || !_text(assistant, maxAssistantBytes)) {
      throw const FormatException('Invalid private transcript text');
    }
    final data = await _call(
      'POST',
      path,
      body: {'exchangeId': exchangeId, 'user': user, 'assistant': assistant},
      maxResponseBytes: _maxPushResponseBytes,
    );
    if (data.length != 1) throw _malformed;
    final seq = data['seq'];
    if (seq is! int || seq < 1) throw _malformed;
    return seq;
  }

  Future<Map<String, Object?>> _call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
    required int maxResponseBytes,
  }) async {
    try {
      return await _connection.requestBoundedObject(
        method,
        path,
        query: query,
        body: body,
        maxResponseBytes: maxResponseBytes,
        expectedStatus: 200,
      );
    } on FormatException {
      // Never echo a response snippet: it could carry private transcript text.
      throw _malformed;
    }
  }
}
