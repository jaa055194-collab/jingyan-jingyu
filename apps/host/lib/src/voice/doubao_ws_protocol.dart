/// 豆包（火山引擎）双向流式 TTS WebSocket 二进制帧编解码。
///
/// 说明：本机文档只给出 JSON 事件样例，二进制帧附件的官方布局无法在此核对。
/// 这里按 openspeech v3 的**已知约定**实现（4 字节头 + 可选 4 字节事件 id +
/// 4 字节 session 长度/内容 + 4 字节 payload 长度/内容；音频帧只带 payload）。
/// 真实厂商联调需待官方附件/参数补齐后才能确认，本切片不声称已与真实豆包连通。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 帧消息类型（protocol version 1）。
abstract final class DoubaoMessageType {
  static const int fullClientRequest = 0x1;
  static const int audioOnlyRequest = 0x2;
  static const int fullServerResponse = 0x9;
  static const int audioOnlyResponse = 0xB;
  static const int error = 0xF;
}

/// 双向流式事件 id（文档事件名对应）。
abstract final class DoubaoEvent {
  static const int startConnection = 1;
  static const int finishConnection = 2;
  static const int connectionStarted = 50;
  static const int connectionFailed = 51;
  static const int connectionFinished = 52;
  static const int startSession = 100;
  static const int cancelSession = 101;
  static const int finishSession = 102;
  static const int sessionStarted = 150;
  static const int sessionFinished = 152;
  static const int sessionFailed = 153;
  static const int sessionCanceled = 154;
  static const int taskRequest = 200;
  static const int ttsSentenceStart = 350;
  static const int ttsSentenceEnd = 351;
  static const int ttsResponse = 352;
  static const int ttsSubtitle = 353;
}

/// 解出的一帧。
class DoubaoFrame {
  const DoubaoFrame({
    required this.messageType,
    required this.eventType,
    required this.sessionId,
    required this.payload,
    this.errorCode,
  });

  final int messageType;
  final int eventType;
  final String sessionId;
  final Uint8List payload;
  final int? errorCode;

  bool get isError => messageType == DoubaoMessageType.error;
  bool get isAudio => messageType == DoubaoMessageType.audioOnlyResponse;
  bool get isFullResponse =>
      messageType == DoubaoMessageType.fullServerResponse;

  Map<String, Object?> payloadJson() {
    if (payload.isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is! Map) throw const FormatException('payload 不是对象');
    return decoded.cast<String, Object?>();
  }
}

/// 帧编解码（协议假定见文件头注释）。
abstract final class DoubaoBinaryProtocol {
  static const int _version = 1;
  static const int _headerWords = 1;
  static const int _serializationJson = 1;
  static const int _flagsHasEvent = 0x1;

  static Uint8List _i32(int value) {
    final data = ByteData(4)..setInt32(0, value, Endian.big);
    return data.buffer.asUint8List();
  }

  /// 编码一个客户端请求帧（可能携带事件 id / session id / JSON payload）。
  static Uint8List encodeClientEvent({
    required int messageType,
    required int eventType,
    required String sessionId,
    required Map<String, Object?> payload,
  }) {
    final payloadBytes = utf8.encode(jsonEncode(payload));
    final sid = utf8.encode(sessionId);
    final buffer = BytesBuilder(copy: false);
    buffer.addByte((_version << 4) | _headerWords);
    buffer.addByte((messageType << 4) | _flagsHasEvent);
    buffer.addByte((_serializationJson << 4) | 0);
    buffer.addByte(0);
    buffer.add(_i32(eventType));
    buffer.add(_i32(sid.length));
    buffer.add(sid);
    buffer.add(_i32(payloadBytes.length));
    buffer.add(payloadBytes);
    return buffer.takeBytes();
  }

  /// 解码服务端帧（全量响应 / 音频 / 错误）。
  static DoubaoFrame decodeFrame(Uint8List bytes) {
    if (bytes.length < 4) throw const FormatException('帧过短');
    final version = bytes[0] >> 4;
    final headerSize = (bytes[0] & 0x0F) * 4;
    final messageType = bytes[1] >> 4;
    final flags = bytes[1] & 0x0F;
    final serialization = bytes[2] >> 4;
    final compression = bytes[2] & 0x0F;
    if (version != _version || headerSize < 4 || headerSize > bytes.length) {
      throw const FormatException('帧头无效');
    }
    if (compression != 0) throw const FormatException('不支持压缩帧');
    if (serialization != _serializationJson) {
      throw const FormatException('不支持序列化类型');
    }
    final view = ByteData.sublistView(bytes);
    var offset = headerSize;

    Uint8List slice(int length) {
      if (length < 0 || offset + length > bytes.length) {
        throw const FormatException('帧负载长度越界');
      }
      final value = Uint8List.sublistView(bytes, offset, offset + length);
      offset += length;
      return value;
    }

    if (messageType == DoubaoMessageType.error) {
      final code = view.getInt32(offset);
      offset += 4;
      final length = view.getInt32(offset);
      offset += 4;
      return DoubaoFrame(
        messageType: messageType,
        eventType: 0,
        sessionId: '',
        payload: slice(length),
        errorCode: code,
      );
    }
    if (messageType == DoubaoMessageType.audioOnlyResponse) {
      final length = view.getInt32(offset);
      offset += 4;
      return DoubaoFrame(
        messageType: messageType,
        eventType: DoubaoEvent.ttsResponse,
        sessionId: '',
        payload: slice(length),
      );
    }
    var eventType = 0;
    if (flags & _flagsHasEvent == _flagsHasEvent) {
      eventType = view.getInt32(offset);
      offset += 4;
    }
    final sidLength = view.getInt32(offset);
    offset += 4;
    final sessionId = utf8.decode(slice(sidLength));
    final length = view.getInt32(offset);
    offset += 4;
    return DoubaoFrame(
      messageType: messageType,
      eventType: eventType,
      sessionId: sessionId,
      payload: slice(length),
    );
  }
}
