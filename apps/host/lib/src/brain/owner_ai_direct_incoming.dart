import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../messages/message_store.dart';
import '../messages/sqlite_message_store.dart';
import '../social/owner_ai_direct_consent.dart';
import '../storage/database.dart';

/// Trusted incoming append adapter. Tagged conversations are reauthorized in
/// the same transaction that commits the message and its source consent stamp.
/// Untagged conversations retain the ordinary message-store behavior; their
/// membership authorization remains at the existing service boundary.
class OwnerAiDirectIncoming {
  OwnerAiDirectIncoming({
    required Database database,
    required SqliteMessageStore messages,
  }) : _database = database,
       _messages = messages;

  final Database _database;
  final SqliteMessageStore _messages;

  Future<Result<AppendResult>> append({
    required String conversationId,
    required String senderId,
    required String clientMsgId,
    required MessageKind kind,
    required Map<String, Object?> body,
  }) => _database.transaction((tx) async {
    final tag = await OwnerAiDirectConsent.tagInTx(tx, conversationId);
    OwnerAiDirectGrant? grant;
    if (tag != null) {
      // Both kinds share message keys. Recheck ambiguity in this final write Tx,
      // even if the earlier membership precheck saw only the direct chat.
      final collision = await tx.query(
        'SELECT 1 FROM social_conversations WHERE id=?',
        [conversationId],
      );
      if (collision.isNotEmpty) {
        return err(FailureCode.notFound, 'Conversation not available');
      }
      grant = await OwnerAiDirectConsent.resolveInTx(
        tx,
        ownerAccountId: tag['owner_account_id'] as String,
        conversationId: conversationId,
      );
      if (grant == null ||
          (senderId != grant.ownerAccountId && senderId != grant.aiAccountId)) {
        return err(FailureCode.notFound, 'Conversation not available');
      }
    }

    // Never call append() here: it would open a nested Database transaction.
    final result = await _messages.appendInTransaction(
      tx,
      conversationId: conversationId,
      senderId: senderId,
      clientMsgId: clientMsgId,
      kind: kind,
      body: body,
    );
    if (result.isErr || result.value.duplicate || grant == null) return result;

    // Derive every stamp field from canonical accepted message/grant, not from
    // untrusted metadata. Retries never insert or repair a missing old stamp.
    final message = result.value.message;
    final text = message.body['text'];
    if (message.senderId == grant.ownerAccountId &&
        message.kind == MessageKind.text &&
        message.body.length == 1 &&
        text is String &&
        text.trim().isNotEmpty) {
      await tx.execute(
        '''INSERT INTO owner_ai_direct_sources
(source_message_id,owner_account_id,ai_profile_id,ai_account_id,conversation_id,grant_revision)
VALUES(?,?,?,?,?,?)''',
        [
          message.messageId,
          grant.ownerAccountId,
          grant.aiProfileId,
          grant.aiAccountId,
          message.conversationId,
          grant.revision,
        ],
      );
    }
    return result;
  });
}
