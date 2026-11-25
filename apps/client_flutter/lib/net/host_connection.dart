import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  /// One explicit request with a response byte limit and exact HTTP success
  /// status. No redirect, auth renewal or retry; a write may already be applied
  /// when its response fails validation or times out.
  Future<Map<String, Object?>> requestBoundedObject(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    required int maxResponseBytes,
    required int expectedStatus,
    HostReadCancellation? cancellation,
  }) => _getBoundedJson(
    path,
    method: method,
    body: body,
    query: query,
    maxResponseBytes: maxResponseBytes,
    expectedStatus: expectedStatus,
    cancellation: cancellation,
  );

  /// A one-shot GET with a wire-body limit, before UTF-8 or JSON decoding.
  /// Explicit media reads never renew/replay authentication or follow redirects.
  Future<Map<String, Object?>> getBoundedJson(
    String path, {
    required int maxResponseBytes,
    HostReadCancellation? cancellation,
  }) => _getBoundedJson(
    path,
    maxResponseBytes: maxResponseBytes,
    cancellation: cancellation,
  );

  /// The same one-shot bounded read with separately encoded query parameters.
  Future<Map<String, Object?>> getBoundedJsonWithQuery(
    String path, {
    required Map<String, String> query,
    required int maxResponseBytes,
    HostReadCancellation? cancellation,
  }) => _getBoundedJson(
    path,
    query: query,
    maxResponseBytes: maxResponseBytes,
    cancellation: cancellation,
  );

  Future<Map<String, Object?>> _getBoundedJson(
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    Map<String, String>? query,
    required int maxResponseBytes,
    int? expectedStatus,
    HostReadCancellation? cancellation,
  }) async {
    if (maxResponseBytes < 1) {
      throw ArgumentError.value(maxResponseBytes, 'maxResponseBytes');
    }
    final stop = cancellation ?? HostReadCancellation();
    stop._check();
    if (stop._signal != null) throw StateError('Read already started');
    final signal = Completer<void>();
    stop._signal = signal;
    try {
      final decoded =
          await Future.any<Object?>([
            _requestJson(
              method,
              path,
              body: body,
              query: query,
              retryAuthentication: false,
              maxResponseBytes: maxResponseBytes,
              expectedStatus: expectedStatus,
              cancellation: stop,
            ),
            signal.future.then<Object?>(
              (_) => throw HostReadCancellation._error,
            ),
          ]).timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              stop.cancel();
              throw TimeoutException('宿主响应超时');
            },
          );
      stop._check();
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('宿主响应无效');
      }
      return decoded;
    } finally {
      stop._abort = null;
      if (!signal.isCompleted) signal.complete();
    }
  }

  Future<Object?> _requestJson(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
    int? maxResponseBytes,
    int? expectedStatus,
    HostReadCancellation? cancellation,
  }) async {
    final attemptedToken = _token;
    final opening = client.openUrl(method, route(path, query));
    final req = cancellation == null
        ? await opening.timeout(const Duration(seconds: 15))
        : await opening;
    if (cancellation?._cancelled == true) {
      // A cancelled caller may have been waiting for a socket. Abort it
      // without sending the request as soon as Dart hands it to us.
      req.done.ignore();
      req.abort(HostReadCancellation._error);
      throw HostReadCancellation._error;
    }
    req.followRedirects = false;
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $attemptedToken');
    req.headers.contentType = ContentType.json;
    if (cancellation != null) {
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      cancellation._abort = () => req.abort(HostReadCancellation._error);
    }
    if (body != null) req.write(jsonEncode(body));
    final closing = req.close();
    final response = cancellation == null
        ? await closing.timeout(const Duration(seconds: 15))
        : await closing;
    final text = maxResponseBytes == null
        ? await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 15))
        : await _boundedText(response, maxResponseBytes, cancellation!);
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
    if (expectedStatus != null && response.statusCode != expectedStatus) {
      throw const FormatException('宿主响应状态未知');
    }
    if (allowEmptySuccess && text.isEmpty) return <String, Object?>{};
    return jsonDecode(text);
  }

  static Future<String> _boundedText(
    HttpClientResponse response,
    int limit,
    HostReadCancellation stop,
  ) async {
    // Do not accept compressed bodies: checking Content-Length alone would
    // not bound the bytes the decoder actually receives.
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    if (stop._cancelled ||
        response.contentLength > limit ||
        (encoding != null && encoding.toLowerCase() != 'identity')) {
      await response.listen(null).cancel();
      stop._check();
      throw const FormatException('宿主响应过大或编码不受支持');
    }
    final chunks = StreamIterator<List<int>>(response);
    stop._abort = () => chunks.cancel().ignore();
    final body = BytesBuilder(copy: false);
    try {
      while (await chunks.moveNext()) {
        stop._check();
        final chunk = chunks.current;
        if (chunk.length > limit - body.length) {
          throw const FormatException('宿主响应过大');
        }
        body.add(chunk);
      }
      stop._check();
      return utf8.decode(body.takeBytes());
    } finally {
      await chunks.cancel();
    }
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
      if ((page.containsKey('firstVisibleSeq') &&
              (floor is! int || floor < 1)) ||
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

/// Cancels one bounded read without closing the rest of the host session.
class HostReadCancellation {
  static const _error = HttpException('读取已取消');
  Completer<void>? _signal;
  void Function()? _abort;
  bool _cancelled = false;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _abort?.call();
    final signal = _signal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  void _check() {
    if (_cancelled) throw _error;
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
