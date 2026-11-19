import '../messages/messages_module.dart';
import '../storage/database.dart';
import 'private_conversations.dart';

/// Selects policy from the persisted conversation kind, never by whether a
/// particular actor happens to have membership. Both kinds share message keys;
/// ambiguous IDs must deny every actor to prevent cross-conversation disclosure.
class CombinedMembership implements HistoryMembershipCheck {
  CombinedMembership({
    required Database db,
    required HistoryMembershipCheck group,
    required PrivateConversations direct,
    Future<int?> Function(Tx, String, String)? groupHistoryInTransaction,
  }) : _db = db,
       _group = group,
       _direct = direct,
       _groupHistoryInTransaction = groupHistoryInTransaction;

  final Database _db;
  final HistoryMembershipCheck _group;
  final PrivateConversations _direct;
  final Future<int?> Function(Tx, String, String)? _groupHistoryInTransaction;

  Future<String?> _kind(Tx tx, String conversationId) async {
    final kinds = await tx.query(
      '''
SELECT 'group' AS kind FROM social_conversations WHERE id=?
UNION ALL
SELECT 'direct' AS kind FROM direct_conversations WHERE id=?
''',
      [conversationId, conversationId],
    );
    return kinds.length == 1 ? kinds.single['kind'] as String : null;
  }

  Future<HistoryMembershipCheck?> _policy(String conversationId) =>
      _db.transaction((tx) async {
        final kind = await _kind(tx, conversationId);
        return kind == null ? null : (kind == 'direct' ? _direct : _group);
      });

  /// Observe all candidate visibility bounds together. Null means denied.
  Future<Map<String, int?>> historySnapshot(
    String accountId,
    Iterable<String> conversationIds,
  ) {
    final groupHistory = _groupHistoryInTransaction;
    if (groupHistory == null) {
      throw StateError('Group history snapshot policy is not configured');
    }
    return _db.transaction((tx) async {
      final floors = <String, int?>{};
      for (final id in conversationIds) {
        floors[id] = switch (await _kind(tx, id)) {
          'group' => await groupHistory(tx, accountId, id),
          'direct' => await _direct.firstVisibleSeqInTransaction(
            tx,
            accountId,
            id,
          ),
          _ => null,
        };
      }
      return floors;
    });
  }

  @override
  Future<bool> canPost(String accountId, String conversationId) async {
    final policy = await _policy(conversationId);
    return policy == null ? false : policy.canPost(accountId, conversationId);
  }

  @override
  Future<bool> canRead(String accountId, String conversationId) async {
    final policy = await _policy(conversationId);
    return policy == null ? false : policy.canRead(accountId, conversationId);
  }

  @override
  Future<int?> firstVisibleSeq(String accountId, String conversationId) async {
    final policy = await _policy(conversationId);
    return policy?.firstVisibleSeq(accountId, conversationId);
  }
}
