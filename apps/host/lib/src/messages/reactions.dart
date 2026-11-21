import 'package:jingyu_core/jingyu_core.dart';

import '../audit/audit_log.dart';
import '../storage/database.dart';

/// Reads the actor's history floor within the transaction. Mutations also
/// require current posting permission; null means the conversation is hidden.
typedef ReactionHistoryAccess =
    Future<int?> Function(
      Tx tx,
      String accountId,
      String conversationId, {
      required bool requirePost,
    });

/// 消息表情回应（tapback）：按消息+账号+emoji 唯一，重复切换即取消。
class ReactionsService {
  ReactionsService({
    required Database database,
    required ReactionHistoryAccess historyAccess,
    required Future<void> Function(Tx, AuditEntry) writeAudit,
    this.clock = const SystemClock(),
  }) : _database = database,
       _historyAccess = historyAccess,
       _writeAudit = writeAudit;

  final Database _database;
  final ReactionHistoryAccess _historyAccess;
  final Future<void> Function(Tx, AuditEntry) _writeAudit;
  final Clock clock;

  static Result<T> _notVisible<T>() => err(FailureCode.notFound, 'Not found');

  Future<bool> _canAccess(
    Tx tx,
    String accountId,
    String conversationId,
    String messageId, {
    required bool requirePost,
  }) async {
    final first = await _historyAccess(
      tx,
      accountId,
      conversationId,
      requirePost: requirePost,
    );
    if (first == null) return false;
    return (await tx.query(
      '''
SELECT 1 FROM messages WHERE conversation_id=? AND message_id=?
AND seq>=? AND recalled_at IS NULL
''',
      [conversationId, messageId, first],
    )).isNotEmpty;
  }

  Future<Result<Map<String, Object?>>> toggle({
    required String conversationId,
    required String messageId,
    required String accountId,
    required String emoji,
  }) async {
    if (emoji.isEmpty || emoji.length > 32) {
      return err(FailureCode.invalidArgument, 'emoji length must be 1-32');
    }
    return _database.transaction((tx) async {
      if (!await _canAccess(
        tx,
        accountId,
        conversationId,
        messageId,
        requirePost: true,
      )) {
        return _notVisible();
      }
      final now = clock.now().toUtc();
      final removed = await tx.execute(
        '''
DELETE FROM message_reactions
WHERE conversation_id=? AND message_id=? AND account_id=? AND emoji=?
''',
        [conversationId, messageId, accountId, emoji],
      );
      final active = removed == 0;
      if (active) {
        await tx.execute(
          '''
INSERT INTO message_reactions(message_id, conversation_id, account_id, emoji, created_at)
VALUES (?, ?, ?, ?, ?)
''',
          [messageId, conversationId, accountId, emoji, now.toIso8601String()],
        );
      }
      // The legacy emoji field accepts arbitrary short text. Never audit it.
      await _writeAudit(
        tx,
        AuditEntry(
          at: now,
          actorId: accountId,
          action: active ? 'message.react' : 'message.unreact',
          targetKind: 'message',
          targetId: messageId,
          meta: {'conversationId': conversationId},
        ),
      );
      return Ok({'emoji': emoji, 'active': active});
    });
  }

  Future<Result<List<Map<String, Object?>>>> list({
    required String conversationId,
    required String messageId,
    required String accountId,
  }) => _database.transaction((tx) async {
    if (!await _canAccess(
      tx,
      accountId,
      conversationId,
      messageId,
      requirePost: false,
    )) {
      return _notVisible();
    }
    final rows = await tx.query(
      '''
SELECT account_id, emoji FROM message_reactions
WHERE conversation_id=? AND message_id=?
ORDER BY rowid
''',
      [conversationId, messageId],
    );
    return Ok([
      for (final row in rows)
        {'accountId': row['account_id'], 'emoji': row['emoji']},
    ]);
  });
}
