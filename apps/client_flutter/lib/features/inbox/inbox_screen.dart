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
          const Text('宿主尚未提供收件箱接口；邀请与通知在接入后显示。', textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
