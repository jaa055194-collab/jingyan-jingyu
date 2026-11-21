import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, PlatformException;
import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../net/message_operations_api.dart';
import 'chat_pins_dialog.dart';
import 'message_reactions_sheet.dart';

enum _Action { copy, edit, recall, pin, reactions }

void _notice(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// One explicit action on the row that opened the sheet. Dialogs belong to the
/// same selection; going away must not expose its text or submit a write.
Future<void> openMessageActions(
  BuildContext context, {
  required ShellViewModel model,
  required ShellMessage message,
  required String conversationId,
  required Object expectedContext,
  required bool Function() viewIsCurrent,
}) async {
  ShellMessage? currentRow() {
    if (!viewIsCurrent()) return null;
    return model.messages.where((row) => row.id == message.id).firstOrNull;
  }

  bool sameRow() {
    final row = currentRow();
    return row != null &&
        !row.recalled &&
        row.copyText == message.copyText &&
        row.sentAt == message.sentAt &&
        row.operationEligible == message.operationEligible;
  }

  if (!sameRow()) return;
  final choice = await showModalBottomSheet<_Action>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => ListenableBuilder(
      listenable: model,
      builder: (sheet, _) {
        final valid = sameRow();
        final online = valid && model.messageOperationsAvailable;
        return SafeArea(
          key: const Key('message-actions-sheet'),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('消息操作', style: Theme.of(sheet).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (!valid)
                  const Text('消息或会话已变化，请关闭后重新操作。')
                else ...[
                  if (!online && message.outgoing) const Text('连接宿主后可编辑或撤回。'),
                  if (message.canCopy)
                    ListTile(
                      key: const Key('message-action-copy'),
                      leading: const Icon(Icons.copy_outlined),
                      title: const Text('复制'),
                      subtitle: const Text('写入系统剪贴板'),
                      onTap: () => Navigator.of(sheet).pop(_Action.copy),
                    ),
                  if (message.canEdit)
                    ListTile(
                      key: const Key('message-action-edit'),
                      enabled: online,
                      leading: const Icon(Icons.edit_outlined),
                      title: const Text('编辑'),
                      onTap: online
                          ? () => Navigator.of(sheet).pop(_Action.edit)
                          : null,
                    ),
                  if (model.supportsMessageReactions && message.operationEligible)
                    ListTile(
                      key: const Key('message-action-reactions'),
                      leading: const Icon(Icons.emoji_emotions_outlined),
                      title: const Text('表情回应'),
                      onTap: () => Navigator.of(sheet).pop(_Action.reactions),
                    ),
                  if (model.supportsChatPins && message.operationEligible)
                    ListTile(
                      key: const Key('message-action-pin'),
                      leading: const Icon(Icons.push_pin_outlined),
                      title: const Text('管理置顶'),
                      subtitle: const Text('查看并更改本会话的置顶状态'),
                      onTap: () => Navigator.of(sheet).pop(_Action.pin),
                    ),
                  if (message.outgoing && message.operationEligible)
                    ListTile(
                      key: const Key('message-action-recall'),
                      enabled: online && message.canRecall,
                      leading: const Icon(Icons.undo),
                      title: const Text('撤回'),
                      subtitle: const Text('仅可撤回本人 24 小时内的消息'),
                      onTap: online && message.canRecall
                          ? () => Navigator.of(sheet).pop(_Action.recall)
                          : null,
                    ),
                ],
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const Key('message-actions-sheet-close'),
                    onPressed: () => Navigator.of(sheet).pop(),
                    child: const Text('关闭'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
  if (choice == null || !context.mounted || !sameRow()) return;
  if (choice == _Action.copy) {
    if (!message.canCopy) return;
    try {
      await Clipboard.setData(ClipboardData(text: message.copyText!));
      if (context.mounted && sameRow()) _notice(context, '已复制');
    } on PlatformException {
      if (context.mounted && sameRow()) _notice(context, '无法访问系统剪贴板');
    }
    return;
  }
  if (choice == _Action.reactions) {
    if (!model.supportsMessageReactions || !message.operationEligible) return;
    await openMessageReactions(
      context,
      model: model,
      conversationId: conversationId,
      messageId: message.id,
      expectedContext: expectedContext,
      viewIsCurrent: sameRow,
    );
    return;
  }
  if (choice == _Action.pin) {
    if (!model.supportsChatPins || !message.operationEligible) return;
    await openChatPins(
      context,
      model: model,
      conversationId: conversationId,
      expectedContext: expectedContext,
      viewIsCurrent: viewIsCurrent,
      targetId: message.id,
    );
    return;
  }
  final editing = choice == _Action.edit;
  if (!model.messageOperationsAvailable ||
      (editing ? !message.canEdit : !message.canRecall)) {
    return;
  }
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _MessageMutationDialog(
      model: model,
      initialText: editing ? message.copyText : null,
      viewIsCurrent: viewIsCurrent,
      canSubmit: () =>
          sameRow() &&
          model.messageOperationsAvailable &&
          (editing ? message.canEdit : message.canRecall),
      submit: (text, dialogIsCurrent) => editing
          ? model.editMessage(
              conversationId: conversationId,
              messageId: message.id,
              expectedText: message.copyText!,
              text: text,
              expectedContext: expectedContext,
              viewIsCurrent: dialogIsCurrent,
            )
          : model.recallMessage(
              conversationId: conversationId,
              messageId: message.id,
              expectedContext: expectedContext,
              viewIsCurrent: dialogIsCurrent,
            ),
    ),
  );
  if (saved == true && context.mounted && viewIsCurrent()) {
    _notice(context, editing ? '消息已编辑' : '消息已撤回');
  }
}

class _MessageMutationDialog extends StatefulWidget {
  const _MessageMutationDialog({
    required this.model,
    required this.initialText,
    required this.viewIsCurrent,
    required this.canSubmit,
    required this.submit,
  });

  final ShellViewModel model;
  final String? initialText;
  final bool Function() viewIsCurrent;
  final bool Function() canSubmit;
  final Future<MessageWriteOutcome> Function(String, bool Function()) submit;

  @override
  State<_MessageMutationDialog> createState() => _MessageMutationDialogState();
}

class _MessageMutationDialogState extends State<_MessageMutationDialog> {
  late final _controller = TextEditingController(text: widget.initialText);
  bool _submitting = false;
  bool _invalidated = false;
  bool _uncertain = false;
  String? _failure;
  bool get _editing => widget.initialText != null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _isCurrent() =>
      mounted &&
      !_invalidated &&
      widget.viewIsCurrent() &&
      ModalRoute.of(context)?.isCurrent == true;

  Future<void> _submit() async {
    if (_submitting || _uncertain || !_isCurrent() || !widget.canSubmit()) {
      return;
    }
    final text = _editing ? _controller.text.trim() : '';
    if (_editing &&
        (text.isEmpty ||
            text.length > MessageOperationsApi.maxEditTextLength)) {
      setState(() => _failure = '请输入 1–4000 个字符的正文。');
      return;
    }
    if (_editing && text == widget.initialText) {
      setState(() => _failure = '正文未修改。');
      return;
    }
    setState(() {
      _submitting = true;
      _failure = null;
    });
    final result = await widget.submit(text, _isCurrent);
    if (!mounted || !_isCurrent()) return;
    setState(() => _submitting = false);
    switch (result) {
      case EditAccepted() || MessageWriteAccepted():
        Navigator.of(context).pop(true);
      case MessageWriteRejected():
        setState(
          () => _failure = _editing
              ? '编辑未获允许：请确认是本人未撤回的文本消息且会话仍可写入。'
              : '撤回未获允许：可能已超过 24 小时，或会话权限已变化。',
        );
      case MessageWriteUnknown():
        setState(() {
          _uncertain = true;
          _failure = '结果未确认。操作可能已在宿主生效；本机不会重试。';
        });
      case MessageWriteCancelled():
        Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      if (!widget.viewIsCurrent()) _invalidated = true;
      if (_invalidated) {
        return AlertDialog(
          title: const Text('会话已变化'),
          content: const Text('已隐藏消息内容，请关闭后重新操作。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      }
      return PopScope(
        canPop: !_submitting,
        child: AlertDialog(
          key: Key(_editing ? 'edit-message-dialog' : 'recall-message-dialog'),
          title: Text(_editing ? '编辑消息' : '撤回这条消息？'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_editing)
                  TextField(
                    key: const Key('edit-message-input'),
                    controller: _controller,
                    autofocus: true,
                    enabled: !_submitting && !_uncertain,
                    minLines: 1,
                    maxLines: 5,
                    maxLength: MessageOperationsApi.maxEditTextLength,
                    decoration: const InputDecoration(
                      labelText: '正文',
                      border: OutlineInputBorder(),
                    ),
                  )
                else
                  const Text('撤回后，宿主不再下发原正文，本机会显示占位。不会清除其他设备已有的副本或剪贴板内容。'),
                if (_submitting) const LinearProgressIndicator(),
                if (_failure != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _failure!,
                      key: Key(
                        _editing
                            ? 'edit-message-failure'
                            : 'recall-message-failure',
                      ),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _submitting ? null : () => Navigator.of(context).pop(),
              child: Text(_uncertain ? '关闭' : '取消'),
            ),
            FilledButton(
              key: Key(
                _editing ? 'edit-message-confirm' : 'recall-message-confirm',
              ),
              onPressed: _submitting || _uncertain || !widget.canSubmit()
                  ? null
                  : _submit,
              child: Text(_editing ? '保存' : '撤回'),
            ),
          ],
        ),
      );
    },
  );
}
