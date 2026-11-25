import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../app/status_panel.dart';

/// Android's entry for each owned AI. Opening it performs no host request.
class AndroidAiDirectoryScreen extends StatefulWidget {
  const AndroidAiDirectoryScreen({
    super.key,
    required this.model,
    required this.onOpenAi,
    this.onOpenPrivateChat,
  });

  final ShellViewModel model;
  final void Function(ShellOwnedAi ai, Object interaction) onOpenAi;
  final void Function(ShellOwnedAi ai, Object interaction)? onOpenPrivateChat;

  @override
  State<AndroidAiDirectoryScreen> createState() =>
      _AndroidAiDirectoryScreenState();
}

class _AndroidAiDirectoryScreenState extends State<AndroidAiDirectoryScreen> {
  ShellViewModel get model => widget.model;
  late final _session = model.ownAiSessionContext;
  late final _owner = model.connectedAccountId;
  bool _lost = false;
  bool _refreshing = false;
  String? _refreshError;

  bool get _current =>
      !_lost &&
      model.authenticated &&
      !model.locked &&
      model.connectedAccountId == _owner &&
      model.ownAiSessionContext == _session;

  @override
  void initState() {
    super.initState();
    _lost = !_current;
    model.addListener(_sessionChanged);
  }

  @override
  void dispose() {
    model.removeListener(_sessionChanged);
    super.dispose();
  }

  void _sessionChanged() {
    if (!_lost && !_current) setState(() => _lost = true);
  }

  bool _canWrite(Object? interaction) =>
      mounted &&
      _current &&
      model.online &&
      !model.busy &&
      interaction != null &&
      identical(model.ownAiDirectContext, interaction);

  bool _sameAi(ShellOwnedAi ai) => model.ownAiAccounts.any(
    (row) =>
        row.accountId == ai.accountId &&
        row.displayName == ai.displayName &&
        row.disabled == ai.disabled,
  );

  /// Refreshes from this page and keeps the outcome on it: the shell's error
  /// banner sits under this route and cannot be seen from here.
  Future<void> _refresh(Object? interaction) async {
    if (_refreshing || !_canWrite(interaction)) return;
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });
    try {
      await model.loadOwnAi();
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
          _refreshError = _current ? model.error : null;
        });
      }
    }
  }

  /// Hides a failed refresh. The same text also waits in the shell's banner
  /// under this route, so it is cleared there too unless a newer error has
  /// replaced it.
  void _dismissRefreshError() {
    final shown = _refreshError;
    setState(() => _refreshError = null);
    if (shown != null && model.error == shown) model.clearError();
  }

  Future<void> _confirmRemove(ShellOwnedAi ai, Object? interaction) async {
    bool current() => _canWrite(interaction) && _sameAi(ai);
    if (!current()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ListenableBuilder(
        listenable: model,
        builder: (_, _) => !current()
            ? _expired(dialogContext)
            : AlertDialog(
                title: const Text('移除这个 AI？'),
                content: Text(
                  '将从“我的 AI”移除「${ai.displayName}」并停止使用。'
                  '不会删除服务器上已有的聊天记录或其他历史；此操作不可撤销。',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    key: const Key('android-ai-remove-confirm'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(dialogContext)
                          .colorScheme
                          .error,
                      foregroundColor: Theme.of(dialogContext)
                          .colorScheme
                          .onError,
                    ),
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('确认移除'),
                  ),
                ],
              ),
      ),
    );
    if (confirmed != true || !current()) return;
    await model.removeOwnAi(ai.accountId);
    _showError();
  }

  Future<void> _create(Object? interaction) async {
    if (!_canWrite(interaction)) return;
    var text = '';
    String? error;
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => ListenableBuilder(
        listenable: model,
        builder: (_, _) => !_canWrite(interaction)
            ? _expired(dialogContext)
            : StatefulBuilder(
                builder: (_, setState) => AlertDialog(
                  title: const Text('创建 AI 账户'),
                  content: TextFormField(
                    key: const Key('android-ai-create-name'),
                    autofocus: true,
                    maxLength: 100,
                    onChanged: (value) => text = value,
                    decoration: InputDecoration(
                      labelText: '名称',
                      errorText: error,
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      key: const Key('android-ai-create-confirm'),
                      onPressed: () {
                        final trimmed = text.trim();
                        if (trimmed.isEmpty || trimmed.length > 100) {
                          setState(() => error = '名称须为 1–100 个字符');
                          return;
                        }
                        Navigator.pop(dialogContext, trimmed);
                      },
                      child: const Text('创建'),
                    ),
                  ],
                ),
              ),
      ),
    );
    if (name == null || !_canWrite(interaction)) return;
    await model.createOwnAi(name);
    _showError();
  }

  void _showError() {
    if (mounted && _current && model.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(model.error!)));
    }
  }

  Widget _expired(BuildContext dialogContext) => AlertDialog(
    title: const Text('此操作已失效'),
    content: const Text('请返回列表后重新操作。'),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('关闭'),
      ),
    ],
  );

  /// Why host-backed rows cannot be used right now, or null when they can.
  String? _hostReason(Object? interaction) {
    if (!model.online) return '需要连接宿主';
    if (model.busy) return '请等当前操作完成';
    if (interaction == null) return '暂时无法使用';
    return null;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('我的 AI')),
    body: ListenableBuilder(
      listenable: model,
      builder: (_, _) {
        if (!_current) {
          return const StatusPanel(
            fill: true,
            icon: Icons.lock_outline,
            title: '账号或解锁状态已变更，请返回后重新打开。',
          );
        }
        final interaction = model.ownAiDirectContext;
        final canWrite = _canWrite(interaction);
        final chatAvailable = onChatAvailable(interaction);
        final hostReason = _hostReason(interaction);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('在手机上与自己的 AI 私聊，或管理其模型、人格和活人感设置。'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton.icon(
                  key: const Key('android-ai-directory-refresh'),
                  onPressed: canWrite && !_refreshing
                      ? () => _refresh(interaction)
                      : null,
                  icon: _refreshing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(_refreshing ? '正在刷新…' : '刷新我的 AI'),
                ),
                FilledButton.icon(
                  key: const Key('android-ai-directory-create'),
                  onPressed: canWrite ? () => _create(interaction) : null,
                  icon: const Icon(Icons.add),
                  label: const Text('创建 AI 账户'),
                ),
              ],
            ),
            if (!model.online)
              const _InlineNote(
                key: Key('android-ai-directory-offline'),
                icon: Icons.cloud_off_outlined,
                text: '宿主未连接：已设置的本机私聊仍可使用。管理宿主配置需要联网。',
              ),
            if (_refreshError case final error?)
              StatusPanel(
                key: const Key('android-ai-directory-error'),
                tone: StatusTone.error,
                icon: Icons.error_outline,
                title: '没能刷新我的 AI',
                detail: error,
                action: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton(
                      key: const Key('android-ai-directory-retry'),
                      onPressed: canWrite && !_refreshing
                          ? () => _refresh(interaction)
                          : null,
                      child: const Text('重试'),
                    ),
                    TextButton(
                      key: const Key('android-ai-directory-error-dismiss'),
                      onPressed: _dismissRefreshError,
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
            if (model.ownAiNotice case final notice?)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText(notice),
              ),
            if (model.ownAiAccounts.isEmpty && _refreshError == null)
              model.ownAiLoaded
                  ? const StatusPanel(
                      key: Key('android-ai-directory-empty'),
                      icon: Icons.smart_toy_outlined,
                      title: '你还没有 AI 账户',
                      detail: '创建后，可以在这里与它私聊，或管理它的模型与人格。',
                    )
                  : StatusPanel(
                      key: const Key('android-ai-directory-unloaded'),
                      tone: model.online
                          ? StatusTone.empty
                          : StatusTone.offline,
                      icon: Icons.cloud_download_outlined,
                      title: '尚未读取 AI 列表',
                      detail: model.online
                          ? '点“刷新我的 AI”，从宿主读取。'
                          : '连接宿主后，点“刷新我的 AI”读取。',
                    ),
            for (final ai in model.ownAiAccounts)
              Card(
                key: Key('android-ai-row-${ai.accountId}'),
                child: Column(
                  children: [
                    ListTile(
                      title: Text(ai.displayName),
                      subtitle: ai.disabled ? const Text('已停用') : null,
                    ),
                    if (!ai.disabled) ...[
                      ListTile(
                        key: Key('android-ai-open-chat-${ai.accountId}'),
                        leading: const Icon(Icons.forum_outlined),
                        trailing: const Icon(Icons.chevron_right),
                        title: const Text('私聊我的 AI'),
                        subtitle: Text(
                          chatAvailable
                              ? '直连模型服务；设置好后，宿主离线也能用'
                              : model.busy
                              ? '请等当前操作完成'
                              : '暂时无法打开',
                        ),
                        enabled: chatAvailable,
                        onTap: chatAvailable && interaction != null
                            ? () => widget.onOpenPrivateChat!(ai, interaction)
                            : null,
                      ),
                      ListTile(
                        key: Key('android-ai-open-config-${ai.accountId}'),
                        leading: const Icon(Icons.tune_outlined),
                        trailing: const Icon(Icons.chevron_right),
                        title: const Text('模型、人格与活人感'),
                        subtitle: Text(hostReason ?? '读取和修改宿主上保存的配置'),
                        enabled: canWrite,
                        onTap: canWrite && interaction != null
                            ? () => widget.onOpenAi(ai, interaction)
                            : null,
                      ),
                    ],
                    ListTile(
                      key: Key('android-ai-remove-${ai.accountId}'),
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('从我的 AI 移除'),
                      subtitle: const Text('停止使用；不删除已有聊天或共享历史'),
                      enabled: canWrite,
                      onTap: canWrite
                          ? () => _confirmRemove(ai, interaction)
                          : null,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );

  bool onChatAvailable(Object? interaction) =>
      widget.onOpenPrivateChat != null && interaction != null && !model.busy;
}

/// A one-line explanation that stays in the list flow, for a condition that
/// limits some rows without replacing the whole page.
class _InlineNote extends StatelessWidget {
  const _InlineNote({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
