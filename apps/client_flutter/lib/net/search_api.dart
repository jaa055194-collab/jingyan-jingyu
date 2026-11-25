library;

import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// Strict, read-only client adapter for the already-merged host global search.
///
/// `GET /search?type=message` is a **bounded scan / blind-index lookup on the
/// host**, not a client full-text index. This layer performs no search of its
/// own: it forwards one trimmed query, validates every row the host returns and
/// reports typed outcomes. It never ranks, re-orders, caches or invents a hit,
/// and it holds no message store. Authentication renewal (bounded one-shot 401
/// replay) is inherited from [HostConnection]; this class adds no retry.

/// How the host produced a hit. `blind` came from the encrypted blind index,
/// `scan` from the bounded per-conversation decrypt-and-compare fallback.
/// Neither implies completeness, ranking or an exhaustive index.
enum SearchHitMode { blind, scan }

/// One validated message hit, exactly as the host returned it.
class SearchHit {
  const SearchHit({
    required this.conversationId,
    required this.messageId,
    required this.seq,
    required this.senderId,
    required this.kind,
    required this.body,
    required this.sentAt,
    required this.mode,
  });

  final String conversationId;
  final String messageId;
  final int seq;
  final String senderId;
  final MessageKind kind;

  /// The stored message body (for text messages, `{'text': ...}`).
  final Map<String, Object?> body;

  /// Always UTC, as the host emits it.
  final DateTime sentAt;
  final SearchHitMode mode;

  static const _keys = {
    'conversationId',
    'messageId',
    'seq',
    'senderId',
    'kind',
    'body',
    'sentAt',
    'mode',
  };

  /// Visible text of this hit, or null when the body carries no `text` string.
  /// This is a projection of the host's stored body, never a re-match.
  String? get text => switch (body['text']) {
    final String value => value,
    _ => null,
  };

  factory SearchHit.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('搜索命中无效');
    if (value.length != _keys.length ||
        value.keys.any((key) => key is! String || !_keys.contains(key))) {
      throw const FormatException('搜索命中字段无效');
    }
    final conversationId = value['conversationId'];
    final messageId = value['messageId'];
    final senderId = value['senderId'];
    final seq = value['seq'];
    final kindRaw = value['kind'];
    final body = value['body'];
    final sentAtRaw = value['sentAt'];
    final modeRaw = value['mode'];
    if (conversationId is! String ||
        messageId is! String ||
        senderId is! String ||
        seq is! int ||
        seq < 1 ||
        kindRaw is! String ||
        body is! Map ||
        sentAtRaw is! String ||
        modeRaw is! String) {
      throw const FormatException('搜索命中无效');
    }
    final kind = MessageKind.tryParse(kindRaw);
    final sentAt = DateTime.tryParse(sentAtRaw);
    final mode = switch (modeRaw) {
      'blind' => SearchHitMode.blind,
      'scan' => SearchHitMode.scan,
      _ => null,
    };
    if (kind == null || sentAt == null || !sentAt.isUtc || mode == null) {
      throw const FormatException('搜索命中无效');
    }
    return SearchHit(
      conversationId: validateId(conversationId, kind: 'conversation'),
      messageId: validateId(messageId, kind: 'message'),
      seq: seq,
      senderId: validateId(senderId, kind: 'account'),
      kind: kind,
      body: Map<String, Object?>.unmodifiable(
        body.map((key, value) => MapEntry('$key', value)),
      ),
      sentAt: sentAt,
      mode: mode,
    );
  }
}

/// Typed outcome of one search read. Transport errors never reach the UI raw.
sealed class SearchOutcome {
  const SearchOutcome();

  @override
  String toString() => 'SearchOutcome(${runtimeType.toString()})';
}

/// The host answered with zero or more validated hits.
class SearchLoaded extends SearchOutcome {
  const SearchLoaded(this.hits);

  final List<SearchHit> hits;

  bool get isEmpty => hits.isEmpty;

  @override
  String toString() => 'SearchLoaded(${hits.length} hits)';
}

/// The caller is not authenticated, or the host denied this account.
/// This is **not** an empty result: nothing about coverage is known.
class SearchUnauthenticated extends SearchOutcome {
  const SearchUnauthenticated();
}

/// The host was unreachable, failed, rejected the request, or timed out.
class SearchUnavailable extends SearchOutcome {
  const SearchUnavailable();
}

/// The host answered, but the payload broke the contract. Nothing is used.
class SearchMalformed extends SearchOutcome {
  const SearchMalformed();
}

class SearchApi {
  SearchApi(this.connection);

  final HostConnection connection;

  /// Host bound on `q` (see `MessagesModule._search`).
  static const int maxQueryLength = 200;

  /// Host bound on `limit`.
  static const int maxLimit = 100;

  /// Only message hits have the validated row shape above; `favorite`/`file`
  /// hits are a different, unimplemented surface and are rejected here rather
  /// than half-parsed.
  static const String _type = 'message';

  /// One explicit `GET /search` read.
  ///
  /// An empty or whitespace-only [query] is a client-side `FormatException`:
  /// no request is sent, because the host would reject it as a bad query.
  /// Returns a [SearchOutcome] for every transport/server failure; only a
  /// locally invalid argument throws.
  Future<SearchOutcome> searchMessages(
    String query, {
    int limit = 50,
    String? senderId,
    MessageKind? kind,
    DateTime? from,
    DateTime? to,
    String type = _type,
    bool retryAuthentication = true,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || trimmed.length > maxQueryLength) {
      throw const FormatException('搜索关键词无效');
    }
    if (limit < 1 || limit > maxLimit) {
      throw const FormatException('搜索条数参数无效');
    }
    if (type != _type) {
      throw const FormatException('搜索类型不受支持');
    }
    final parameters = <String, String>{
      'q': trimmed,
      'type': _type,
      'limit': '$limit',
    };
    if (senderId != null) {
      try {
        parameters['senderId'] = validateId(senderId, kind: 'account');
      } on FormatException {
        throw const FormatException('搜索发送者参数无效');
      }
    }
    if (kind != null) parameters['kind'] = kind.wire;
    if (from != null) parameters['from'] = from.toUtc().toIso8601String();
    if (to != null) parameters['to'] = to.toUtc().toIso8601String();

    final Map<String, Object?> json;
    try {
      json = await connection.request(
        'GET',
        Routes.search,
        query: parameters,
        retryAuthentication: retryAuthentication,
      );
    } on HostRequestException catch (error) {
      return switch (error.failure.code) {
        FailureCode.unauthenticated ||
        FailureCode.forbidden => const SearchUnauthenticated(),
        _ => const SearchUnavailable(),
      };
    } on SocketException {
      return const SearchUnavailable();
    } on HttpException {
      return const SearchUnavailable();
    } on TimeoutException {
      return const SearchUnavailable();
    } on FormatException {
      return const SearchMalformed();
    }
    try {
      if (json.length != 1 || !json.containsKey('hits')) {
        throw const FormatException('搜索响应无效');
      }
      final rows = json['hits'];
      if (rows is! List) throw const FormatException('搜索响应无效');
      return SearchLoaded(
        List<SearchHit>.unmodifiable(rows.map(SearchHit.fromJson)),
      );
    } on FormatException {
      return const SearchMalformed();
    }
  }
}
