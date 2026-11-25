import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';

/// A staged share is never routed to the current conversation by default.
class SharedTextPanel extends StatelessWidget {
  const SharedTextPanel({
    super.key,
    required this.model,
    required this.navigationGeneration,
    required this.navigationChanges,
    required this.onApplied,
  });

  final ShellViewModel model;
  final int Function() navigationGeneration;
  final Listenable navigationChanges;
  final Future<void> Function() onApplied;

  bool get _visible => model.authenticated && !model.locked;

  Future<void> _choose(BuildContext context) async {
    final share = model.incomingSharedText;
    final account = model.connectedAccountId;
    final token = model.shareInteractionContext;
    if (!_visible ||
        model.busy ||
        share == null ||
        account == null ||
        token == null) {
      return;
    }
    final chooserContext = context;
    final session = model.ownAiSessionContext;
    int? dialogGeneration;
    final applied = await showDialog<bool>(
      context: chooserContext,
      builder: (_) {
        dialogGeneration ??= navigationGeneration();
        return _ShareTargetDialog(
          model: model,
          account: account,
          share: share,
          token: token,
          session: session,
          navigationGeneration: dialogGeneration!,
          currentNavigationGeneration: navigationGeneration,
          navigationChanges: navigationChanges,
        );
      },
    );
    if (applied == true &&
        chooserContext.mounted &&
        model.authenticated &&
        !model.locked &&
        model.connectedAccountId == account &&
        model.ownAiSessionContext == session &&
        navigationGeneration() == dialogGeneration! + 1) {
      await onApplied();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final share = model.incomingSharedText;
    final notice = model.incomingShareNotice;
    if (share == null && notice == null) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        key: const Key('incoming-shared-text-panel'),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (share != null) ...[
              Text(
                share.text,
                key: const Key('shared-text-preview'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                softWrap: true,
              ),
              const SizedBox(height: 8),
            ],
            if (notice != null) ...[
              Text(notice, key: const Key('shared-text-notice')),
              if (share != null) const SizedBox(height: 8),
            ],
            if (share != null)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton(
                    onPressed: model.busy ? null : () => _choose(context),
                    child: const Text('选择会话'),
                  ),
                  TextButton(
                    onPressed: model.busy ? null : model.discardSharedText,
                    child: const Text('丢弃分享'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

final class _ShareTargetDialog extends StatefulWidget {
  const _ShareTargetDialog({
    required this.model,
    required this.account,
    required this.share,
    required this.token,
    required this.session,
    required this.navigationGeneration,
    required this.currentNavigationGeneration,
    required this.navigationChanges,
  });

  final ShellViewModel model;
  final String account;
  final ShellIncomingShare share;
  final Object token;
  final Object? session;
  final int navigationGeneration;
  final int Function() currentNavigationGeneration;
  final Listenable navigationChanges;

  @override
  State<_ShareTargetDialog> createState() => _ShareTargetDialogState();
}

final class _ShareTargetDialogState extends State<_ShareTargetDialog> {
  String? targetId;
  bool applying = false;
  bool invalidated = false;

  bool get sessionCurrent {
    final model = widget.model;
    return !invalidated &&
        model.authenticated &&
        !model.locked &&
        model.connectedAccountId == widget.account &&
        model.ownAiSessionContext == widget.session &&
        widget.currentNavigationGeneration() == widget.navigationGeneration;
  }

  bool get shareCurrent =>
      sessionCurrent &&
      identical(widget.model.incomingSharedText, widget.share) &&
      identical(widget.model.shareInteractionContext, widget.token);

  bool get candidatesCurrent =>
      targetId == null ||
      widget.model.conversations.any(
        (conversation) => conversation.id == targetId,
      );

  bool get current =>
      shareCurrent && candidatesCurrent && !widget.model.busy && !applying;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.model, widget.navigationChanges]),
    builder: (context, _) {
      if (!shareCurrent || !candidatesCurrent) invalidated = true;
      if (invalidated) {
        return AlertDialog(
          key: const Key('stale-share-target-dialog'),
          title: const Text('分享状态已变化'),
          content: const Text('请重新打开分享内容后再选择会话。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('关闭'),
            ),
          ],
        );
      }
      final conversations = widget.model.conversations;
      final selected = conversations.where((entry) => entry.id == targetId);
      final selectedConversation = selected.isEmpty ? null : selected.first;
      final targetDraft = targetId == null
          ? ''
          : widget.model.draftFor(targetId!);
      return PopScope(
        canPop: !applying,
        child: AlertDialog(
          title: const Text('选择接收会话'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前账号：${widget.account}'),
                const SizedBox(height: 8),
                Text(
                  widget.share.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: RadioGroup<String>(
                      groupValue: targetId,
                      onChanged: (value) {
                        if (!applying) setState(() => targetId = value);
                      },
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final conversation in conversations)
                            RadioListTile<String>(
                              key: ValueKey('share-target-${conversation.id}'),
                              value: conversation.id,
                              title: Text(conversation.title),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (selectedConversation != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      targetDraft.isEmpty
                          ? '将分享内容加入“${selectedConversation.title}”的草稿？'
                          : '目标会话已有草稿，分享内容不会覆盖。',
                      key: const Key('share-target-draft-state'),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: applying
                  ? null
                  : () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed:
                  !current ||
                      targetId == null ||
                      targetDraft.isNotEmpty ||
                      applying
                  ? null
                  : _apply,
              child: applying
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('加入草稿'),
            ),
          ],
        ),
      );
    },
  );

  Future<void> _apply() async {
    final conversationId = targetId;
    if (!current || conversationId == null) return;
    final model = widget.model;
    final token = widget.token;
    final routeGeneration = widget.currentNavigationGeneration();
    setState(() => applying = true);
    final applied = await model.useSharedTextInDraft(
      conversationId,
      interactionContext: token,
    );
    if (!mounted) return;
    final sessionStillCurrent =
        model.authenticated &&
        !model.locked &&
        model.connectedAccountId == widget.account &&
        model.ownAiSessionContext == widget.session &&
        widget.currentNavigationGeneration() == routeGeneration;
    if (!sessionStillCurrent || !applied) {
      setState(() {
        applying = false;
        invalidated = true;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }
}
