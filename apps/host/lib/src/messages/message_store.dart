/// 消息内核：会话内单调 seq、client_msg_id 幂等、差集同步（FR-14、AC-18）。
///
/// 这里给出接口与内存实现。持久化实现（SQLite）必须通过同一组契约测试
/// `test/message_store_contract.dart`，见 docs/modules/M03-messages.md。
library;

import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

/// 已存储的消息。
class StoredMessage {
  const StoredMessage({
    required this.conversationId,
    required this.seq,
    required this.messageId,
    required this.senderId,
    required this.clientMsgId,
    required this.kind,
    required this.body,
    required this.sentAt,
  });

  final String conversationId;
  final int seq;
  final String messageId;
  final String senderId;
  final String clientMsgId;
  final MessageKind kind;
  final Map<String, Object?> body;
  final DateTime sentAt;

  /// 下发给客户端的载荷（与 MessageEventFrame.payload 同构）。
  Map<String, Object?> toPayload() => {
    'conversationId': conversationId,
    'seq': seq,
    'messageId': messageId,
    'senderId': senderId,
    'kind': kind.wire,
    'body': body,
    'sentAt': sentAt.toUtc().toIso8601String(),
  };
}

/// 追加结果：[duplicate] 为 true 表示命中幂等，返回的是首次写入的那条。
class AppendResult {
  const AppendResult(this.message, {required this.duplicate});

  final StoredMessage message;
  final bool duplicate;
}

/// 差集一页。
class SyncPage {
  const SyncPage(this.messages, {required this.hasMore});

  final List<StoredMessage> messages;
  final bool hasMore;
}

/// 一条编辑历史版本（旧正文加密存储）。
class EditVersion {
  const EditVersion({
    required this.editId,
    required this.messageId,
    required this.editorId,
    required this.body,
    required this.editedAt,
  });

  final String editId;
  final String messageId;
  final String editorId;
  final Map<String, Object?> body;
  final DateTime editedAt;
}

/// 编辑结果：新消息与本次产生的旧版本 id（审计只存该 id）。
class EditResult {
  const EditResult(this.message, this.editId);

  final StoredMessage message;
  final String editId;
}

/// 消息存储契约。
abstract class MessageStore {
  /// 追加消息。同一 (conversationId, senderId, clientMsgId) 只写一次。
  Future<Result<AppendResult>> append({
    required String conversationId,
    required String senderId,
    required String clientMsgId,
    required MessageKind kind,
    required Map<String, Object?> body,
  });

  /// 取 seq > [afterSeq] 的消息，按 seq 升序，最多 [limit] 条。
  Future<Result<SyncPage>> since({
    required String conversationId,
    required int afterSeq,
    int limit = 200,
  });

  /// 记录设备已读位点，只前进不后退（按设备取最大值）。
  Future<int> ack({
    required String conversationId,
    required String deviceId,
    required int seq,
  });

  /// 会话当前最大 seq。
  Future<int> headSeq(String conversationId);

  /// 撤回自己的消息：仅发送者、24 小时内、未撤回时成功。
  /// 成功后正文替换为 `{"recalled": true}` 占位，seq 保持不变（留痕与分页稳定）。
  Future<Result<void>> recall({
    required String conversationId,
    required String messageId,
    required String senderId,
  });

  /// 编辑自己的未撤回消息：旧正文写入加密编辑历史，返回新消息与旧版本 id。
  Future<Result<EditResult>> edit({
    required String conversationId,
    required String messageId,
    required String senderId,
    required Map<String, Object?> body,
  });

  /// 读取某消息的编辑历史（仅供管理员路由使用）。
  Future<Result<List<EditVersion>>> editHistory({
    required String conversationId,
    required String messageId,
  });
}

/// 内存实现。
class InMemoryMessageStore implements MessageStore {
  InMemoryMessageStore({
    this.clock = const SystemClock(),
    String Function()? newId,
  }) : _newId = newId ?? _counterIds();

  final Clock clock;
  final String Function() _newId;

  final Map<String, List<StoredMessage>> _byConversation = {};
  final Map<String, StoredMessage> _byIdempotencyKey = {};
  final Map<String, int> _acks = {};
  final Set<String> _recalled = {};
  final Map<String, List<EditVersion>> _edits = {};

  static String Function() _counterIds() {
    var n = 0;
    return () => 'm${++n}';
  }

  @override
  Future<Result<AppendResult>> append({
    required String conversationId,
    required String senderId,
    required String clientMsgId,
    required MessageKind kind,
    required Map<String, Object?> body,
  }) async {
    if (clientMsgId.isEmpty || clientMsgId.length > 64) {
      return err(FailureCode.invalidArgument, 'clientMsgId 长度必须为 1–64');
    }
    final key = '$conversationId|$senderId|$clientMsgId';
    final existing = _byIdempotencyKey[key];
    if (existing != null) return Ok(AppendResult(existing, duplicate: true));

    final list = _byConversation.putIfAbsent(conversationId, () => []);
    final message = StoredMessage(
      conversationId: conversationId,
      seq: list.length + 1,
      messageId: _newId(),
      senderId: senderId,
      clientMsgId: clientMsgId,
      kind: kind,
      body: Map.unmodifiable(body),
      sentAt: clock.now().toUtc(),
    );
    list.add(message);
    _byIdempotencyKey[key] = message;
    return Ok(AppendResult(message, duplicate: false));
  }

  @override
  Future<Result<SyncPage>> since({
    required String conversationId,
    required int afterSeq,
    int limit = 200,
  }) async {
    if (afterSeq < 0) return err(FailureCode.invalidArgument, 'afterSeq 不能为负');
    if (limit <= 0 || limit > 1000) {
      return err(FailureCode.invalidArgument, 'limit 必须在 1–1000');
    }
    final list = _byConversation[conversationId] ?? const <StoredMessage>[];
    final tail = list.where((m) => m.seq > afterSeq).toList();
    return Ok(
      SyncPage(tail.take(limit).toList(), hasMore: tail.length > limit),
    );
  }

  @override
  Future<int> ack({
    required String conversationId,
    required String deviceId,
    required int seq,
  }) async {
    final key = '$conversationId|$deviceId';
    final head = await headSeq(conversationId);
    final clamped = seq > head ? head : seq;
    final current = _acks[key] ?? 0;
    final next = clamped > current ? clamped : current;
    _acks[key] = next;
    return next;
  }

  @override
  Future<int> headSeq(String conversationId) async =>
      _byConversation[conversationId]?.length ?? 0;

  @override
  Future<Result<void>> recall({
    required String conversationId,
    required String messageId,
    required String senderId,
  }) async {
    final list = _byConversation[conversationId];
    final index = list == null
        ? -1
        : list.indexWhere((m) => m.messageId == messageId);
    if (index < 0) return err(FailureCode.notFound, 'message not found');
    final message = list![index];
    if (message.senderId != senderId) {
      return err(FailureCode.forbidden, 'only the sender can recall');
    }
    if (clock.now().toUtc().difference(message.sentAt) >
        const Duration(hours: 24)) {
      return err(FailureCode.forbidden, 'recall window expired');
    }
    if (_recalled.contains(messageId)) {
      return err(FailureCode.invalidArgument, 'already recalled');
    }
    final tombstone = StoredMessage(
      conversationId: message.conversationId,
      seq: message.seq,
      messageId: message.messageId,
      senderId: message.senderId,
      clientMsgId: message.clientMsgId,
      kind: message.kind,
      body: Map<String, Object?>.unmodifiable({'recalled': true}),
      sentAt: message.sentAt,
    );
    list[index] = tombstone;
    _recalled.add(messageId);
    _byIdempotencyKey['$conversationId|$senderId|${message.clientMsgId}'] =
        tombstone;
    return const Ok(null);
  }

  @override
  Future<Result<EditResult>> edit({
    required String conversationId,
    required String messageId,
    required String senderId,
    required Map<String, Object?> body,
  }) async {
    final list = _byConversation[conversationId];
    final index = list == null
        ? -1
        : list.indexWhere((m) => m.messageId == messageId);
    if (index < 0) return err(FailureCode.notFound, 'message not found');
    final message = list![index];
    if (message.senderId != senderId) {
      return err(FailureCode.forbidden, 'only the sender can edit');
    }
    if (_recalled.contains(messageId)) {
      return err(
        FailureCode.invalidArgument,
        'recalled message cannot be edited',
      );
    }
    final String encoded;
    try {
      encoded = jsonEncode(body);
    } on JsonUnsupportedObjectError {
      return err(FailureCode.invalidArgument, 'Body must be a JSON object');
    }
    final editId = _newId();
    final editedAt = clock.now().toUtc();
    _edits
        .putIfAbsent(messageId, () => [])
        .add(
          EditVersion(
            editId: editId,
            messageId: messageId,
            editorId: senderId,
            body: message.body,
            editedAt: editedAt,
          ),
        );
    final updated = StoredMessage(
      conversationId: message.conversationId,
      seq: message.seq,
      messageId: message.messageId,
      senderId: message.senderId,
      clientMsgId: message.clientMsgId,
      kind: message.kind,
      body: Map<String, Object?>.unmodifiable(
        jsonDecode(encoded) as Map<String, dynamic>,
      ),
      sentAt: message.sentAt,
    );
    list[index] = updated;
    _byIdempotencyKey['$conversationId|$senderId|${message.clientMsgId}'] =
        updated;
    return Ok(EditResult(updated, editId));
  }

  @override
  Future<Result<List<EditVersion>>> editHistory({
    required String conversationId,
    required String messageId,
  }) async => Ok(List<EditVersion>.unmodifiable(_edits[messageId] ?? const []));
}
