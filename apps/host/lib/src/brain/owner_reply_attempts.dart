import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';

enum OwnerReplyAttemptStatus { pending, completed, failed, discarded }

/// Immutable identity snapshot. Never contains source body, prompts or keys.
class OwnerReplyAttemptClaim {
  const OwnerReplyAttemptClaim({
    required this.sourceMessageId,
    required this.aiProfileId,
    required this.ownerAccountId,
    required this.aiAccountId,
    required this.conversationId,
    required this.grantRevision,
    required this.requestId,
  });
  final String sourceMessageId;
  final String aiProfileId;
  final String ownerAccountId;
  final String aiAccountId;
  final String conversationId;
  final int grantRevision;
  final String requestId;
}

class OwnerReplyAttempt {
  const OwnerReplyAttempt({
    required this.claim,
    required this.status,
    this.replyId,
    this.failureCode,
  });
  final OwnerReplyAttemptClaim claim;
  final OwnerReplyAttemptStatus status;
  final String? replyId;
  final FailureCode? failureCode;
}

/// Trusted storage primitive: uses only the caller's supplied transaction.
///
/// The (source message, AI profile) key deliberately excludes grant revision and
/// owner: revocation/reopening or ownership transfer must not replay that source.
/// This API never deletes/reclaims/retries. Trusted maintenance may delete rows
/// for retention/account departure; deduplication cannot cover that operation.
///
/// This is NOT conversation authorization or model dispatch. A trusted caller
/// must recheck live ownership, grant and conversation policy in its transaction.
/// Invalid typed input is programmer misuse (ArgumentError/FormatException).
/// Corrupt stored data fails closed with a fixed StateError, never raw values.
class OwnerReplyAttempts {
  const OwnerReplyAttempts();

  Future<bool> claimInTx(Tx tx, {required OwnerReplyAttemptClaim claim}) async {
    _validateClaim(claim);
    final count = await tx.execute(
      '''
INSERT INTO owner_reply_attempts (
  source_message_id,ai_profile_id,owner_account_id,ai_account_id,
  conversation_id,grant_revision,request_id,status
) VALUES (?,?,?,?,?,?,?,'pending')
ON CONFLICT(source_message_id,ai_profile_id) DO NOTHING
''',
      [
        claim.sourceMessageId,
        claim.aiProfileId,
        claim.ownerAccountId,
        claim.aiAccountId,
        claim.conversationId,
        claim.grantRevision,
        claim.requestId,
      ],
    );
    return count == 1;
  }

  /// A single atomic CAS from pending to a terminal status. A repeated finish,
  /// missing key, different owner or different request returns false unchanged.
  Future<bool> finishInTx(
    Tx tx, {
    required String ownerAccountId,
    required String sourceMessageId,
    required String aiProfileId,
    required String requestId,
    required OwnerReplyAttemptStatus status,
    String? replyId,
    FailureCode? failureCode,
  }) async {
    _validateKey(ownerAccountId, sourceMessageId, aiProfileId);
    validateId(requestId, kind: 'request');
    if (replyId != null) validateId(replyId, kind: 'reply');
    _validateTerminal(status, replyId, failureCode);
    final count = await tx.execute(
      '''
UPDATE owner_reply_attempts SET status=?,reply_id=?,safe_failure_code=?
WHERE owner_account_id=? AND source_message_id=? AND ai_profile_id=?
AND request_id=? AND status='pending'
''',
      [
        status.name,
        replyId,
        failureCode?.name,
        ownerAccountId,
        sourceMessageId,
        aiProfileId,
        requestId,
      ],
    );
    return count == 1;
  }

  /// Owner-filtered point read. Does not authorize access to the conversation.
  Future<OwnerReplyAttempt?> getForOwnerInTx(
    Tx tx, {
    required String ownerAccountId,
    required String sourceMessageId,
    required String aiProfileId,
  }) async {
    _validateKey(ownerAccountId, sourceMessageId, aiProfileId);
    final rows = await tx.query(
      '''
SELECT source_message_id,ai_profile_id,owner_account_id,ai_account_id,
conversation_id,grant_revision,request_id,status,reply_id,safe_failure_code
FROM owner_reply_attempts
WHERE owner_account_id=? AND source_message_id=? AND ai_profile_id=?
''',
      [ownerAccountId, sourceMessageId, aiProfileId],
    );
    if (rows.isEmpty) return null;
    try {
      final row = rows.single;
      final claim = OwnerReplyAttemptClaim(
        sourceMessageId: row['source_message_id'] as String,
        aiProfileId: row['ai_profile_id'] as String,
        ownerAccountId: row['owner_account_id'] as String,
        aiAccountId: row['ai_account_id'] as String,
        conversationId: row['conversation_id'] as String,
        grantRevision: row['grant_revision'] as int,
        requestId: row['request_id'] as String,
      );
      _validateClaim(claim);
      final status = OwnerReplyAttemptStatus.values.byName(
        row['status'] as String,
      );
      final rawFailure = row['safe_failure_code'] as String?;
      final failure = rawFailure == null
          ? null
          : FailureCode.values.byName(rawFailure);
      final replyId = row['reply_id'] as String?;
      if (replyId != null) validateId(replyId, kind: 'reply');
      if (status == OwnerReplyAttemptStatus.pending) {
        if (replyId != null || failure != null) throw StateError('invalid');
      } else {
        _validateTerminal(status, replyId, failure);
      }
      return OwnerReplyAttempt(
        claim: claim,
        status: status,
        replyId: replyId,
        failureCode: failure,
      );
    } catch (_) {
      throw StateError('Invalid stored reply attempt');
    }
  }
}

void _validateKey(String owner, String source, String profile) {
  validateId(owner, kind: 'owner');
  validateId(source, kind: 'source message');
  validateId(profile, kind: 'AI profile');
}

void _validateClaim(OwnerReplyAttemptClaim claim) {
  _validateKey(claim.ownerAccountId, claim.sourceMessageId, claim.aiProfileId);
  validateId(claim.aiAccountId, kind: 'AI account');
  validateId(claim.conversationId, kind: 'conversation');
  validateId(claim.requestId, kind: 'request');
  if (claim.grantRevision < 0) throw ArgumentError('Invalid grant revision');
}

void _validateTerminal(
  OwnerReplyAttemptStatus status,
  String? reply,
  FailureCode? failure,
) {
  final valid = switch (status) {
    OwnerReplyAttemptStatus.pending => false,
    OwnerReplyAttemptStatus.completed => reply != null && failure == null,
    OwnerReplyAttemptStatus.failed => reply == null && failure != null,
    OwnerReplyAttemptStatus.discarded => reply == null,
  };
  if (!valid) throw ArgumentError('Invalid terminal reply attempt');
}
