/// 客户端本地消息缓存（纯 Dart、UI 无关）。
///
/// 外壳传入已经服务端授权的同步数据；本包不替代服务端权限检查。按账号隔离，
/// 每个会话内按 seq 有序保存，支持编辑覆盖与不可由旧消息复活的撤回占位。
/// 持久化由外壳用平台密钥加密落盘；本包仅提供内存结构与版本化 JSON 快照。
library;

import 'dart:collection';

import 'package:jingyu_core/jingyu_core.dart';

/// 一条不可变的本地消息。正文必须是 JSON 数据，且深复制后只读。
class CachedMessage {
  CachedMessage({
    required this.messageId,
    required this.conversationId,
    required this.seq,
    required this.senderId,
    required this.kind,
    required Map<String, Object?> body,
    required this.sentAt,
    this.recalled = false,
  }) : body = recalled
           ? const <String, Object?>{'recalled': true}
           : _freezeMap(body);

  final String messageId;
  final String conversationId;
  final int seq;
  final String senderId;
  final String kind;
  final Map<String, Object?> body;
  final DateTime sentAt;
  final bool recalled;

  Map<String, Object?> toJson() => {
    'messageId': messageId,
    'conversationId': conversationId,
    'seq': seq,
    'senderId': senderId,
    'kind': kind,
    'body': body,
    'sentAt': sentAt.toUtc().toIso8601String(),
    'recalled': recalled,
  };

  /// 返回 null 表示快照条目损坏，绝不把非字符串 key 强转成字符串。
  static CachedMessage? fromJson(Map<Object?, Object?> raw) {
    final messageId = raw['messageId'];
    final conversationId = raw['conversationId'];
    final seq = raw['seq'];
    final senderId = raw['senderId'];
    final kind = raw['kind'];
    final body = raw['body'];
    final sentAt = raw['sentAt'];
    final recalled = raw['recalled'];
    if (messageId is! String ||
        conversationId is! String ||
        seq is! int ||
        seq <= 0 ||
        senderId is! String ||
        kind is! String ||
        kind.isEmpty ||
        body is! Map ||
        sentAt is! String ||
        recalled is! bool) {
      return null;
    }
    final parsedAt = DateTime.tryParse(sentAt);
    if (parsedAt == null) return null;
    try {
      validateId(messageId, kind: 'message');
      validateId(conversationId, kind: 'conversation');
      validateId(senderId, kind: 'account');
      return CachedMessage(
        messageId: messageId,
        conversationId: conversationId,
        seq: seq,
        senderId: senderId,
        kind: kind,
        body: _freezeMap(body),
        sentAt: parsedAt,
        recalled: recalled,
      );
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}

Map<String, Object?> _freezeMap(Map<Object?, Object?> source) {
  final result = <String, Object?>{};
  for (final entry in source.entries) {
    final key = entry.key;
    if (key is! String) throw ArgumentError('Body keys must be strings');
    result[key] = _freezeValue(entry.value);
  }
  return Map<String, Object?>.unmodifiable(result);
}

Object? _freezeValue(Object? value) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is Map) return _freezeMap(value);
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeValue));
  }
  throw ArgumentError('Body values must be finite JSON data');
}

/// 按账号、会话、seq 组织的本地消息缓存。
///
/// 没有服务端版本号时，普通编辑按调用顺序应用；撤回是终态，旧同步页不能复活正文。
/// 最大 seq 不代表连续同步游标（缺口检测由 SyncCursor 负责）。
class LocalMessageCache {
  final Map<String, Map<String, SplayTreeMap<int, CachedMessage>>> _data = {};

  /// 同一消息同 seq 覆盖正文（编辑），返回是否为新 seq。
  /// 无效标识、非正 seq 或冲突的身份会抛出 ArgumentError，且不会修改缓存。
  bool upsert(String accountId, CachedMessage message) {
    try {
      validateId(accountId, kind: 'account');
      validateId(message.messageId, kind: 'message');
      validateId(message.conversationId, kind: 'conversation');
      validateId(message.senderId, kind: 'account');
    } on FormatException {
      throw ArgumentError('Invalid message identity');
    }
    if (message.seq <= 0 || message.kind.isEmpty) {
      throw ArgumentError(
        'Message sequence must be positive and kind nonempty',
      );
    }
    final conversations = _data[accountId];
    final bySeq = conversations?[message.conversationId];
    final existing = bySeq?[message.seq];
    if (existing != null &&
        (existing.messageId != message.messageId ||
            existing.senderId != message.senderId ||
            existing.kind != message.kind ||
            !existing.sentAt.isAtSameMomentAs(message.sentAt))) {
      throw ArgumentError('Sequence already belongs to a different message');
    }
    // Message IDs are unique across conversations within one account snapshot.
    if (conversations != null) {
      for (final conversation in conversations.values) {
        for (final cached in conversation.values) {
          if (cached.messageId == message.messageId &&
              (cached.seq != message.seq ||
                  cached.conversationId != message.conversationId)) {
            throw ArgumentError('Message identity cannot move');
          }
        }
      }
    }
    if (existing?.recalled == true) return false;
    final target = _data
        .putIfAbsent(accountId, () => {})
        .putIfAbsent(
          message.conversationId,
          () => SplayTreeMap<int, CachedMessage>(),
        );
    target[message.seq] = message;
    return existing == null;
  }

  /// 撤回已缓存的消息：保留 seq，占位正文；重复撤回无副作用。
  /// 尚未缓存的 messageId 不产生新消息。
  void applyRecall(String accountId, String conversationId, String messageId) {
    final bySeq = _data[accountId]?[conversationId];
    if (bySeq == null) return;
    CachedMessage? found;
    for (final message in bySeq.values) {
      if (message.messageId == messageId) {
        found = message;
        break;
      }
    }
    if (found == null || found.recalled) return;
    bySeq[found.seq] = CachedMessage(
      messageId: found.messageId,
      conversationId: found.conversationId,
      seq: found.seq,
      senderId: found.senderId,
      kind: found.kind,
      body: const {},
      sentAt: found.sentAt,
      recalled: true,
    );
  }

  /// seq > afterSeq 的消息，按 seq 升序，最多 limit 条。正文为深度只读值。
  List<CachedMessage> list(
    String accountId,
    String conversationId, {
    int afterSeq = 0,
    int limit = 200,
  }) {
    final bySeq = _data[accountId]?[conversationId];
    if (bySeq == null || limit <= 0) return const <CachedMessage>[];
    return bySeq.values
        .where((message) => message.seq > afterSeq)
        .take(limit)
        .toList(growable: false);
  }

  /// 已知最大 seq；不是连续确认游标。无消息返回 0。
  int headSeq(String accountId, String conversationId) =>
      _data[accountId]?[conversationId]?.lastKey() ?? 0;

  void clearConversation(String accountId, String conversationId) {
    final conversations = _data[accountId];
    if (conversations == null) return;
    conversations.remove(conversationId);
    if (conversations.isEmpty) _data.remove(accountId);
  }

  void clearAccount(String accountId) => _data.remove(accountId);

  Map<String, Object?> exportAccount(String accountId) => {
    'version': 1,
    'messages': [
      for (final conversation
          in _data[accountId]?.values ?? <SplayTreeMap<int, CachedMessage>>[])
        for (final message in conversation.values) message.toJson(),
    ],
  };

  /// 验证整份快照后原子替换账号缓存。损坏/未知版本抛 FormatException，原数据不动。
  void importAccount(String accountId, Map<String, Object?> snapshot) {
    final rawMessages = snapshot['messages'];
    if (snapshot['version'] != 1 || rawMessages is! List) {
      throw const FormatException('Unsupported or invalid cache snapshot');
    }
    final staged = LocalMessageCache();
    final seen = <String>{};
    try {
      validateId(accountId, kind: 'account');
      for (final raw in rawMessages) {
        if (raw is! Map<Object?, Object?>) {
          throw const FormatException('Invalid cache message');
        }
        final message = CachedMessage.fromJson(raw);
        if (message == null || !seen.add(message.messageId)) {
          throw const FormatException('Invalid or duplicate cache message');
        }
        staged.upsert(accountId, message);
      }
      // Existing tombstones survive restoring an older snapshot. Explicit
      // clearAccount/clearConversation remains the intentional purge boundary.
      for (final conversation
          in _data[accountId]?.values ?? <SplayTreeMap<int, CachedMessage>>[]) {
        for (final message in conversation.values) {
          if (message.recalled) staged.upsert(accountId, message);
        }
      }
    } on ArgumentError {
      throw const FormatException('Conflicting cache message identity');
    }
    final replacement = staged._data[accountId];
    if (replacement == null) {
      clearAccount(accountId);
    } else {
      _data[accountId] = replacement;
    }
  }
}
