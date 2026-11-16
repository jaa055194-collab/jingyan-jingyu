import 'dart:convert';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';

import '../messages/messages_module.dart';
import '../storage/database.dart';
import 'friendship_service.dart';
import 'owner_ai_direct_consent.dart';

class PrivateConversation {
  const PrivateConversation({
    required this.id,
    required this.accountLow,
    required this.accountHigh,
    required this.createdAt,
  });

  final String id;
  final String accountLow;
  final String accountHigh;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': 'direct',
    'accountLow': accountLow,
    'accountHigh': accountHigh,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory PrivateConversation._row(Map<String, Object?> row) =>
      PrivateConversation(
        id: row['id'] as String,
        accountLow: row['account_low'] as String,
        accountHigh: row['account_high'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row['created_at'] as int,
          isUtc: true,
        ),
      );
}

/// Trusted internal capability. Callers supply authenticated account IDs, never
/// an actor taken from request JSON. This first public creation flow is human to
/// human: AI cannot initiate or accept friendship without future authorization.
/// An existing AI member may pass canPost only with a valid active operator;
/// callers must obtain that identity through a trusted gateway, not delegation.
///
/// Both fixed members retain history from seq 1 after blocking. Posting requires
/// current active accounts, current mutual friendship and no inherited block.
/// This policy can be composed with the group's HistoryMembershipCheck by a host.
class PrivateConversations implements HistoryMembershipCheck {
  PrivateConversations({required Database db, required Clock clock})
    : _db = db,
      _clock = clock;

  final Database _db;
  final Clock _clock;
  static final Random _random = Random.secure();
  static String _newId() => base64Url
      .encode(List.generate(18, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  static bool _valid(String id) {
    try {
      validateId(id);
      return true;
    } on FormatException {
      return false;
    }
  }

  Result<T> _invalid<T>() => err(FailureCode.invalidArgument, 'Invalid input');
  Result<T> _missing<T>() => err(FailureCode.notFound, 'Not found');
  // Do not expose the existence or direction of a block, even to callers who
  // can attempt an open. All relationship denials have the same public result.
  Result<T> _denied<T>() =>
      err(FailureCode.forbidden, 'Private conversation unavailable');

  Future<Result<PrivateConversation>> open({
    required String actorId,
    required String targetId,
  }) async {
    if (!_valid(actorId) || !_valid(targetId) || actorId == targetId) {
      return _invalid();
    }
    return _db.transaction((tx) async {
      final actorKind = await FriendshipService.activeKindInTx(tx, actorId);
      final targetKind = await FriendshipService.activeKindInTx(tx, targetId);
      if (actorKind == null || targetKind == null) return _missing();
      if (actorKind != 'human') return _denied();
      if (!await FriendshipService.friendsInTx(tx, actorId, targetId) ||
          await FriendshipService.isBlockedInTransaction(
            tx,
            actorId,
            targetId,
          )) {
        return _denied();
      }
      final pair = actorId.compareTo(targetId) < 0
          ? [actorId, targetId]
          : [targetId, actorId];
      final existing = await tx.query(
        'SELECT id FROM direct_conversations WHERE account_low=? AND account_high=?',
        pair,
      );
      if (existing.isNotEmpty &&
          await OwnerAiDirectConsent.tagInTx(
                tx,
                existing.single['id'] as String,
              ) !=
              null) {
        // Tagged owner-AI consent can only be changed via its explicit CAS API.
        return _denied();
      }
      // Eligibility, uniqueness and insertion share the supplied Tx. The unique
      // pair also arbitrates competing opens through independent connections.
      await tx.execute(
        '''INSERT INTO direct_conversations(id,account_low,account_high,created_at)
VALUES (?,?,?,?) ON CONFLICT(account_low,account_high) DO NOTHING''',
        [_newId(), ...pair, _clock.now().toUtc().millisecondsSinceEpoch],
      );
      final rows = await tx.query(
        'SELECT * FROM direct_conversations WHERE account_low=? AND account_high=?',
        pair,
      );
      return Ok(PrivateConversation._row(rows.single));
    });
  }

  Future<Result<List<PrivateConversation>>> list(String accountId) async {
    if (!_valid(accountId)) return _invalid();
    return _db.transaction((tx) async {
      if ((await tx.query('SELECT 1 FROM account WHERE id=?', [
        accountId,
      ])).isEmpty) {
        return _missing();
      }
      final rows = await tx.query(
        '''SELECT * FROM direct_conversations WHERE account_low=? OR account_high=?
ORDER BY created_at,id''',
        [accountId, accountId],
      );
      final visible = <PrivateConversation>[];
      for (final row in rows) {
        final tag = await OwnerAiDirectConsent.tagInTx(tx, row['id'] as String);
        if (tag == null ||
            await OwnerAiDirectConsent.taggedReadInTx(tx, tag, accountId)) {
          visible.add(PrivateConversation._row(row));
        }
      }
      return Ok(visible);
    });
  }

  Future<List<Map<String, Object?>>> _member(
    Tx tx,
    String accountId,
    String conversationId,
  ) async {
    final rows = await tx.query(
      '''SELECT * FROM direct_conversations WHERE id=?
AND (account_low=? OR account_high=?)''',
      [conversationId, accountId, accountId],
    );
    if (rows.isEmpty) return rows;
    final tag = await OwnerAiDirectConsent.tagInTx(tx, conversationId);
    if (tag != null &&
        !await OwnerAiDirectConsent.taggedReadInTx(tx, tag, accountId)) {
      return [];
    }
    return rows;
  }

  Future<Result<PrivateConversation>> get({
    required String accountId,
    required String conversationId,
  }) async {
    if (!_valid(accountId) || !_valid(conversationId)) return _invalid();
    return _db.transaction((tx) async {
      final rows = await _member(tx, accountId, conversationId);
      return rows.isEmpty
          ? _missing()
          : Ok(PrivateConversation._row(rows.single));
    });
  }

  @override
  Future<int?> firstVisibleSeq(String accountId, String conversationId) async {
    if (!_valid(accountId) || !_valid(conversationId)) return null;
    return _db.transaction(
      (tx) async =>
          (await _member(tx, accountId, conversationId)).isEmpty ? null : 1,
    );
  }

  @override
  Future<bool> canRead(String accountId, String conversationId) async =>
      await firstVisibleSeq(accountId, conversationId) != null;

  @override
  Future<bool> canPost(String accountId, String conversationId) async {
    if (!_valid(accountId) || !_valid(conversationId)) return false;
    return _db.transaction((tx) async {
      final rows = await _member(tx, accountId, conversationId);
      if (rows.isEmpty) return false;
      final tag = await OwnerAiDirectConsent.tagInTx(tx, conversationId);
      if (tag != null) {
        return await OwnerAiDirectConsent.resolveInTx(
              tx,
              ownerAccountId: tag['owner_account_id'] as String,
              conversationId: conversationId,
            ) !=
            null;
      }
      final a = rows.single['account_low'] as String;
      final b = rows.single['account_high'] as String;
      return await FriendshipService.activeKindInTx(tx, a) != null &&
          await FriendshipService.activeKindInTx(tx, b) != null &&
          await FriendshipService.friendsInTx(tx, a, b) &&
          !await FriendshipService.isBlockedInTransaction(tx, a, b);
    });
  }
}
