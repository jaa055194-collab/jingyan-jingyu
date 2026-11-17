import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/friends_api.dart';
import '../../net/host_connection.dart';

/// Contacts surface.
///
/// When a [loadFriends] loader is injected it GETs the host friend list and
/// renders it, reporting loading/empty/denied/unknown honestly. Without a
/// loader the screen keeps the original honest empty state instead of
/// fabricating contacts. A read-only per-account lookup ([lookupState]) remains
/// available. Incoming pending invitations can be explicitly accepted/denied
/// only when [acceptFriend]/[denyFriend] are wired; every action is
/// user-triggered, refreshes the list afterwards and reports failures honestly.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({
    super.key,
    this.lookupState,
    this.loadFriends,
    this.acceptFriend,
    this.denyFriend,
  });

  final Future<FriendState> Function(String accountId)? lookupState;
  final Future<List<FriendContact>> Function()? loadFriends;
  final Future<void> Function(String accountId)? acceptFriend;
  final Future<void> Function(String accountId)? denyFriend;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _account = TextEditingController();
  String? _result;
  bool _busy = false;
  List<FriendContact>? _friends;
  bool _loadingFriends = false;
  String? _friendsMessage;
  String? _friendActionBusy;

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  @override
  void dispose() {
    _account.dispose();
    super.dispose();
  }

  Future<void> _loadFriends() async {
    final load = widget.loadFriends;
    if (load == null) return;
    setState(() {
      _loadingFriends = true;
      _friendsMessage = null;
    });
    try {
      final contacts = await load();
      if (!mounted) return;
      setState(() {
        _friends = contacts;
        _friendsMessage = null;
        _loadingFriends = false;
      });
    } catch (error) {
      if (!mounted) return;
      final denied =
          error is HostRequestException &&
          (error.failure.code == FailureCode.forbidden ||
              error.failure.code == FailureCode.unauthenticated);
      setState(() {
        _friends = null;
        _friendsMessage = denied
            ? '未认证或无权限读取好友列表；不会自动重试'
            : '好友列表读取失败或结果未知；不会自动重试';
        _loadingFriends = false;
      });
    }
  }

  static String _label(FriendState state) => switch (state) {
    FriendState.none => '未添加',
    FriendState.outgoingPending => '已发出请求，待对方确认',
    FriendState.incomingPending => '对方请求添加你',
    FriendState.friends => '好友',
    FriendState.blocked => '已拉黑/被拉黑',
  };

  Future<void> _lookup() async {
    final lookup = widget.lookupState;
    final id = _account.text.trim();
    if (lookup == null || id.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final state = await lookup(id);
      if (!mounted) return;
      setState(() => _result = '关系状态：${_label(state)}');
    } catch (_) {
      // Never surface upstream/response material.
      if (!mounted) return;
      setState(() => _result = '查询失败，请稍后重试；不会自动重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _respondFriend(
    FriendContact contact, {
    required bool accept,
  }) async {
    final action = accept ? widget.acceptFriend : widget.denyFriend;
    if (action == null || _friendActionBusy != null) return;
    setState(() => _friendActionBusy = contact.accountId);
    try {
      await action(contact.accountId);
      if (!mounted) return;
      setState(() {
        _friendActionBusy = null;
        _friendsMessage = null;
      });
      await _loadFriends();
    } catch (error) {
      if (!mounted) return;
      final denied =
          error is HostRequestException &&
          (error.failure.code == FailureCode.forbidden ||
              error.failure.code == FailureCode.unauthenticated);
      setState(() {
        _friendActionBusy = null;
        _friendsMessage = denied
            ? '未认证或无权限处理邀请；不会自动重试'
            : error is FormatException
            ? '好友操作响应无效；不会自动重试'
            : '好友操作失败或结果未知；不会自动重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.people_outline, size: 40),
              const SizedBox(height: 16),
              Text('联系人', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                '数据来自宿主实时读取；仅显式点击「接受/拒绝」处理好友邀请，其余只读。',
                key: Key('contacts-live-note'),
              ),
              if (widget.loadFriends == null)
                const Text(
                  '宿主未提供好友列表路由；接入好友列表后可在此显示。',
                  textAlign: TextAlign.center,
                )
              else if (_loadingFriends)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: CircularProgressIndicator(),
                )
              else if (_friendsMessage != null)
                Text(_friendsMessage!, textAlign: TextAlign.center)
              else if (_friends != null) ...[
                if (_friends!.isEmpty)
                  const Text('暂无好友；这不代表没有待处理请求。', textAlign: TextAlign.center)
                else
                  for (final friend in _friends!)
                    ListTile(
                      key: Key('contacts-friend-${friend.accountId}'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_outline),
                      title: Text(friend.displayName),
                      subtitle: Text(
                        '${friend.accountId} · ${_label(friend.state)}',
                      ),
                      trailing: friend.state == FriendState.incomingPending
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextButton(
                                  key: Key('friend-accept-${friend.accountId}'),
                                  onPressed:
                                      _friendActionBusy == null &&
                                          widget.acceptFriend != null
                                      ? () =>
                                            _respondFriend(friend, accept: true)
                                      : null,
                                  child: const Text('接受'),
                                ),
                                TextButton(
                                  key: Key('friend-deny-${friend.accountId}'),
                                  onPressed:
                                      _friendActionBusy == null &&
                                          widget.denyFriend != null
                                      ? () => _respondFriend(
                                          friend,
                                          accept: false,
                                        )
                                      : null,
                                  child: const Text('拒绝'),
                                ),
                              ],
                            )
                          : null,
                    ),
              ],
              if (widget.lookupState != null) ...[
                const SizedBox(height: 20),
                TextField(
                  key: const Key('contacts-account-id'),
                  controller: _account,
                  decoration: const InputDecoration(
                    labelText: '按账号 ID 查询关系',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('contacts-query'),
                  onPressed: _busy ? null : _lookup,
                  child: const Text('查询关系'),
                ),
                if (_result != null) ...[
                  const SizedBox(height: 12),
                  Text(_result!),
                ],
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
