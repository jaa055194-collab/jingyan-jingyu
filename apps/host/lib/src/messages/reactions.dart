import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';

/// 消息表情回应（tapback）：按消息+账号+emoji 唯一，重复切换即取消。
class ReactionsService {
  ReactionsService({
    required Database database,
    this.clock = const SystemClock(),
  }) : _database = database;

  final Database _database;
  final Clock clock;

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
      final message = await tx.query(
        'SELECT 1 FROM messages WHERE conversation_id = ? AND message_id = ?',
        [conversationId, messageId],
      );
      if (message.isEmpty) {
        return err(FailureCode.notFound, 'message not found');
      }
      final existing = await tx.query(
        'SELECT 1 FROM message_reactions WHERE message_id = ? AND account_id = ? AND emoji = ?',
        [messageId, accountId, emoji],
      );
      if (existing.isNotEmpty) {
        await tx.execute(
          'DELETE FROM message_reactions WHERE message_id = ? AND account_id = ? AND emoji = ?',
          [messageId, accountId, emoji],
        );
        return Ok({'emoji': emoji, 'active': false});
      }
      await tx.execute(
        '''
INSERT INTO message_reactions(message_id, conversation_id, account_id, emoji, created_at)
VALUES (?, ?, ?, ?, ?)
''',
        [
          messageId,
          conversationId,
          accountId,
          emoji,
          clock.now().toUtc().toIso8601String(),
        ],
      );
      return Ok({'emoji': emoji, 'active': true});
    });
  }

  Future<Result<List<Map<String, Object?>>>> list({
    required String conversationId,
    required String messageId,
  }) async {
    final rows = await _database.query(
      '''
SELECT account_id, emoji FROM message_reactions
WHERE conversation_id = ? AND message_id = ?
ORDER BY rowid
''',
      [conversationId, messageId],
    );
    return Ok([
      for (final row in rows)
        {'accountId': row['account_id'], 'emoji': row['emoji']},
    ]);
  }
}
