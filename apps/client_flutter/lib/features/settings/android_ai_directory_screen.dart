import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';

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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('我的 AI')),
    body: ListenableBuilder(
      listenable: model,
      builder: (_, _) {
        if (!_current) {
          return const Center(child: Text('账号或解锁状态已变更，请返回后重新打开。'));
        }
        final interaction = model.ownAiDirectContext;
        final canWrite = _canWrite(interaction);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('在手机上与自己的 AI 私聊，或管理其模型、人格和活人感设置。'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  key: const Key('android-ai-directory-refresh'),
                  onPressed: canWrite ? model.loadOwnAi : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新我的 AI'),
                ),
                FilledButton.icon(
                  key: const Key('android-ai-directory-create'),
                  onPressed: canWrite ? () => _create(interaction) : null,
                  icon: const Icon(Icons.add),
                  label: const Text('创建 AI 账户'),
                ),
              ],
            ),
            if (model.ownAiNotice case final notice?)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText(notice),
              ),
            if (!model.online) const Text('宿主未连接：已设置的本机私聊仍可使用。管理宿主配置需要联网。'),
            if (model.ownAiAccounts.isEmpty)
              Text(model.ownAiLoaded ? '你还没有 AI 账户。' : '尚未加载，请刷新我的 AI。'),
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
                        title: const Text('私聊我的 AI'),
                        subtitle: const Text('查看当前模型与人格'),
                        enabled: onChatAvailable(interaction),
                        onTap:
                            onChatAvailable(interaction) && interaction != null
                            ? () => widget.onOpenPrivateChat!(ai, interaction)
                            : null,
                      ),
                      ListTile(
                        key: Key('android-ai-open-config-${ai.accountId}'),
                        leading: const Icon(Icons.tune_outlined),
                        title: const Text('模型、人格与活人感'),
                        subtitle: const Text('读取和修改宿主已保存配置'),
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
