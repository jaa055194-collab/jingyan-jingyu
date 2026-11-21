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
    Future<int?> Function(Tx, String, String)? groupPostingHistoryInTransaction,
  }) : _db = db,
       _group = group,
       _direct = direct,
       _groupHistoryInTransaction = groupHistoryInTransaction,
       _groupPostingHistoryInTransaction = groupPostingHistoryInTransaction;

  final Database _db;
  final HistoryMembershipCheck _group;
  final PrivateConversations _direct;
  final Future<int?> Function(Tx, String, String)? _groupHistoryInTransaction;
  final Future<int?> Function(Tx, String, String)?
  _groupPostingHistoryInTransaction;

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

  /// Reuse the conversation policy inside a caller-owned transaction.
  /// A missing transaction policy fails closed; a direct conversation has a
  /// separate posting gate.
  Future<int?> firstVisibleSeqInTransaction(
    Tx tx,
    String accountId,
    String conversationId, {
    bool requirePost = false,
  }) async {
    switch (await _kind(tx, conversationId)) {
      case 'group':
        final policy = requirePost
            ? _groupPostingHistoryInTransaction
            : _groupHistoryInTransaction;
        return policy == null
            ? null
            : await policy(tx, accountId, conversationId);
      case 'direct':
        if (requirePost) {
          return await _direct.canPostInTransaction(
                tx,
                accountId,
                conversationId,
              )
              ? 1
              : null;
        }
        return _direct.firstVisibleSeqInTransaction(
          tx,
          accountId,
          conversationId,
        );
      default:
        return null;
    }
  }

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
