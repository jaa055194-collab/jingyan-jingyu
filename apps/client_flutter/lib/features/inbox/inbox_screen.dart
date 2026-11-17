import 'package:material_ui/material_ui.dart';

/// Inbox surface. The host currently has no inbox/notification route, so this
/// screen shows an honest unavailable/empty state rather than fabricating
/// invitations or notifications.
class InboxScreen extends StatelessWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context) => Center(
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
            '当前缺口：宿主未提供收件箱/通知路由。',
            key: Key('inbox-gap'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          const Text(
            '接入后此处将显示邀请与通知；数据来自宿主实时读取。',
            key: Key('inbox-after-wiring'),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}
