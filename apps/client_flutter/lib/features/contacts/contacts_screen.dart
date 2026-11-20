import 'dart:async';

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
/// Outgoing requests require a known account ID and a separate confirmation.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({
    super.key,
    this.lookupState,
    this.loadFriends,
    this.acceptFriend,
    this.denyFriend,
    this.requestFriend,
    this.requestContext,
    this.requestChanges,
    this.navigationGeneration,
  });

  final Future<FriendState> Function(String accountId)? lookupState;
  final Future<List<FriendContact>> Function()? loadFriends;
  final Future<void> Function(String accountId)? acceptFriend;
  final Future<void> Function(String accountId)? denyFriend;
  final Future<void> Function(String accountId)? requestFriend;

  /// Live signed-in identity and session/lock scope (null when unavailable).
  final ({String accountId, Object session})? Function()? requestContext;

  /// Notifies on either session or navigation changes.
  final Listenable? requestChanges;
  final int Function()? navigationGeneration;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _account = TextEditingController();
  final _requestAccount = TextEditingController();
  bool _requestActive = false;
  bool _requestSending = false;
  String? _requestIdError;
  ({String text, Object scope})? _requestResult;
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
    _requestAccount.dispose();
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
    if (action == null || _friendActionBusy != null || _requestActive) return;
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

  Future<void> _reviewRequest() async {
    final send = widget.requestFriend;
    final scope = widget.requestContext?.call();
    final navigationGeneration = widget.navigationGeneration;
    final source = ModalRoute.of(context);
    if (send == null ||
        scope == null ||
        source?.isCurrent != true ||
        _requestActive ||
        _friendActionBusy != null) {
      return;
    }
    final String target;
    try {
      target = AccountId.parse(_requestAccount.text).value;
    } on FormatException {
      setState(() => _requestIdError = '请输入有效账号 ID（1–64 位字母、数字、下划线或连字符）。');
      return;
    }
    if (target == scope.accountId) {
      setState(() => _requestIdError = '不能向当前账号发送好友请求。');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _requestActive = true;
      _requestResult = null;
    });
    final changes = widget.requestChanges;
    final navigator = Navigator.of(context, rootNavigator: true);
    var invalidated = false;
    var confirming = true;
    var confirmedInDialog = false;
    final openedAt = navigationGeneration?.call();
    final dialogAt = openedAt == null ? null : openedAt + 1;
    final returnedAt = openedAt == null ? null : openedAt + 2;
    late final DialogRoute<bool> dialog;

    bool sameSession() => mounted && widget.requestContext?.call() == scope;
    bool currentSource() =>
        sameSession() &&
        source!.isCurrent &&
        navigationGeneration?.call() == returnedAt;

    void invalidate() {
      if (invalidated) return;
      invalidated = true;
      if (confirming) {
        scheduleMicrotask(() {
          // Remove only this confirmation, not whatever route is above it.
          if (navigator.mounted && dialog.isActive) {
            navigator.removeRoute(dialog, false);
          }
        });
      }
    }

    void onChange() {
      if (!sameSession()) {
        invalidate();
        return;
      }
      final generation = navigationGeneration?.call();
      if (confirming) {
        // Only our confirm button's pop may advance the generation back to
        // the source. A push above this dialog can also increment it once.
        final returning =
            confirmedInDialog && generation == returnedAt && source!.isCurrent;
        if (generation != dialogAt && !returning) invalidate();
      } else if (!currentSource()) {
        invalidate();
      }
    }

    dialog = DialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor: DialogTheme.of(context).barrierColor ?? Colors.black54,
      builder: (_) => AlertDialog(
        key: const Key('contacts-request-confirmation'),
        title: const Text('发送好友请求？'),
        scrollable: true,
        content: Text('从 ${scope.accountId} 向 $target 发送好友请求。对方同意后才会成为好友。'),
        actions: [
          TextButton(
            key: const Key('contacts-request-cancel'),
            onPressed: () {
              if (dialog.isCurrent && !invalidated) navigator.pop(false);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('contacts-request-send'),
            onPressed: () {
              if (!dialog.isCurrent || invalidated || confirmedInDialog) return;
              if (!sameSession() ||
                  navigationGeneration?.call() != dialogAt ||
                  _requestAccount.text != target) {
                invalidate();
                return;
              }
              confirmedInDialog = true;
              navigator.pop(true);
            },
            child: const Text('确认发送'),
          ),
        ],
      ),
    );

    changes?.addListener(onChange);
    try {
      final confirmed = await navigator.push(dialog);
      confirming = false;
      if (confirmed != true ||
          !confirmedInDialog ||
          invalidated ||
          !currentSource() ||
          _requestAccount.text != target) {
        return;
      }
      setState(() => _requestSending = true);
      var message = '宿主已确认收到发给 $target 的请求；不代表对方已同意。';
      try {
        await send(target);
      } on HostRequestException catch (error) {
        message = switch (error.failure.code) {
          FailureCode.unauthenticated ||
          FailureCode.forbidden => '未认证或无权限发送好友请求；不会自动重试。',
          FailureCode.invalidArgument ||
          FailureCode.notFound ||
          FailureCode.conflict => '宿主未受理此好友请求；请核对账号 ID 或关系状态。不会自动重试。',
          _ => '好友请求结果未确认；不会自动重试。',
        };
      } catch (_) {
        message = '好友请求结果未确认；不会自动重试。';
      }
      if (!invalidated && currentSource()) {
        setState(() => _requestResult = (text: message, scope: scope));
      }
    } finally {
      changes?.removeListener(onChange);
      if (mounted) {
        setState(() {
          _requestSending = false;
          _requestActive = false;
        });
      }
    }
  }

  Widget _requestForm(BuildContext context, Object scope) {
    final result = _requestResult;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Text('发起好友请求', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('输入对方提供的账号 ID。请求需对方同意，不会自动开启聊天。'),
        const SizedBox(height: 12),
        TextField(
          key: const Key('contacts-request-account'),
          controller: _requestAccount,
          enabled: !_requestActive,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: '对方的账号 ID',
            border: const OutlineInputBorder(),
            errorText: _requestIdError,
          ),
          onChanged: (_) => setState(() {
            _requestIdError = null;
            _requestResult = null;
          }),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton(
            key: const Key('contacts-request-review'),
            onPressed: _requestActive || _friendActionBusy != null
                ? null
                : _reviewRequest,
            child: Text(_requestSending ? '正在发送…' : '核对好友请求'),
          ),
        ),
        if (result != null && result.scope == scope)
          Semantics(
            liveRegion: true,
            child: Text(result.text, key: const Key('contacts-request-result')),
          ),
      ],
    );
  }

  // Account names may contain controls per the host contract. Only the
  // rendered label changes; the DTO and account ID are kept intact.
  static final _displayControls = RegExp(r'[\x00-\x1f\x7f-\x9f]');

  static String _contactTitle(FriendContact friend) {
    final display = friend.displayName.replaceAll(_displayControls, ' ');
    return display.trim().isEmpty ? friend.accountId : display;
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
              Text(
                widget.requestFriend == null
                    ? '数据来自宿主实时读取；仅显式点击「接受/拒绝」处理好友邀请，其余只读。'
                    : '数据来自宿主实时读取；可接受或拒绝来信，也可核对账号 ID 后确认发送好友请求。',
                key: const Key('contacts-live-note'),
              ),
              if (widget.loadFriends == null)
                const Text('当前未连接宿主，无法读取联系人。', textAlign: TextAlign.center)
              else if (_loadingFriends)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: CircularProgressIndicator(),
                )
              else if (_friendsMessage != null)
                Text(_friendsMessage!, textAlign: TextAlign.center)
              else if (_friends != null) ...[
                if (_friends!.isEmpty)
                  const Text('暂无联系人或待处理的好友邀请。', textAlign: TextAlign.center)
                else
                  for (final friend in _friends!)
                    ListTile(
                      key: Key('contacts-friend-${friend.accountId}'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_outline),
                      title: Text(_contactTitle(friend)),
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
                                      !_requestActive &&
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
                                      !_requestActive &&
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
              if (widget.requestFriend != null)
                if (widget.requestContext?.call() case final scope?)
                  _requestForm(context, scope),
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
