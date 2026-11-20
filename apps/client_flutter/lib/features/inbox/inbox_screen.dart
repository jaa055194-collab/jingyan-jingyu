import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/host_connection.dart';
import '../../net/notification_api.dart';

/// The host-confirmed outcome for one inbox row. Only a completed host write
/// ever produces one; an unknown result never fabricates a label.
class _RowOutcome {
  const _RowOutcome.accepted()
    : label = '已接受',
      failure = null;
  const _RowOutcome.denied()
    : label = '已拒绝',
      failure = null;
  const _RowOutcome.failed(this.failure) : label = null;

  final String? label;
  final String? failure;
}

/// Inbox surface backed by the host notifications route when a loader is
/// injected. Without a loader (no host connection) it keeps the honest gap
/// state instead of fabricating invitations.
///
/// Pending friend-request rows can be explicitly accepted or denied **only**
/// when the matching [acceptFriend]/[denyFriend] callback and a live
/// [actionContext] are wired. Every action first asks for an explicit
/// confirmation, then performs exactly one host write through the injected
/// callback (the existing `FriendsApi` transport, never a second one). Only the
/// acted-on row is updated, and only from a host-confirmed result: a success
/// shows 已接受/已拒绝, a failure shows an honest per-row failure with no
/// automatic retry. If the session/lock/account epoch changes while the
/// confirmation is open or the write is in flight, both the pending
/// confirmation and the late result are discarded — the screen never claims a
/// stale success. All other notification kinds stay read-only.
class InboxScreen extends StatefulWidget {
  const InboxScreen({
    super.key,
    this.loadNotifications,
    this.acceptFriend,
    this.denyFriend,
    this.actionContext,
    this.actionChanges,
  });

  final Future<List<NotificationItem>> Function()? loadNotifications;

  /// Injected host write for an explicit accept. Reuse `FriendsApi`.
  final Future<void> Function(String accountId)? acceptFriend;

  /// Injected host write for an explicit deny. Reuse `FriendsApi`.
  final Future<void> Function(String accountId)? denyFriend;

  /// Runtime-issued epoch for the authenticated, unlocked account. A null value
  /// means no action may be offered at all; a changed value means any pending
  /// confirmation or in-flight result is stale.
  final Object? Function()? actionContext;

  /// Notifies when the epoch may have changed (lock, logout, account switch).
  final Listenable? actionChanges;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  List<NotificationItem>? _items;
  bool _loading = false;
  String? _message;
  final _outcomes = <String, _RowOutcome>{};
  String? _busyRefId;
  bool get _refreshBlocked => _loading || _busyRefId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final load = widget.loadNotifications;
    if (!mounted || load == null || _refreshBlocked) return;
    setState(() {
      _loading = true;
      _message = null;
      _outcomes.clear();
    });
    try {
      final items = await load();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      final denied =
          error is HostRequestException &&
          (error.failure.code == FailureCode.forbidden ||
              error.failure.code == FailureCode.unauthenticated);
      setState(() {
        _items = null;
        _loading = false;
        _message = denied ? '未认证或无权限读取通知；不会自动重试' : '通知读取失败或结果未知；不会自动重试';
      });
    }
  }

  /// Only a pending friend request with a valid account id, a wired callback
  /// and a live session epoch may be acted on. Anything else stays read-only.
  bool _actionable(NotificationItem item) {
    if (item.kind != 'friendRequest' || item.status != 'pending') return false;
    if (_outcomes.containsKey(item.refId)) return false;
    if (widget.acceptFriend == null && widget.denyFriend == null) return false;
    if (widget.actionContext?.call() == null) return false;
    try {
      AccountId.parse(item.refId);
    } on FormatException {
      return false;
    }
    return true;
  }

  static String _failureCopy(Object error) {
    if (error is HostRequestException &&
        (error.failure.code == FailureCode.forbidden ||
            error.failure.code == FailureCode.unauthenticated)) {
      return '未认证或无权限处理邀请；不会自动重试';
    }
    if (error is FormatException) return '邀请处理响应无效；不会自动重试';
    return '邀请处理失败或结果未知；不会自动重试';
  }

  /// Ask for an explicit confirmation. Returns true only for a deliberate
  /// confirmation made against the same session epoch; a lock, logout or
  /// account change while the dialog is open closes it without a write.
  Future<bool> _confirm(
    NotificationItem item,
    Object token, {
    required bool accept,
  }) async {
    final changes = widget.actionChanges;
    final navigator = Navigator.of(context, rootNavigator: true);
    var invalidated = false;
    late final DialogRoute<bool> route;

    void finish(bool confirmed) {
      if (route.isCurrent && !invalidated) navigator.pop(confirmed);
    }

    route = DialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor:
          DialogTheme.of(context).barrierColor ??
          Theme.of(context).dialogTheme.barrierColor ??
          Colors.black54,
      builder: (_) => AlertDialog(
        key: const Key('inbox-confirm-dialog'),
        title: Text(accept ? '接受好友邀请？' : '拒绝好友邀请？'),
        content: Text(
          accept
              ? '将接受来自 ${item.refId} 的好友邀请。这会修改好友关系，需要宿主确认。'
              : '将拒绝来自 ${item.refId} 的好友邀请。这会修改好友关系，需要宿主确认。',
        ),
        actions: [
          TextButton(
            key: const Key('inbox-confirm-cancel'),
            onPressed: () => finish(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('inbox-confirm-ok'),
            onPressed: () => finish(true),
            child: Text(accept ? '确认接受' : '确认拒绝'),
          ),
        ],
      ),
    );

    void onChanged() {
      if (invalidated || (mounted && widget.actionContext?.call() == token)) {
        return;
      }
      invalidated = true;
      // A different route may be on top, or this notification may arrive
      // during a Navigator operation. Remove only this confirmation once.
      scheduleMicrotask(() {
        if (navigator.mounted && route.isActive) {
          navigator.removeRoute(route, false);
        }
      });
    }

    changes?.addListener(onChanged);
    try {
      final confirmed = await navigator.push(route);
      return !invalidated && confirmed == true && mounted;
    } finally {
      changes?.removeListener(onChanged);
    }
  }

  Future<void> _respond(NotificationItem item, {required bool accept}) async {
    final action = accept ? widget.acceptFriend : widget.denyFriend;
    final token = widget.actionContext?.call();
    if (action == null || token == null || _refreshBlocked) return;
    if (!_actionable(item)) return;

    if (!await _confirm(item, token, accept: accept)) return;
    if (!mounted || widget.actionContext?.call() != token) return;
    if (_refreshBlocked || !_actionable(item)) return;
    if (_items?.contains(item) != true) return;

    setState(() => _busyRefId = item.refId);
    var outcome = accept
        ? const _RowOutcome.accepted()
        : const _RowOutcome.denied();
    try {
      await action(item.refId);
    } catch (error) {
      outcome = _RowOutcome.failed(_failureCopy(error));
    }
    if (!mounted) return;
    final current = widget.actionContext?.call() == token;
    setState(() {
      _busyRefId = null;
      if (current) _outcomes[item.refId] = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loadNotifications == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inbox_outlined, size: 40),
              const SizedBox(height: 16),
              Text('收件箱', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                '当前未连接宿主，无法读取收件箱。',
                key: Key('inbox-gap'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              const Text(
                '连接后可查看待处理的好友邀请。',
                key: Key('inbox-after-wiring'),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              key: const Key('inbox-refresh'),
              onPressed: _refreshBlocked ? null : _load,
              icon: const Icon(Icons.refresh),
              label: Text(_message == null ? '刷新收件箱' : '重试读取'),
            ),
          ),
        ),
        Expanded(child: _connectedBody()),
      ],
    );
  }

  Widget _connectedBody() {
    if (_loading) {
      return Center(
        child: Semantics(
          liveRegion: true,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 8),
              Text('正在读取收件箱…'),
            ],
          ),
        ),
      );
    }
    if (_message != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _message!,
            key: const Key('inbox-message'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final items = _items ?? const <NotificationItem>[];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text('暂无新通知。', key: Key('inbox-empty'))),
          )
        else
          for (final item in items) _row(item),
        const SizedBox(height: 12),
        const Text(
          '仅「待确认」的好友邀请可在此处理：接受/拒绝需要再次确认，结果以宿主返回为准；'
          '其他通知只读。',
          key: Key('inbox-footer'),
        ),
      ],
    );
  }

  Widget _row(NotificationItem item) {
    final outcome = _outcomes[item.refId];
    final actionable = _actionable(item);
    final busy = _busyRefId != null;
    final trailing = <Widget>[];
    if (outcome?.label != null) {
      trailing.add(Text(outcome!.label!));
    } else if (actionable) {
      if (widget.acceptFriend != null) {
        trailing.add(
          TextButton(
            key: Key('inbox-accept-${item.refId}'),
            onPressed: busy ? null : () => _respond(item, accept: true),
            child: const Text('接受'),
          ),
        );
      }
      if (widget.denyFriend != null) {
        trailing.add(
          TextButton(
            key: Key('inbox-deny-${item.refId}'),
            onPressed: busy ? null : () => _respond(item, accept: false),
            child: const Text('拒绝'),
          ),
        );
      }
    } else {
      trailing.add(Text(item.status));
    }
    return ListTile(
      key: Key('notification-${item.refId}'),
      leading: const Icon(Icons.person_add_alt),
      title: Text(item.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('来自 ${item.refId} · ${item.createdAt}'),
          if (outcome?.failure != null)
            Semantics(
              liveRegion: true,
              child: Text(
                outcome!.failure!,
                key: Key('inbox-action-failure-${item.refId}'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      trailing: trailing.length == 1
          ? trailing.single
          : Row(mainAxisSize: MainAxisSize.min, children: trailing),
    );
  }
}
