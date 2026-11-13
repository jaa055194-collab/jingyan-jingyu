/// 线协议帧定义。
///
/// 约定：
/// * 每个帧都带 `id`（幂等键/请求号）与 `at`（发送时刻），服务端据此回执；
/// * 客户端上行消息必须带 `clientMsgId`，服务端按它去重（FR-14）；
/// * 消息序号 `seq` 由服务端单调分配，客户端只读。
library;

import 'package:jingyu_core/jingyu_core.dart';

import 'error_codes.dart';

/// 信封版本。破坏性变更时递增，并保留旧版解析器一个版本周期。
const int protocolVersion = 1;

/// 帧类型。
enum FrameType {
  hello('hello'),
  ready('ready'),
  ping('ping'),
  pong('pong'),
  sendMessage('message.send'),
  messageEvent('message.event'),
  ack('message.ack'),
  syncRequest('sync.request'),
  syncChunk('sync.chunk'),
  error('error');

  const FrameType(this.wire);

  final String wire;

  static FrameType? tryParse(String wire) {
    for (final type in FrameType.values) {
      if (type.wire == wire) return type;
    }
    return null;
  }
}

/// 所有帧的父类型。
sealed class Frame {
  const Frame({
    required this.id,
    required this.at,
  });

  /// 帧标识：请求号或事件号，用于关联回执与排查。
  final String id;

  /// 发送时刻（UTC）。
  final DateTime at;

  /// 帧类型。
  FrameType get type;

  /// 载荷（不含信封字段）。
  Map<String, Object?> payload();

  /// 完整信封。
  Map<String, Object?> toEnvelope() => {
        'v': protocolVersion,
        'type': type.wire,
        'id': id,
        'at': at.toUtc().toIso8601String(),
        'payload': payload(),
      };
}

/// 客户端建立连接时的握手。
class HelloFrame extends Frame {
  const HelloFrame({
    required super.id,
    required super.at,
    required this.deviceId,
    required this.accountId,
    this.lastSeq = const <String, int>{},
  });

  final String deviceId;
  final String accountId;

  /// 每会话已知的最大序号，用于断线后拉差集。
  final Map<String, int> lastSeq;

  @override
  FrameType get type => FrameType.hello;

  @override
  Map<String, Object?> payload() => {
        'deviceId': deviceId,
        'accountId': accountId,
        'lastSeq': lastSeq,
      };
}

/// 服务端握手确认。
class ReadyFrame extends Frame {
  const ReadyFrame({
    required super.id,
    required super.at,
    required this.serverTime,
    required this.hostVersion,
  });

  final DateTime serverTime;
  final String hostVersion;

  @override
  FrameType get type => FrameType.ready;

  @override
  Map<String, Object?> payload() => {
        'serverTime': serverTime.toUtc().toIso8601String(),
        'hostVersion': hostVersion,
      };
}

/// 心跳。
class PingFrame extends Frame {
  const PingFrame({required super.id, required super.at});

  @override
  FrameType get type => FrameType.ping;

  @override
  Map<String, Object?> payload() => const <String, Object?>{};
}

/// 心跳回执。
class PongFrame extends Frame {
  const PongFrame({required super.id, required super.at});

  @override
  FrameType get type => FrameType.pong;

  @override
  Map<String, Object?> payload() => const <String, Object?>{};
}

/// 消息种类。
enum MessageKind {
  text('text'),
  image('image'),
  file('file'),
  audio('audio'),
  generatedImage('generated_image'),
  card('card');

  const MessageKind(this.wire);

  final String wire;

  static MessageKind? tryParse(String wire) {
    for (final kind in MessageKind.values) {
      if (kind.wire == wire) return kind;
    }
    return null;
  }
}

/// 客户端提交消息。
class SendMessageFrame extends Frame {
  const SendMessageFrame({
    required super.id,
    required super.at,
    required this.conversationId,
    required this.clientMsgId,
    required this.kind,
    required this.body,
  });

  final String conversationId;

  /// 客户端生成的幂等键。
  final String clientMsgId;

  final MessageKind kind;

  /// 文本正文或附件引用；具体结构由消息模块定义。
  final Map<String, Object?> body;

  @override
  FrameType get type => FrameType.sendMessage;

  @override
  Map<String, Object?> payload() => {
        'conversationId': conversationId,
        'clientMsgId': clientMsgId,
        'kind': kind.wire,
        'body': body,
      };
}

/// 服务端下发的新消息事件。
class MessageEventFrame extends Frame {
  const MessageEventFrame({
    required super.id,
    required super.at,
    required this.conversationId,
    required this.seq,
    required this.messageId,
    required this.senderId,
    required this.kind,
    required this.body,
    required this.sentAt,
  });

  final String conversationId;

  /// 服务端分配的会话内单调序号。
  final int seq;

  final String messageId;
  final String senderId;
  final MessageKind kind;
  final Map<String, Object?> body;
  final DateTime sentAt;

  @override
  FrameType get type => FrameType.messageEvent;

  @override
  Map<String, Object?> payload() => {
        'conversationId': conversationId,
        'seq': seq,
        'messageId': messageId,
        'senderId': senderId,
        'kind': kind.wire,
        'body': body,
        'sentAt': sentAt.toUtc().toIso8601String(),
      };
}

/// 客户端确认已收到某个序号（按设备维度取最大值，FR-14）。
class AckFrame extends Frame {
  const AckFrame({
    required super.id,
    required super.at,
    required this.conversationId,
    required this.seq,
  });

  final String conversationId;
  final int seq;

  @override
  FrameType get type => FrameType.ack;

  @override
  Map<String, Object?> payload() => {
        'conversationId': conversationId,
        'seq': seq,
      };
}

/// 请求补差集。
class SyncRequestFrame extends Frame {
  const SyncRequestFrame({
    required super.id,
    required super.at,
    required this.conversationId,
    required this.afterSeq,
    this.limit = 200,
  });

  final String conversationId;
  final int afterSeq;
  final int limit;

  @override
  FrameType get type => FrameType.syncRequest;

  @override
  Map<String, Object?> payload() => {
        'conversationId': conversationId,
        'afterSeq': afterSeq,
        'limit': limit,
      };
}

/// 补差集回包。
class SyncChunkFrame extends Frame {
  const SyncChunkFrame({
    required super.id,
    required super.at,
    required this.conversationId,
    required this.messages,
    required this.hasMore,
  });

  final String conversationId;

  /// 每一项为 `MessageEventFrame.payload()` 的结构。
  final List<Map<String, Object?>> messages;

  final bool hasMore;

  @override
  FrameType get type => FrameType.syncChunk;

  @override
  Map<String, Object?> payload() => {
        'conversationId': conversationId,
        'messages': messages,
        'hasMore': hasMore,
      };
}

/// 错误帧。不含正文、路径与 key。
class ErrorFrame extends Frame {
  const ErrorFrame({
    required super.id,
    required super.at,
    required this.code,
    this.requestId,
  });

  final String code;

  /// 出错的请求号，便于双端对账。
  final String? requestId;

  @override
  FrameType get type => FrameType.error;

  @override
  Map<String, Object?> payload() => {
        'code': code,
        if (requestId != null) 'requestId': requestId,
      };
}

/// 便于构造：把领域失败转成错误帧（错误码映射集中在 `error_codes.dart`）。
ErrorFrame errorFrameFrom(
  Failure failure, {
  required String id,
  required DateTime at,
}) =>
    ErrorFrame(
      id: id,
      at: at,
      code: ErrorCode.fromFailure(failure.code).wire,
    );
