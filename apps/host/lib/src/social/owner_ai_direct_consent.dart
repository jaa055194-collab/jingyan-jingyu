import 'dart:convert';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'friendship_service.dart';

/// Internal capability snapshot. Not permission to invoke models or post later:
/// a caller must resolve again in its final write Tx and compare revision.
final class OwnerAiDirectGrant {
  const OwnerAiDirectGrant({
    required this.ownerAccountId,
    required this.aiProfileId,
    required this.aiAccountId,
    required this.conversationId,
    required this.revision,
  });
  final String ownerAccountId;
  final String aiProfileId;
  final String aiAccountId;
  final String conversationId;
  final int revision;
}

/// Explicit current-human consent for exactly the human and their own AI.
/// Scope is ownerTextOnly; this class does not dispatch models or mutate friends.
class OwnerAiDirectConsent {
  OwnerAiDirectConsent({required this.database, required this.clock});
  final Database database;
  final Clock clock;
  static final _random = Random.secure();

  static bool _valid(String value) {
    try {
      validateId(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  static Future<bool> _installed(Tx tx) async => (await tx.query(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='owner_ai_direct_grants'",
  )).isNotEmpty;

  /// Null: untagged legacy chat; non-null: tagged policy MUST take precedence,
  /// including revoked rows. Optional migration keeps old isolated HH tests valid.
  static Future<Map<String, Object?>?> tagInTx(
    Tx tx,
    String conversationId,
  ) async {
    if (!await _installed(tx)) return null;
    final rows = await tx.query(
      'SELECT * FROM owner_ai_direct_grants WHERE conversation_id=?',
      [conversationId],
    );
    return rows.isEmpty ? null : rows.single;
  }

  static Future<OwnerAiDirectGrant?> resolveInTx(
    Tx tx, {
    required String ownerAccountId,
    required String conversationId,
  }) async {
    if (!await _installed(tx)) return null;
    final rows = await tx.query(
      '''
SELECT g.* FROM owner_ai_direct_grants g
JOIN direct_conversations d ON d.id=g.conversation_id
 AND ((d.account_low=g.owner_account_id AND d.account_high=g.ai_account_id)
   OR (d.account_high=g.owner_account_id AND d.account_low=g.ai_account_id))
JOIN ai_profile p ON p.id=g.ai_profile_id AND p.account_id=g.ai_account_id
JOIN account ai ON ai.id=p.account_id AND ai.kind='ai' AND ai.disabled=0
JOIN ai_operator o ON o.ai_id=ai.id AND o.operator_id=g.owner_account_id
JOIN account h ON h.id=o.operator_id AND h.kind='human' AND h.disabled=0
WHERE g.owner_account_id=? AND g.conversation_id=? AND g.enabled=1
''',
      [ownerAccountId, conversationId],
    );
    if (rows.length != 1) return null;
    final row = rows.single;
    final ai = row['ai_account_id'] as String;
    if (await FriendshipService.isBlockedInTransaction(
      tx,
      ownerAccountId,
      ai,
    )) {
      return null;
    }
    return OwnerAiDirectGrant(
      ownerAccountId: ownerAccountId,
      aiProfileId: row['ai_profile_id'] as String,
      aiAccountId: ai,
      conversationId: conversationId,
      revision: row['revision'] as int,
    );
  }

  static Future<bool> taggedReadInTx(
    Tx tx,
    Map<String, Object?> tag,
    String accountId,
  ) async {
    final owner = tag['owner_account_id'] as String;
    final ai = tag['ai_account_id'] as String;
    final canonical = await tx.query(
      '''SELECT 1 FROM direct_conversations WHERE id=?
AND ((account_low=? AND account_high=?) OR (account_low=? AND account_high=?))''',
      [tag['conversation_id'], owner, ai, ai, owner],
    );
    if (canonical.length != 1) return false;
    // Original human retains their own history, even after revoke/transfer.
    if (accountId == owner) {
      return await FriendshipService.activeKindInTx(tx, owner) == 'human';
    }
    if (accountId != tag['ai_account_id']) return false;
    return await resolveInTx(
          tx,
          ownerAccountId: owner,
          conversationId: tag['conversation_id'] as String,
        ) !=
        null;
  }

  Future<Result<Map<String, Object?>>> get({
    required String ownerId,
    required String aiProfileId,
  }) => _access(ownerId: ownerId, aiProfileId: aiProfileId);
  Future<Result<Map<String, Object?>>> open({
    required String ownerId,
    required String aiProfileId,
    required int expectedRevision,
  }) => _access(
    ownerId: ownerId,
    aiProfileId: aiProfileId,
    enabled: true,
    expectedRevision: expectedRevision,
  );
  Future<Result<Map<String, Object?>>> revoke({
    required String ownerId,
    required String aiProfileId,
    required int expectedRevision,
  }) => _access(
    ownerId: ownerId,
    aiProfileId: aiProfileId,
    enabled: false,
    expectedRevision: expectedRevision,
  );

  Future<Result<Map<String, Object?>>> _access({
    required String ownerId,
    required String aiProfileId,
    bool? enabled,
    int? expectedRevision,
  }) async {
    if (!_valid(ownerId) ||
        !_valid(aiProfileId) ||
        (expectedRevision != null && expectedRevision < 0)) {
      return err(
        FailureCode.invalidArgument,
        'Invalid consent identity or revision',
      );
    }
    return database.transaction((tx) async {
      final identity = await tx.query(
        '''
SELECT p.account_id FROM ai_profile p
JOIN account ai ON ai.id=p.account_id AND ai.kind='ai' AND ai.disabled=0
JOIN ai_operator o ON o.ai_id=ai.id AND o.operator_id=?
JOIN account h ON h.id=o.operator_id AND h.kind='human' AND h.disabled=0
WHERE p.id=?
''',
        [ownerId, aiProfileId],
      );
      if (identity.length != 1) {
        return err(FailureCode.notFound, 'AI not found');
      }
      final ai = identity.single['account_id'] as String;
      final rows = await tx.query(
        'SELECT * FROM owner_ai_direct_grants WHERE owner_account_id=? AND ai_profile_id=?',
        [ownerId, aiProfileId],
      );
      final row = rows.isEmpty ? null : rows.single;
      final revision = row?['revision'] as int? ?? 0;
      final blocked = await FriendshipService.isBlockedInTransaction(
        tx,
        ownerId,
        ai,
      );
      Map<String, Object?> view({
        String? id,
        required bool active,
        required int rev,
      }) => {
        'scope': 'ownerTextOnly',
        'aiProfileId': aiProfileId,
        'aiAccountId': ai,
        'conversationId': id,
        'enabled': active,
        'revision': rev,
      };
      if (enabled == null) {
        final id = row?['conversation_id'] as String?;
        final active =
            id != null &&
            await resolveInTx(
                  tx,
                  ownerAccountId: ownerId,
                  conversationId: id,
                ) !=
                null;
        return Ok(view(id: id, active: active, rev: revision));
      }
      if (revision != expectedRevision) {
        return err(FailureCode.conflict, 'Consent revision changed');
      }
      if (enabled && blocked) return err(FailureCode.notFound, 'AI not found');
      // Revoking a never-opened, default-off relationship is a read-only no-op.
      if (!enabled && row == null) return Ok(view(active: false, rev: 0));
      final pair = ownerId.compareTo(ai) < 0 ? [ownerId, ai] : [ai, ownerId];
      final now = clock.now().toUtc().millisecondsSinceEpoch;
      if (row == null) {
        final id = base64Url
            .encode(List.generate(18, (_) => _random.nextInt(256)))
            .replaceAll('=', '');
        await tx.execute(
          '''INSERT INTO direct_conversations(id,account_low,account_high,created_at)
VALUES(?,?,?,?) ON CONFLICT(account_low,account_high) DO NOTHING''',
          [id, ...pair, now],
        );
      }
      final direct = await tx.query(
        'SELECT id FROM direct_conversations WHERE account_low=? AND account_high=?',
        pair,
      );
      if (direct.length != 1) {
        return err(FailureCode.notFound, 'Canonical conversation not found');
      }
      final id = direct.single['id'] as String;
      if (row != null &&
          (row['ai_account_id'] != ai || row['conversation_id'] != id)) {
        return err(FailureCode.conflict, 'Consent identity changed');
      }
      await tx.execute(
        '''INSERT INTO owner_ai_direct_grants
(owner_account_id,ai_profile_id,ai_account_id,conversation_id,enabled,revision,updated_at)
VALUES(?,?,?,?,?,?,?) ON CONFLICT(owner_account_id,ai_profile_id) DO UPDATE SET
 enabled=excluded.enabled,revision=excluded.revision,updated_at=excluded.updated_at''',
        [ownerId, aiProfileId, ai, id, enabled ? 1 : 0, revision + 1, now],
      );
      return Ok(view(id: id, active: enabled, rev: revision + 1));
    });
  }
}
