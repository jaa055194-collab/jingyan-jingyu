import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'friendship_service.dart';

/// Trusted current-account scope, never an owner accepted from request data.
final class ConversationPreferences {
  ConversationPreferences({required Database database}) : _db = database;
  final Database _db;

  Future<bool> _member(Tx tx, String account, String conversation) async {
    if (await FriendshipService.activeKindInTx(tx, account) == null) {
      return false;
    }
    final kinds = await tx.query(
      '''
SELECT 'group' AS kind FROM social_conversations WHERE id=?
UNION ALL SELECT 'direct' AS kind FROM direct_conversations WHERE id=?
''',
      [conversation, conversation],
    );
    if (kinds.length != 1) return false;
    if (kinds.single['kind'] == 'group') {
      return (await tx.query(
        'SELECT 1 FROM social_members WHERE conversation_id=? AND account_id=?',
        [conversation, account],
      )).isNotEmpty;
    }
    // Pinning follows retained read-history membership, not posting consent.
    return (await tx.query(
      '''
SELECT 1 FROM direct_conversations WHERE id=? AND (account_low=? OR account_high=?)
''',
      [conversation, account, account],
    )).isNotEmpty;
  }

  Future<Result<Map<String, Object?>>> _access({
    required String accountId,
    required String conversationId,
    bool? pinned,
  }) async {
    try {
      validateId(accountId, kind: 'account');
      validateId(conversationId, kind: 'conversation');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'Invalid preference identity');
    }
    return _db.transaction((tx) async {
      if (!await _member(tx, accountId, conversationId)) {
        return err(FailureCode.notFound, 'Conversation not found');
      }
      if (pinned != null) {
        await tx.execute(
          '''
INSERT INTO conversation_preferences(account_id,conversation_id,pinned) VALUES(?,?,?)
ON CONFLICT(account_id,conversation_id) DO UPDATE SET pinned=excluded.pinned
''',
          [accountId, conversationId, pinned ? 1 : 0],
        );
        return Ok<Map<String, Object?>>({'pinned': pinned});
      }
      final rows = await tx.query(
        'SELECT pinned FROM conversation_preferences WHERE account_id=? AND conversation_id=?',
        [accountId, conversationId],
      );
      return Ok<Map<String, Object?>>({
        'pinned': rows.isNotEmpty && rows.single['pinned'] == 1,
      });
    });
  }

  Future<Result<Map<String, Object?>>> get({
    required String accountId,
    required String conversationId,
  }) => _access(accountId: accountId, conversationId: conversationId);
  Future<Result<Map<String, Object?>>> set({
    required String accountId,
    required String conversationId,
    required bool pinned,
  }) => _access(
    accountId: accountId,
    conversationId: conversationId,
    pinned: pinned,
  );
}
