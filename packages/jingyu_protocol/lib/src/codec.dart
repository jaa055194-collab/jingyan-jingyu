/// 严格编解码。
///
/// 原则：**解析失败一律返回 Err**，绝不返回"尽力而为"的半成品。
/// 宽松解析是把串数据缺陷放进系统的常见入口，这里不接受。
library;

import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';

import 'frames.dart';

/// 把帧编码成 JSON 文本。
String encodeFrame(Frame frame) => jsonEncode(frame.toEnvelope());

/// 从 JSON 文本解码帧。
Result<Frame> decodeFrame(String raw) {
  final Object? parsed;
  try {
    parsed = jsonDecode(raw);
  } on FormatException catch (error) {
    return err<Frame>(FailureCode.invalidArgument, 'JSON 解析失败：${error.message}');
  }
  if (parsed is! Map<String, Object?>) {
    return err<Frame>(FailureCode.invalidArgument, '帧必须是 JSON 对象');
  }
  return decodeFrameMap(parsed);
}

/// 从已解析的 Map 解码帧。
Result<Frame> decodeFrameMap(Map<String, Object?> map) {
  final version = map['v'];
  if (version is! int) {
    return err<Frame>(FailureCode.invalidArgument, '缺少协议版本 v');
  }
  if (version != protocolVersion) {
    return err<Frame>(
      FailureCode.invalidArgument,
      '不支持的协议版本 $version（当前 $protocolVersion）',
    );
  }

  final id = _requireString(map, 'id');
  final atRaw = _requireString(map, 'at');
  final typeRaw = _requireString(map, 'type');
  final payloadRaw = map['payload'];

  if (id is Err<String>) return Err<Frame>(id.failure);
  if (atRaw is Err<String>) return Err<Frame>(atRaw.failure);
  if (typeRaw is Err<String>) return Err<Frame>(typeRaw.failure);
  if (payloadRaw != null && payloadRaw is! Map) {
    return err<Frame>(FailureCode.invalidArgument, 'payload 必须是对象');
  }

  final type = FrameType.tryParse(typeRaw.value);
  if (type == null) {
    return err<Frame>(FailureCode.invalidArgument, '未知帧类型 ${typeRaw.value}');
  }

  final at = DateTime.tryParse(atRaw.value);
  if (at == null) {
    return err<Frame>(FailureCode.invalidArgument, 'at 不是合法时间');
  }

  final payload = <String, Object?>{
    ...?(payloadRaw as Map<String, Object?>?),
  };

  return switch (type) {
    FrameType.hello => _decodeHello(id: id.value, at: at, payload: payload),
    FrameType.ready => _decodeReady(id: id.value, at: at, payload: payload),
    FrameType.ping => Ok<Frame>(PingFrame(id: id.value, at: at)),
    FrameType.pong => Ok<Frame>(PongFrame(id: id.value, at: at)),
    FrameType.sendMessage =>
      _decodeSendMessage(id: id.value, at: at, payload: payload),
    FrameType.messageEvent =>
      _decodeMessageEvent(id: id.value, at: at, payload: payload),
    FrameType.ack => _decodeAck(id: id.value, at: at, payload: payload),
    FrameType.syncRequest =>
      _decodeSyncRequest(id: id.value, at: at, payload: payload),
    FrameType.syncChunk => _decodeSyncChunk(id: id.value, at: at, payload: payload),
    FrameType.error => _decodeError(id: id.value, at: at, payload: payload),
  };
}

Result<String> _requireString(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is String && value.isNotEmpty) return Ok<String>(value);
  return err<String>(FailureCode.invalidArgument, '字段 $key 缺失或不是字符串');
}

Result<T> _requireField<T>(
  Map<String, Object?> payload,
  String key,
  Result<T> Function(Object? value) parse,
) {
  if (!payload.containsKey(key)) {
    return err<T>(FailureCode.invalidArgument, '载荷缺少字段 $key');
  }
  return parse(payload[key]);
}

Result<String> _asString(Object? value, String key) {
  if (value is String) return Ok<String>(value);
  return err<String>(FailureCode.invalidArgument, '字段 $key 必须是字符串');
}

Result<int> _asInt(Object? value, String key) {
  if (value is int) return Ok<int>(value);
  if (value is double && value.isFinite && value == value.roundToDouble()) {
    return Ok<int>(value.toInt());
  }
  return err<int>(FailureCode.invalidArgument, '字段 $key 必须是整数');
}

Result<bool> _asBool(Object? value, String key) {
  if (value is bool) return Ok<bool>(value);
  return err<bool>(FailureCode.invalidArgument, '字段 $key 必须是布尔值');
}

Result<DateTime> _asTime(Object? value, String key) {
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return Ok<DateTime>(parsed);
  }
  return err<DateTime>(FailureCode.invalidArgument, '字段 $key 不是合法时间');
}

Result<Map<String, Object?>> _asMap(Object? value, String key) {
  if (value is Map<String, Object?>) return Ok<Map<String, Object?>>(value);
  if (value is Map) {
    return Ok<Map<String, Object?>>({...value.cast<String, Object?>()});
  }
  return err<Map<String, Object?>>(FailureCode.invalidArgument, '字段 $key 必须是对象');
}

Result<Frame> _decodeHello({
  required String id,
  required DateTime at,
  required Map<String, Object?> payload,
}) {
  final deviceId = _requireField(payload, 'deviceId', (v) => _asString(v, 'deviceId'));
  final accountId =
      _requireField(payload, 'accountId', (v) => _asString(v, 'accountId'));
  if (deviceId is Err<String>) return Err<Frame>(deviceId.failure);
  if (accountId is Err<String>) return Err<Frame>(accountId.failure);

  final lastSeq = <String, int>{};
  final rawSeq = payload['lastSeq'];
  if (rawSeq != null) {
    final asMap = _asMap(rawSeq, 'lastSeq');
    if (asMap is Err<Map<String, Object?>>) return Err<Frame>(asMap.failure);
    for (final entry in asMap.value.entries) {
      final seq = _asInt(entry.value, 'lastSeq.${entry.key}');
      if (seq is Err<int>) return Err<Frame>(seq.failure);
      lastSeq[entry.key] = seq.value;
    }
  }

  return Ok<Frame>(HelloFrame(
    id: id,
    at: at,
    deviceId: deviceId.value,
    accountId: accountId.value,
    lastSeq: lastSeq,
  ));
}

Result<Frame> _decodeReady({
  required String id,
  required DateTime at,
  required Map<String, Object?> payload,
}) {
  final serverTime =
      _requireField(payload, 'serverTime', (v) => _asTime(v, 'serverTime'));
  final hostVersion =
      _requireField(payload, 'hostVersion', (v) => _asString(v, 'hostVersion'));
  if (serverTime is Err<DateTime>) return Err<Frame>(serverTime.failure);
  if (hostVersion is Err<String>) return Err<Frame>(hostVersion.failure);
  return Ok<Frame>(ReadyFrame(
    id: id,
    at: at,
    serverTime: serverTime.value,
    hostVersion: hostVersion.value,
  ));
}

Result<Frame> _decodeSendMessage({
  required String id,
  required DateTime at,
  required Map<String, Object?> payload,
}) {
  final conversationId = _requireField(
      payload, 'conversationId', (v) => _asString(v, 'conversationId'));
  final clientMsgId =
      _requireField(payload, 'clientMsgId', (v) => _asString(v, 'clientMsgId'));
  final kindRaw = _requireField(payload, 'kind', (v) => _asString(v, 'kind'));
  final body = _requireField(payload, 'body', (v) => _asMap(v, 'body'));

  if (conversationId is Err<String>) return Err<Frame>(conversationId.failure);
  if (clientMsgId is Err<String>) return Err<Frame>(clientMsgId.failure);
  if (kindRaw is Err<String>) return Err<Frame>(kindRaw.failure);
  if (body is Err<Map<String, Object?>>) return Err<Frame>(body.failure);

  final kind = MessageKind.tryParse(kindRaw.value);
  if (kind == null) {
    return err<Frame>(FailureCode.invalidArgument, '未知消息类型 ${kindRaw.value}');
  }
  if (clientMsgId.value.length > 64) {
    return err<Frame>(FailureCode.invalidArgument, 'clientMsgId 过长');
  }

  return Ok<Frame>(SendMessageFrame(
    id: id,
    at: at,
    conversationId: conversationId.value,
    clientMsgId: clientMsgId.value,
    kind: kind,
    body: body.value,
  ));
}

Result<Frame> _decodeMessageEvent({
  required String id,
  required DateTime at,
  required Map<String, Object?> payload,
}) {
  final conversationId = _requireField(
      payload, 'conversationId', (v) => _asString(v, 'conversationId'));
  final seq = _requireField(payload, 'seq', (v) => _asInt(v, 'seq'));
  final messageId =
      _requireField(payload, 'messageId', (v) => _asString(v, 'messageId'));
  final senderId =
      _requireField(payload, 'senderId', (v) => _asString(v, 'senderId'));
  final kindRaw = _requireField(payload, 'kind', (v) => _asString(v, 'kind'));
  final body = _requireField(payload, 'body', (v) => _asMap(v, 'body'));
  final sentAt = _requireField(payload, 'sentAt', (v) => _asTime(v, 'sentAt'));

  if (conversationId is Err<String>) return Err<Frame>(conversationId.failure);
  if (seq is Err<int>) return Err<Frame>(seq.failure);
  if (messageId is Err<String>) return Err<Frame>(messageId.failure);
  if (senderId is Err<String>) return Err<Frame>(senderId.failure);
  if (kindRaw is Err<String>) return Err<Frame>(kindRaw.failure);
  if (body is Err<Map<String, Object?>>) return Err<Frame>(body.failure);
  if (sentAt is Err<DateTime>) return Err<Frame>(sentAt.failure);

  final kind = MessageKind.tryParse(kindRaw.value);
  if (kind == null) {
    return err<Frame>(FailureCode.invalidArgument, '未知消息类型 ${kindRaw.value}');
  }

  return Ok<Frame>(MessageEventFrame(
    id: id,
    at: at,
    conversationId: conversationId.value,
    seq: seq.value,
    messageId: messageId.value,
    senderId: senderId.value,
    kind: kind,
    body: body.value,
    sentAt: sentAt.value,
  ));
}

Result<Frame> _decodeAck({
  required String id,
  required DateTime at,
  required Map<String, Object?> payload,
}) {
  final conversationId = _requireField(
      payload, 'conversationId', (v) => _asString(v, 'conversationId'));
  final seq = _requireField(payload, 'seq', (v) => _asInt(v, 'seq'));
  if (conversationId is Err<String>) return Err<Frame>(conversationId.failure);
  if (seq is Err<int>) return Err<Frame>(seq.failure);
  return Ok<Frame>(AckFrame(
    id: id,
    at: at,
    conversationId: conversationId.value,
    seq: seq.value,
  ));
}

Result<Frame> _decodeSyncRequest({
  required String id,
  required DateTime at,
  required Map<String, Object?> payload,
}) {
  final conversationId = _requireField(
      payload, 'conversationId', (v) => _asString(v, 'conversationId'));
  final afterSeq = _requireField(payload, 'afterSeq', (v) => _asInt(v, 'afterSeq'));
  final limit = payload.containsKey('limit')
      ? _asInt(payload['limit'], 'limit')
      : const Ok<int>(200);

  if (conversationId is Err<String>) return Err<Frame>(conversationId.failure);
  if (afterSeq is Err<int>) return Err<Frame>(afterSeq.failure);
  if (limit is Err<int>) return Err<Frame>(limit.failure);
  if (limit.value <= 0 || limit.value > 1000) {
    return err<Frame>(FailureCode.invalidArgument, 'limit 必须在 1–1000');
  }

  return Ok<Frame>(SyncRequestFrame(
    id: id,
    at: at,
    conversationId: conversationId.value,
    afterSeq: afterSeq.value,
    limit: limit.value,
  ));
}

Result<Frame> _decodeSyncChunk({
  required String id,
  required DateTime at,
  required Map<String, Object?> payload,
}) {
  final conversationId = _requireField(
      payload, 'conversationId', (v) => _asString(v, 'conversationId'));
  final hasMore = _requireField(payload, 'hasMore', (v) => _asBool(v, 'hasMore'));
  if (conversationId is Err<String>) return Err<Frame>(conversationId.failure);
  if (hasMore is Err<bool>) return Err<Frame>(hasMore.failure);

  final rawMessages = payload['messages'];
  if (rawMessages is! List) {
    return err<Frame>(FailureCode.invalidArgument, '字段 messages 必须是数组');
  }
  final messages = <Map<String, Object?>>[];
  for (var index = 0; index < rawMessages.length; index++) {
    final item = _asMap(rawMessages[index], 'messages[$index]');
    if (item is Err<Map<String, Object?>>) return Err<Frame>(item.failure);
    messages.add(item.value);
  }

  return Ok<Frame>(SyncChunkFrame(
    id: id,
    at: at,
    conversationId: conversationId.value,
    messages: messages,
    hasMore: hasMore.value,
  ));
}

Result<Frame> _decodeError({
  required String id,
  required DateTime at,
  required Map<String, Object?> payload,
}) {
  final code = _requireField(payload, 'code', (v) => _asString(v, 'code'));
  if (code is Err<String>) return Err<Frame>(code.failure);
  final requestIdRaw = payload['requestId'];
  String? requestId;
  if (requestIdRaw != null) {
    final parsed = _asString(requestIdRaw, 'requestId');
    if (parsed is Err<String>) return Err<Frame>(parsed.failure);
    requestId = parsed.value;
  }
  return Ok<Frame>(ErrorFrame(
    id: id,
    at: at,
    code: code.value,
    requestId: requestId,
  ));
}
