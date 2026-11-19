import 'dart:convert';
import 'dart:math' show min;

import 'package:jingyu_core/jingyu_core.dart';

import '../messages/message_store.dart' show SyncPage;
import 'export.dart';

/// Reads the owner's visible chat history through the host's sync contracts.
///
/// This monolithic in-memory route fails when its assembly bounds are exceeded;
/// it never truncates history or treats those bounds as an account quota. The
/// byte bound counts UTF-8 JSON messages plus one newline each, before final
/// membership filtering. It does not measure total Dart object/assembly memory.
class ChatHistoryExportSource implements ExportSource, ExportCoverage {
  ChatHistoryExportSource({
    required Future<List<String>> Function(String owner) listConversationIds,
    required Future<int?> Function(String owner, String conversation)
    firstVisibleSeq,
    required Future<Map<String, int?>> Function(
      String owner,
      Iterable<String> conversationIds,
    )
    readVisibilitySnapshot,
    required Future<int> Function(String conversation) headSeq,
    required Future<Result<SyncPage>> Function({
      required String conversationId,
      required int afterSeq,
      int limit,
    })
    readPage,
    int pageSize = 200,
    int maxConversations = 10000,
    int maxMessages = 100000,
    int maxEncodedBytes = 32 * 1024 * 1024,
  }) : _listConversationIds = listConversationIds,
       _firstVisibleSeq = firstVisibleSeq,
       _readVisibilitySnapshot = readVisibilitySnapshot,
       _headSeq = headSeq,
       _readPage = readPage,
       _pageSize = RangeError.checkValueInInterval(
         pageSize,
         1,
         1000,
         'pageSize',
       ),
       _maxConversations = _positive(maxConversations, 'maxConversations'),
       _maxMessages = _positive(maxMessages, 'maxMessages'),
       _maxEncodedBytes = _positive(maxEncodedBytes, 'maxEncodedBytes');

  final Future<List<String>> Function(String owner) _listConversationIds;
  final Future<int?> Function(String owner, String conversation)
  _firstVisibleSeq;
  final Future<Map<String, int?>> Function(
    String owner,
    Iterable<String> conversationIds,
  )
  _readVisibilitySnapshot;
  final Future<int> Function(String conversation) _headSeq;
  final Future<Result<SyncPage>> Function({
    required String conversationId,
    required int afterSeq,
    int limit,
  })
  _readPage;
  final int _pageSize;
  final int _maxConversations;
  final int _maxMessages;
  final int _maxEncodedBytes;

  static int _positive(int value, String name) {
    if (value < 1) throw ArgumentError.value(value, name, 'Must be positive');
    return value;
  }

  @override
  Map<String, Object?> get coverage => const {
    'scope': 'chatHistory',
    'completeAccountExport': false,
    'pendingDomains': ['persona', 'memories', 'attachments'],
  };

  @override
  Future<Map<String, Object?>?> persona(String ownerAccountId) async => null;

  @override
  Future<List<Map<String, Object?>>> memories(String ownerAccountId) async =>
      const [];

  @override
  Future<List<Map<String, Object?>>> attachments(String ownerAccountId) async =>
      const [];

  @override
  Future<List<ExportConversation>> conversations(String ownerAccountId) async {
    final unique = <String>{};
    for (final id in await _listConversationIds(ownerAccountId)) {
      unique.add(id);
      if (unique.length > _maxConversations) {
        throw StateError('Export conversation assembly limit exceeded');
      }
    }
    final ids = unique.toList()..sort();
    for (final id in ids) {
      ConversationId.parse(id);
    }

    final candidates = <ExportConversation>[];
    final budget = _ExportBudget(_maxMessages, _maxEncodedBytes);
    for (final id in ids) {
      final first = await _visibilityFloor(ownerAccountId, id);
      if (first == null) continue;
      final head = await _headSeq(id);
      if (head < 0) throw StateError('Invalid message head');
      candidates.add(
        ExportConversation(
          conversationId: id,
          messages: await _readSuffix(id, first, head, budget),
        ),
      );
    }

    // The host observes all final permissions in one read transaction. Copy its
    // result and use it without further per-ID awaits; changes after that point
    // still follow normal sync semantics rather than a whole-export DB snapshot.
    final candidateIds = candidates.map((c) => c.conversationId).toSet();
    final snapshot = Map<String, int?>.of(
      await _readVisibilitySnapshot(ownerAccountId, candidateIds),
    );
    if (snapshot.length != candidateIds.length ||
        snapshot.keys.any((id) => !candidateIds.contains(id))) {
      throw StateError('Incomplete or invalid visibility snapshot');
    }
    final visible = <ExportConversation>[];
    for (final candidate in candidates) {
      final id = candidate.conversationId;
      final first = snapshot[id];
      if (first == null) continue;
      if (first < 1) throw StateError('Invalid visibility floor');
      visible.add(
        ExportConversation(
          conversationId: id,
          messages: candidate.messages.where((m) => m.seq >= first).toList(),
        ),
      );
    }
    return visible;
  }

  Future<int?> _visibilityFloor(String owner, String id) async {
    final first = await _firstVisibleSeq(owner, id);
    if (first != null && first < 1) {
      throw StateError('Invalid visibility floor');
    }
    return first;
  }

  Future<List<ExportMessage>> _readSuffix(
    String id,
    int first,
    int head,
    _ExportBudget budget,
  ) async {
    if (head - first + 1 > budget.remainingMessages) {
      throw StateError('Export message assembly limit exceeded');
    }
    final messages = <ExportMessage>[];
    var after = first - 1;
    while (after < head) {
      final limit = min(_pageSize, head - after);
      final result = await _readPage(
        conversationId: id,
        afterSeq: after,
        limit: limit,
      );
      final page = result.valueOrNull;
      if (page == null ||
          page.messages.isEmpty ||
          page.messages.length > limit) {
        throw StateError('Unreadable or invalid message page');
      }
      for (final message in page.messages) {
        if (message.conversationId != id || message.seq != after + 1) {
          throw StateError('Unexpected message conversation or sequence');
        }
        final exported = ExportMessage(
          messageId: message.messageId,
          conversationId: id,
          seq: message.seq,
          senderId: message.senderId,
          kind: message.kind.wire,
          body: message.body,
          sentAt: message.sentAt,
        );
        budget.retain(exported);
        messages.add(exported);
        after = message.seq;
      }
      if (!page.hasMore && after < head) {
        throw StateError('Message page ended before the snapshot head');
      }
    }
    return messages;
  }
}

class _ExportBudget {
  _ExportBudget(this.remainingMessages, this._remainingBytes);

  int remainingMessages;
  int _remainingBytes;

  void retain(ExportMessage message) {
    final bytes = utf8.encode(jsonEncode(message.toJson())).length + 1;
    if (remainingMessages == 0 || bytes > _remainingBytes) {
      throw StateError('Export message assembly limit exceeded');
    }
    remainingMessages--;
    _remainingBytes -= bytes;
  }
}
