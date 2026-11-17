import 'package:material_ui/material_ui.dart';

import '../../net/friends_api.dart';

/// Contacts surface. The host currently exposes only a per-account friendship
/// state lookup (`GET /friends/{accountId}`), not a friend list. When no lookup
/// callback is wired, this screen shows an honest empty state instead of
/// fabricating contacts. A read-only lookup by account id is provided when a
/// callback is supplied, so the surface is testable without inventing data.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, this.lookupState});

  final Future<FriendState> Function(String accountId)? lookupState;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _account = TextEditingController();
  String? _result;
  bool _busy = false;

  @override
  void dispose() {
    _account.dispose();
    super.dispose();
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
                '宿主未提供好友列表路由；接入好友列表后可在此显示。',
                textAlign: TextAlign.center,
              ),
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
