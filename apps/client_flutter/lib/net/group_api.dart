import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// Canonical group metadata returned by the host, not a locally invented group.
class HostGroup {
  const HostGroup({
    required this.id,
    required this.name,
    required this.ownerAccountId,
    required this.historyVisibility,
  });
  final String id;
  final String name;
  final String ownerAccountId;
  final String historyVisibility;

  factory HostGroup.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final owner = json['ownerAccountId'];
    final visibility = json['historyVisibility'];
    if (id is! String ||
        owner is! String ||
        name is! String ||
        name.trim().isEmpty ||
        name.trim() != name ||
        name.length > 100 ||
        json['kind'] != 'group' ||
        (visibility != 'all' && visibility != 'joined')) {
      throw const FormatException('宿主群会话响应无效');
    }
    return HostGroup(
      id: ConversationId.parse(id).value,
      name: name,
      ownerAccountId: AccountId.parse(owner).value,
      historyVisibility: visibility as String,
    );
  }
}

/// Explicit online group operations; no local queue, retries or enumeration.
/// Existing connection authentication renewal is retained. A failed/uncertain
/// create may already have committed: callers must not silently recreate it.
class GroupApi {
  GroupApi(this._connection);
  final HostConnection _connection;

  Future<HostGroup> createGroup(String name) async {
    if (name.length > 100 || name.trim().isEmpty) {
      throw const FormatException('群名须为1–100个字符');
    }
    final response = await _connection.request(
      'POST',
      Routes.conversations,
      body: {'name': name.trim(), 'kind': 'group', 'historyVisibility': 'all'},
    );
    return HostGroup.fromJson(response);
  }

  /// Add one explicitly known account. The host enforces group-owner authority;
  /// group creation and member additions are deliberately separate operations.
  Future<void> addMember(String groupId, String accountId) async {
    final group = ConversationId.parse(groupId).value;
    final member = AccountId.parse(accountId).value;
    await _connection.request(
      'POST',
      Routes.conversationMembers.replaceFirst('{conversationId}', group),
      body: {'accountId': member},
      allowEmptySuccess: true,
    );
  }
}
