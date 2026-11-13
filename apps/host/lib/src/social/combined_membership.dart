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
  }) : _db = db,
       _group = group,
       _direct = direct;

  final Database _db;
  final HistoryMembershipCheck _group;
  final PrivateConversations _direct;

  Future<HistoryMembershipCheck?> _policy(String conversationId) =>
      _db.transaction((tx) async {
        final kinds = await tx.query(
          '''
SELECT 'group' AS kind FROM social_conversations WHERE id=?
UNION ALL
SELECT 'direct' AS kind FROM direct_conversations WHERE id=?
''',
          [conversationId, conversationId],
        );
        if (kinds.length != 1) return null;
        return kinds.single['kind'] == 'direct' ? _direct : _group;
      });

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
