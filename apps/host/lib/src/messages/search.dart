import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../storage/database.dart';
import 'blind_index.dart';
import 'message_store.dart';

/// 全局消息搜索（FR-17 / AC-20 的服务端子集）。
///
/// 正文在库内加密，无法直接建立明文 FTS 索引；这里对“当前账号可见”的会话
/// 逐页解密扫描，按发送者/类型/时间过滤并限制返回条数。可见性完全由注入的
/// 成员策略判定，绝不返回非成员或早于入群历史的正文。
class MessageSearchService {
  MessageSearchService({
    required Database database,
    required MessageStore store,
    BlindIndexService? blind,
  }) : _database = database,
       _store = store,
       _blind = blind;

  final Database _database;
  final MessageStore _store;
  final BlindIndexService? _blind;

  static const int _maxPagesPerConversation = 20;
  static const int _pageSize = 200;

  Future<Result<List<Map<String, Object?>>>> search({
    required String accountId,
    required String query,
    required Future<bool> Function(String accountId, String conversationId)
    canRead,
    required Future<int?> Function(String accountId, String conversationId)
    firstVisibleSeq,
    String? senderId,
    MessageKind? kind,
    DateTime? from,
    DateTime? to,
    int limit = 50,
  }) async {
    final needle = query.toLowerCase();
    final hits = <Map<String, Object?>>[];
    final seen = <String>{};
    bool matches(
      Map<String, Object?> body,
      String sender,
      String kindWire,
      DateTime sentAt,
    ) {
      if (senderId != null && sender != senderId) return false;
      if (kind != null && kind.wire != kindWire) return false;
      if (from != null && sentAt.isBefore(from)) return false;
      if (to != null && sentAt.isAfter(to)) return false;
      return jsonEncode(body).toLowerCase().contains(needle);
    }

    // 盲索引候选优先（候选仍需解密校验与可见性检查）。
    final blind = _blind;
    if (blind != null) {
      final candidates = await blind.candidates(query);
      if (candidates.isOk) {
        for (final row in await blind.resolve(candidates.value)) {
          if (hits.length >= limit) break;
          final conversationId = row['conversationId'] as String;
          if (!await canRead(accountId, conversationId)) continue;
          final first = await firstVisibleSeq(accountId, conversationId);
          if (first == null) continue;
          if ((row['seq'] as int) < first) continue;
          final body = (row['body'] as Map).cast<String, Object?>();
          final kindWire = row['kind'] as String;
          final sentAt = DateTime.parse(row['sentAt'] as String);
          if (!matches(body, row['senderId'] as String, kindWire, sentAt)) {
            continue;
          }
          final id = row['messageId'] as String;
          if (!seen.add(id)) continue;
          hits.add({
            'conversationId': conversationId,
            'messageId': id,
            'seq': row['seq'],
            'senderId': row['senderId'],
            'kind': kindWire,
            'body': body,
            'sentAt': sentAt.toIso8601String(),
            'mode': 'blind',
          });
        }
      }
    }

    final conversations = await _database.query(
      'SELECT DISTINCT conversation_id FROM messages',
    );
    for (final row in conversations) {
      if (hits.length >= limit) break;
      final conversationId = row['conversation_id'] as String;
      if (!await canRead(accountId, conversationId)) continue;
      final first = await firstVisibleSeq(accountId, conversationId);
      if (first == null) continue;
      var afterSeq = first - 1;
      var pages = 0;
      while (hits.length < limit && pages < _maxPagesPerConversation) {
        final page = await _store.since(
          conversationId: conversationId,
          afterSeq: afterSeq,
          limit: _pageSize,
        );
        if (page.isErr) return Err(page.failureOrNull!);
        final messages = page.value.messages;
        for (final message in messages) {
          if (hits.length >= limit) break;
          if (!seen.add(message.messageId)) continue;
          if (!matches(
            message.body,
            message.senderId,
            message.kind.wire,
            message.sentAt,
          )) {
            continue;
          }
          hits.add({
            'conversationId': message.conversationId,
            'messageId': message.messageId,
            'seq': message.seq,
            'senderId': message.senderId,
            'kind': message.kind.wire,
            'body': message.body,
            'sentAt': message.sentAt.toIso8601String(),
            'mode': 'scan',
          });
        }
        if (!page.value.hasMore || messages.isEmpty) break;
        afterSeq = messages.last.seq;
        pages++;
      }
    }
    return Ok(hits);
  }
}
