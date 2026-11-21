import 'package:jingyu_core/jingyu_core.dart';

import '../audit/audit_log.dart';
import '../storage/database.dart';

/// Reads the first visible sequence for an authenticated actor in [tx].
/// Mutations additionally require the current posting permission.
typedef PinHistoryAccess =
    Future<int?> Function(
      Tx tx,
      String accountId,
      String conversationId, {
      required bool requirePost,
    });

/// 会话内消息置顶（FR-15 / AC-19 子集）：每会话最多 [maxPins] 条。
class PinsService {
  PinsService({
    required Database database,
    required PinHistoryAccess historyAccess,
    required Future<void> Function(Tx, AuditEntry) writeAudit,
    this.clock = const SystemClock(),
    this.maxPins = 50,
  }) : _database = database,
       _historyAccess = historyAccess,
       _writeAudit = writeAudit;

  final Database _database;
  final PinHistoryAccess _historyAccess;
  final Future<void> Function(Tx, AuditEntry) _writeAudit;
  final Clock clock;
  final int maxPins;

  static const _livePins = '''
FROM message_pins p
JOIN messages m ON m.conversation_id=p.conversation_id AND m.message_id=p.message_id
WHERE p.conversation_id=? AND m.recalled_at IS NULL
''';

  static Result<T> _notVisible<T>() => err(FailureCode.notFound, 'Not found');

  Future<bool> _canChange(
    Tx tx,
    String accountId,
    String conversationId,
    String messageId,
  ) async {
    final first = await _historyAccess(
      tx,
      accountId,
      conversationId,
      requirePost: true,
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

  Future<Result<Map<String, Object?>>> pin({
    required String conversationId,
    required String messageId,
    required String accountId,
  }) => _database.transaction((tx) async {
    if (!await _canChange(tx, accountId, conversationId, messageId)) {
      return _notVisible();
    }
    final existing = await tx.query(
      'SELECT 1 FROM message_pins WHERE conversation_id=? AND message_id=?',
      [conversationId, messageId],
    );
    if (existing.isNotEmpty) return Ok({'pinned': true, 'duplicate': true});
    final count = await tx.query('SELECT COUNT(*) AS n $_livePins', [
      conversationId,
    ]);
    if ((count.single['n'] as int) >= maxPins) {
      return err(FailureCode.invalidArgument, 'pin limit reached');
    }
    // Recalled or removed rows no longer count as pins. Prune only when a
    // new pin is allowed so this metadata cannot grow without the cap.
    await tx.execute(
      '''
DELETE FROM message_pins WHERE conversation_id=? AND NOT EXISTS (
  SELECT 1 FROM messages m WHERE m.conversation_id=message_pins.conversation_id
  AND m.message_id=message_pins.message_id AND m.recalled_at IS NULL
)
''',
      [conversationId],
    );
    final now = clock.now().toUtc();
    await tx.execute(
      '''
INSERT INTO message_pins(conversation_id, message_id, account_id, pinned_at)
VALUES (?, ?, ?, ?)
''',
      [conversationId, messageId, accountId, now.toIso8601String()],
    );
    await _auditChange(
      tx,
      'message.pin',
      accountId,
      conversationId,
      messageId,
      now,
    );
    return Ok({'pinned': true, 'duplicate': false});
  });

  Future<Result<void>> unpin({
    required String conversationId,
    required String messageId,
    required String accountId,
  }) => _database.transaction((tx) async {
    if (!await _canChange(tx, accountId, conversationId, messageId)) {
      return _notVisible();
    }
    final removed = await tx.execute(
      'DELETE FROM message_pins WHERE conversation_id=? AND message_id=?',
      [conversationId, messageId],
    );
    if (removed != 0) {
      await _auditChange(
        tx,
        'message.unpin',
        accountId,
        conversationId,
        messageId,
        clock.now(),
      );
    }
    return const Ok(null);
  });

  Future<void> _auditChange(
    Tx tx,
    String action,
    String accountId,
    String conversationId,
    String messageId,
    DateTime at,
  ) => _writeAudit(
    tx,
    AuditEntry(
      at: at,
      actorId: accountId,
      action: action,
      targetKind: 'message',
      targetId: messageId,
      meta: {'conversationId': conversationId},
    ),
  );

  Future<Result<List<Map<String, Object?>>>> list({
    required String conversationId,
    required String accountId,
  }) => _database.transaction((tx) async {
    final first = await _historyAccess(
      tx,
      accountId,
      conversationId,
      requirePost: false,
    );
    if (first == null) return _notVisible();
    final rows = await tx.query(
      'SELECT p.message_id, p.account_id, p.pinned_at $_livePins AND m.seq>=? ORDER BY p.rowid',
      [conversationId, first],
    );
    return Ok([
      for (final row in rows)
        {
          'messageId': row['message_id'],
          'pinnedBy': row['account_id'],
          'pinnedAt': row['pinned_at'],
        },
    ]);
  });
}
