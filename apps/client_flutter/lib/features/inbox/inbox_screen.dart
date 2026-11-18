import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/host_connection.dart';
import '../../net/notification_api.dart';

/// Inbox surface backed by the host notifications route when a loader is
/// injected. Without a loader (no host connection) it keeps the honest gap
/// state instead of fabricating invitations. Rendered items are metadata only;
/// this screen never performs relationship mutations or navigates on tap.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key, this.loadNotifications});

  final Future<List<NotificationItem>> Function()? loadNotifications;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  List<NotificationItem>? _items;
  bool _loading = false;
  bool _unbound = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final load = widget.loadNotifications;
    if (load == null) {
      if (mounted) setState(() => _unbound = true);
      return;
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _message = null;
      });
    }
    try {
      final items = await load();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _unbound = false;
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
        _unbound = false;
        _message = denied ? '未认证或无权限读取通知；不会自动重试' : '通知读取失败或结果未知；不会自动重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unbound) {
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
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
          for (final item in items)
            ListTile(
              key: Key('notification-${item.refId}'),
              leading: const Icon(Icons.person_add_alt),
              title: Text(item.title),
              subtitle: Text('来自 ${item.refId} · ${item.createdAt}'),
              trailing: Text(item.status),
            ),
        const SizedBox(height: 12),
        const Text('本页只读，不修改好友关系。'),
      ],
    );
  }
}
