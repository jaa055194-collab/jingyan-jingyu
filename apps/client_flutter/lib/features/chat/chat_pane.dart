import 'package:material_ui/material_ui.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../../app/shell_view_model.dart';

class ConversationList extends StatelessWidget {
  const ConversationList({
    super.key,
    required this.model,
    required this.onSelected,
  });
  final ShellViewModel model;
  final ValueChanged<String> onSelected;
  Future<void> create(BuildContext context) async {
    final before = model.selectedConversationId;
    await showDialog<void>(
      context: context,
      builder: (_) => _GroupActionDialog(model: model),
    );
    final selected = model.selectedConversationId;
    if (context.mounted &&
        selected != null &&
        selected != before &&
        model.error == null) {
      onSelected(selected);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton.icon(
          key: const Key('create-group'),
          onPressed:
              model.authenticated &&
                  model.online &&
                  !model.locked &&
                  !model.busy
              ? () => create(context)
              : null,
          icon: const Icon(Icons.group_add_outlined),
          label: const Text('创建群聊'),
        ),
      ),
      TextButton.icon(
        key: const Key('refresh-conversations'),
        onPressed: model.authenticated && !model.locked && !model.busy
            ? model.refreshConversations
            : null,
        icon: const Icon(Icons.refresh),
        label: const Text('刷新会话'),
      ),
      Expanded(
        child: model.conversations.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '暂无会话\n连接宿主后，将显示可用的聊天。',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView(
                children: [
                  for (final conversation in model.conversations)
                    ListTile(
                      key: ValueKey(conversation.id),
                      selected: model.selectedConversationId == conversation.id,
                      leading: CircleAvatar(
                        child: Text(
                          conversation.title.isEmpty
                              ? '?'
                              : conversation.title.characters.first,
                        ),
                      ),
                      title: Text(conversation.title),
                      subtitle: Text(
                        conversation.preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: conversation.unread > 0
                          ? Badge(label: Text('${conversation.unread}'))
                          : null,
                      onTap: model.busy
                          ? null
                          : () => onSelected(conversation.id),
                    ),
                ],
              ),
      ),
    ],
  );
}

class _GroupActionDialog extends StatefulWidget {
  const _GroupActionDialog({required this.model, this.groupId});
  final ShellViewModel model;
  final String? groupId;
  @override
  State<_GroupActionDialog> createState() => _GroupActionDialogState();
}

class _GroupActionDialogState extends State<_GroupActionDialog> {
  final input = TextEditingController();
  final form = GlobalKey<FormState>();
  bool submitting = false;
  String? failure;
  late final String? initialAccount;
  bool invalidated = false;
  bool get adding => widget.groupId != null;
  @override
  void initState() {
    super.initState();
    initialAccount = widget.model.connectedAccountId;
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final model = widget.model;
    if (invalidated ||
        submitting ||
        model.busy ||
        !model.authenticated ||
        model.locked ||
        !model.online ||
        form.currentState?.validate() != true) {
      return;
    }
    setState(() {
      submitting = true;
      failure = null;
    });
    if (adding) {
      await model.addGroupMember(widget.groupId!, input.text.trim());
    } else {
      await model.createGroup(input.text);
    }
    if (!mounted || invalidated) return;
    if (model.authenticated &&
        !model.locked &&
        model.error == null &&
        (adding || model.selectedConversationId != null)) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        submitting = false;
        failure = model.error ?? '会话已变化，请重新操作';
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final model = widget.model;
      if (!model.authenticated ||
          model.locked ||
          model.connectedAccountId != initialAccount) {
        invalidated = true;
      }
      if (invalidated) {
        return AlertDialog(
          title: const Text('会话已锁定或登录已变化'),
          content: const Text('已隐藏输入，请关闭后重新操作。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      }
      final permitted = model.authenticated && !model.locked && model.online;
      return PopScope(
        canPop: !submitting,
        child: AlertDialog(
          title: Text(adding ? '添加群成员' : '创建群聊'),
          content: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    adding ? '输入对方已知的账户 ID。仅群主可添加成员。' : '先创建群聊，再单独添加已知账户 ID。',
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: Key(adding ? 'member-account-id' : 'group-name'),
                    controller: input,
                    autofocus: true,
                    enabled: permitted && !submitting,
                    decoration: InputDecoration(
                      labelText: adding ? '账户 ID' : '群名称',
                    ),
                    validator: (value) {
                      final text = value ?? '';
                      if (!adding) {
                        return text.trim().isEmpty || text.length > 100
                            ? '请输入1–100个字符的群名'
                            : null;
                      }
                      try {
                        AccountId.parse(text.trim());
                        return null;
                      } on FormatException {
                        return '请输入有效账户 ID';
                      }
                    },
                    onFieldSubmitted: (_) => submit(),
                  ),
                  if (!permitted) const Text('请解锁并重新连接宿主后操作。'),
                  if (failure != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        failure!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (submitting)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: Key(adding ? 'confirm-add-member' : 'confirm-create-group'),
              onPressed: permitted && !submitting && !model.busy
                  ? submit
                  : null,
              child: Text(adding ? '添加' : '创建'),
            ),
          ],
        ),
      );
    },
  );
}

class ChatPane extends StatefulWidget {
  const ChatPane({super.key, required this.model, this.onBack});
  final ShellViewModel model;
  final VoidCallback? onBack;
  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane> {
  final composer = TextEditingController();
  @override
  void dispose() {
    composer.dispose();
    super.dispose();
  }

  Future<void> attach(String kind) async {
    final model = widget.model;
    if (!model.aiConsentGranted) {
      final granted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('允许 AI 读取附件？'),
          content: const Text(
            '你选择的图片或文件可能发送至宿主配置的 AI 服务，用于理解附件内容。仅在你明确允许后继续。可在设置中撤销。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('暂不允许'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('允许并继续'),
            ),
          ],
        ),
      );
      if (granted != true || !mounted) return;
      await model.setAiConsent(true);
      if (!model.aiConsentGranted || model.error != null || !mounted) return;
    }
    await model.attachFile(kind);
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    if (model.selectedConversationId == null) {
      return const Center(child: Text('选择一个会话，开始聊天'));
    }
    if (composer.text != model.draft) {
      composer.value = TextEditingValue(
        text: model.draft,
        selection: TextSelection.collapsed(offset: model.draft.length),
      );
    }
    final selected = model.conversations.where(
      (c) => c.id == model.selectedConversationId,
    );
    final title = selected.isEmpty ? '聊天' : selected.first.title;
    return Column(
      children: [
        ListTile(
          leading: widget.onBack == null
              ? null
              : IconButton(
                  tooltip: '返回会话列表',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onBack,
                ),
          title: Text(title),
          subtitle: Text(model.online ? '已连接' : '离线 · 消息将加入待发送队列'),
          trailing: model.canAddMembersToSelectedGroup
              ? IconButton(
                  key: const Key('add-group-member'),
                  tooltip: '添加成员',
                  icon: const Icon(Icons.person_add_outlined),
                  onPressed: !model.busy && model.online && !model.locked
                      ? () => showDialog<void>(
                          context: context,
                          builder: (_) => _GroupActionDialog(
                            model: model,
                            groupId: model.selectedConversationId,
                          ),
                        )
                      : null,
                )
              : null,
        ),
        const Divider(height: 1),
        if (model.queuedCount > 0)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '${model.queuedCount} 条待发送 · 联网后自动重试',
              key: const Key('queue-status'),
            ),
          ),
        Expanded(
          child: model.messages.isEmpty
              ? const Center(child: Text('还没有消息'))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: model.messages.length,
                  itemBuilder: (context, index) {
                    final message = model.messages[index];
                    return Align(
                      alignment: message.outgoing
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: message.outgoing
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SelectableText(message.text),
                              const SizedBox(height: 4),
                              Text(
                                message.status,
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '添加图片',
                onPressed: model.busy ? null : () => attach('image'),
                icon: const Icon(Icons.image_outlined),
              ),
              IconButton(
                tooltip: '添加文件',
                onPressed: model.busy ? null : () => attach('file'),
                icon: const Icon(Icons.attach_file),
              ),
              Expanded(
                child: TextField(
                  key: const Key('composer'),
                  controller: composer,
                  minLines: 1,
                  maxLines: 5,
                  enabled: !model.busy,
                  onChanged: model.updateDraft,
                  decoration: const InputDecoration(
                    hintText: '输入消息',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: '发送',
                onPressed: model.busy || model.draft.trim().isEmpty
                    ? null
                    : model.sendMessage,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
