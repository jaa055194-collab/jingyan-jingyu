import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';

class ConversationList extends StatelessWidget {
  const ConversationList({
    super.key,
    required this.model,
    required this.onSelected,
  });
  final ShellViewModel model;
  final ValueChanged<String> onSelected;
  @override
  Widget build(BuildContext context) => model.conversations.isEmpty
      ? const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('暂无会话\n连接宿主后，将显示可用的聊天。', textAlign: TextAlign.center),
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
                onTap: model.busy ? null : () => onSelected(conversation.id),
              ),
          ],
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
