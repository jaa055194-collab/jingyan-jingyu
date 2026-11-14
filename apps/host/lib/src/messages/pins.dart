import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';

/// 会话内消息置顶（FR-15 / AC-19 子集）：每会话最多 [maxPins] 条。
class PinsService {
  PinsService({
    required Database database,
    this.clock = const SystemClock(),
    this.maxPins = 50,
  }) : _database = database;

  final Database _database;
  final Clock clock;
  final int maxPins;

  Future<Result<Map<String, Object?>>> pin({
    required String conversationId,
    required String messageId,
    required String accountId,
  }) => _database.transaction((tx) async {
    final message = await tx.query(
      'SELECT 1 FROM messages WHERE conversation_id = ? AND message_id = ?',
      [conversationId, messageId],
    );
    if (message.isEmpty) return err(FailureCode.notFound, 'message not found');
    final existing = await tx.query(
      'SELECT 1 FROM message_pins WHERE conversation_id = ? AND message_id = ?',
      [conversationId, messageId],
    );
    if (existing.isNotEmpty) return Ok({'pinned': true, 'duplicate': true});
    final count = await tx.query(
      'SELECT COUNT(*) AS n FROM message_pins WHERE conversation_id = ?',
      [conversationId],
    );
    if ((count.single['n'] as int) >= maxPins) {
      return err(FailureCode.invalidArgument, 'pin limit reached');
    }
    await tx.execute(
      '''
INSERT INTO message_pins(conversation_id, message_id, account_id, pinned_at)
VALUES (?, ?, ?, ?)
''',
      [
        conversationId,
        messageId,
        accountId,
        clock.now().toUtc().toIso8601String(),
      ],
    );
    return Ok({'pinned': true, 'duplicate': false});
  });

  Future<Result<void>> unpin({
    required String conversationId,
    required String messageId,
  }) async {
    await _database.execute(
      'DELETE FROM message_pins WHERE conversation_id = ? AND message_id = ?',
      [conversationId, messageId],
    );
    return const Ok(null);
  }

  Future<Result<List<Map<String, Object?>>>> list({
    required String conversationId,
  }) async {
    final rows = await _database.query(
      '''
SELECT message_id, account_id, pinned_at FROM message_pins
WHERE conversation_id = ?
ORDER BY rowid
''',
      [conversationId],
    );
    return Ok([
      for (final row in rows)
        {
          'messageId': row['message_id'],
          'pinnedBy': row['account_id'],
          'pinnedAt': row['pinned_at'],
        },
    ]);
  }
}
