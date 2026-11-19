import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

/// HTTP adapter for the currently implemented host routes. WebSocket frames use
/// the shared strict codec, while HTTP sync is retained when stream is absent.
class HostConnection {
  HostConnection(this.base, this._token, {this.onUnauthorized});
  final Uri base;
  String _token;
  final Future<bool> Function()? onUnauthorized;
  void updateAccessToken(String token) {
    _token = token;
  }

  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  WebSocket? socket;
  Uri route(String path, [Map<String, String>? query]) =>
      base.replace(path: path, queryParameters: query, fragment: '');
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    // Opt in only for routes whose successful response has no JSON entity.
    bool allowEmptySuccess = false,
  }) async {
    final decoded = await _requestJson(
      method,
      path,
      body: body,
      query: query,
      retryAuthentication: retryAuthentication,
      allowEmptySuccess: allowEmptySuccess,
    );
    if (decoded is! Map<String, dynamic>) throw const FormatException('宿主响应无效');
    return decoded.cast<String, Object?>();
  }

  Future<List<Object?>> requestList(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
  }) async {
    final decoded = await _requestJson(
      method,
      path,
      body: body,
      query: query,
      retryAuthentication: retryAuthentication,
    );
    if (decoded is! List) throw const FormatException('宿主列表响应无效');
    return List<Object?>.unmodifiable(decoded);
  }

  Future<Object?> _requestJson(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    final attemptedToken = _token;
    final req = await client
        .openUrl(method, route(path, query))
        .timeout(const Duration(seconds: 15));
    req.followRedirects = false;
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $attemptedToken');
    req.headers.contentType = ContentType.json;
    if (body != null) req.write(jsonEncode(body));
    final response = await req.close().timeout(const Duration(seconds: 15));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 15));
    var renewalFailed = false;
    if (response.statusCode == 401 &&
        retryAuthentication &&
        onUnauthorized != null) {
      final renewed = _token != attemptedToken || await onUnauthorized!();
      renewalFailed = !renewed;
      if (renewed) {
        return _requestJson(
          method,
          path,
          body: body,
          query: query,
          retryAuthentication: false,
          allowEmptySuccess: allowEmptySuccess,
        );
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      ErrorCode? code;
      try {
        final body = jsonDecode(text);
        if (body is Map && body['error'] is String) {
          final parsed = ErrorCode.tryParse(body['error'] as String);
          if (parsed?.httpStatus == response.statusCode) code = parsed;
        }
      } on FormatException {
        // A proxy may return HTML; retain the HTTP failure classification.
      }
      final failureCode = code == null
          ? switch (response.statusCode) {
              400 => FailureCode.invalidArgument,
              401 => FailureCode.unauthenticated,
              403 => FailureCode.forbidden,
              404 => FailureCode.notFound,
              409 => FailureCode.conflict,
              429 => FailureCode.rateLimited,
              _ => FailureCode.unavailable,
            }
          : FailureCode.values.byName(code.name);
      throw HostRequestException(
        Failure(
          failureCode,
          '宿主请求失败 (${response.statusCode})',
          details: renewalFailed && failureCode == FailureCode.unauthenticated
              ? const {'authenticationRenewalFailed': true}
              : const {},
        ),
      );
    }
    if (allowEmptySuccess && text.isEmpty) return <String, Object?>{};
    return jsonDecode(text);
  }

  Future<Result<void>> submit(OutboxSubmission item) async {
    try {
      await request(
        'POST',
        Routes.messages.replaceAll(
          '{conversationId}',
          Uri.encodeComponent(item.conversationId),
        ),
        body: item.payload,
      );
      return const Ok(null);
    } on HostRequestException catch (error) {
      if (error.failure.code == FailureCode.unauthenticated) {
        return const Err(Failure(FailureCode.unavailable, '需要重新验证登录，消息保留待发送'));
      }
      return Err(error.failure);
    } on HttpException {
      return const Err(Failure(FailureCode.unavailable, '宿主暂不可用'));
    } on SocketException {
      return const Err(Failure(FailureCode.unavailable, '离线'));
    } on FormatException {
      return const Err(Failure(FailureCode.internal, '宿主响应无效'));
    }
  }

  MessageEventFrame decodeMessage(Map<String, Object?> payload) {
    final decoded = decodeFrameMap({
      'v': protocolVersion,
      'type': FrameType.messageEvent.wire,
      'id': payload['messageId'],
      'at': payload['sentAt'],
      'payload': payload,
    });
    if (!decoded.isOk || decoded.value is! MessageEventFrame) {
      throw const FormatException('消息响应无效');
    }
    return decoded.value as MessageEventFrame;
  }

  /// Validate each page before applying its authorized floor or any rows.
  /// Legacy hosts can omit the floor; they still have to send contiguous rows.
  Future<void> sync(
    SyncRequestFrame frame,
    Future<void> Function(MessageEventFrame) accept, {
    Future<void> Function(int firstVisibleSeq)? applyHistoryFloor,
    void Function()? checkActive,
  }) async {
    var after = frame.afterSeq;
    while (true) {
      checkActive?.call();
      final page = await request(
        'GET',
        Routes.sync.replaceAll(
          '{conversationId}',
          Uri.encodeComponent(frame.conversationId),
        ),
        query: {'afterSeq': '$after'},
      );
      checkActive?.call();
      final floor = page['firstVisibleSeq'];
      final rows = page['messages'];
      final hasMore = page['hasMore'];
      if ((page.containsKey('firstVisibleSeq') && (floor is! int || floor < 1)) ||
          rows is! List ||
          hasMore is! bool ||
          (hasMore && rows.isEmpty)) {
        throw const FormatException('差集响应无效');
      }

      var next = after;
      if (floor is int && applyHistoryFloor != null && floor - 1 > next) {
        next = floor - 1;
      }
      final messages = <MessageEventFrame>[];
      for (final row in rows) {
        if (row is! Map<String, Object?>) {
          throw const FormatException('消息响应无效');
        }
        final message = decodeMessage(row);
        if (message.conversationId != frame.conversationId ||
            message.seq <= next ||
            message.seq != next + 1) {
          throw const FormatException('差集会话或序号不匹配');
        }
        // Parsed numeric overflow can be non-finite; the snapshot cannot
        // encode it. Reject the entire page before applying its floor or rows.
        try {
          jsonEncode(message.body);
        } on JsonUnsupportedObjectError {
          throw const FormatException('消息正文无效');
        }
        messages.add(message);
        next = message.seq;
      }
      if (floor is int && applyHistoryFloor != null) {
        await applyHistoryFloor(floor);
      }
      for (final message in messages) {
        await accept(message);
      }
      if (!hasMore) return;
      after = next;
    }
  }

  Future<void> connectStream(
    void Function(Frame) receive,
    void Function() disconnected,
  ) async {
    final uri = route(Routes.stream)
        .replace(scheme: base.scheme == 'https' ? 'wss' : 'ws');
    socket = await WebSocket.connect(
      uri.toString(),
      headers: {HttpHeaders.authorizationHeader: 'Bearer $_token'},
    ).timeout(const Duration(seconds: 10));
    socket!.pingInterval = const Duration(seconds: 20);
    socket!.listen(
      (raw) {
        if (raw is String) {
          final result = decodeFrame(raw);
          if (result.isOk) receive(result.value);
        }
      },
      onDone: disconnected,
      onError: (Object _) => disconnected(),
    );
  }

  Future<void> close() async {
    await socket?.close();
    client.close(force: true);
  }
}

class HostRequestException implements Exception {
  const HostRequestException(this.failure);
  final Failure failure;
  @override
  String toString() => failure.message;
}

class OutboxSubmission {
  const OutboxSubmission(this.conversationId, this.payload);
  final String conversationId;
  final Map<String, Object?> payload;
}
