import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../../app/shell_view_model.dart';
import '../../app/status_panel.dart';
import '../../ui/jy_palette.dart';
import '../../ui/jy_presence.dart';
import '../../ui/jy_surfaces.dart';
import '../../ui/jy_tokens.dart';
import '../../ui/jy_typography.dart';
import '../favorites/favorites_screen.dart';
import 'chat_pins_dialog.dart';
import 'message_favorite_action.dart';
import 'message_operations_ui.dart';
import 'scheduled_messages_dialog.dart';
import 'voice_message_playback.dart';

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
      // One compact action row (pages/conversations.md section 2); it wraps
      // on small screens and large text instead of scrolling sideways.
      Padding(
        padding: const EdgeInsets.fromLTRB(
          JySpace.lg,
          JySpace.md,
          JySpace.lg,
          JySpace.sm,
        ),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Wrap(
            spacing: JySpace.sm,
            runSpacing: JySpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
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
              TextButton.icon(
                key: const Key('refresh-conversations'),
                onPressed: model.authenticated && !model.locked && !model.busy
                    ? model.refreshConversations
                    : null,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('刷新会话'),
              ),
              if (FavoritesScreen.canOpen(model))
                TextButton.icon(
                  key: const Key('open-favorites'),
                  onPressed: () => FavoritesScreen.open(context, model),
                  icon: const Icon(Icons.bookmark_border_rounded),
                  label: const Text('我的收藏'),
                ),
            ],
          ),
        ),
      ),
      Expanded(
        child: model.conversations.isEmpty
            ? _ConversationsStatus(model: model)
            : ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: JySpace.sm,
                  vertical: JySpace.xs,
                ),
                children: [
                  for (final conversation in model.conversations)
                    _ConversationRow(
                      conversation: conversation,
                      selected: model.selectedConversationId == conversation.id,
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

/// One conversation: a 44dp avatar (two stacked discs for a group), the
/// title, a one-line preview, and the time above the unread badge. The
/// selected row gets a signalSoft fill and a 3dp signal bar on its leading
/// edge, so the selection does not rely on colour alone.
class _ConversationRow extends StatelessWidget {
  const _ConversationRow({
    required this.conversation,
    required this.selected,
    required this.onTap,
  });
  final ShellConversation conversation;
  final bool selected;
  final VoidCallback? onTap;

  static String _timeLabel(DateTime at, DateTime now) {
    final local = at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${two(local.hour)}:${two(local.minute)}';
    }
    if (local.year == now.year) return '${local.month}/${local.day}';
    return '${local.year}/${local.month}/${local.day}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = JyPalette.of(context);
    final text = Theme.of(context).textTheme;
    final at = conversation.lastActivityAt;
    final unread = conversation.unread > 0;
    final shape = JyShapes.rounded(JyRadius.md);
    final tile = ListTile(
      key: ValueKey(conversation.id),
      selected: selected,
      minTileHeight: 64,
      shape: shape,
      selectedTileColor: palette.signalSoft,
      contentPadding: const EdgeInsetsDirectional.only(
        start: JySpace.md,
        end: JySpace.md,
      ),
      leading: JyAvatar(
        label: conversation.title.isEmpty
            ? '?'
            : conversation.title.characters.first,
        kind: conversation.kind == 'group'
            ? JyAvatarKind.group
            : JyAvatarKind.person,
      ),
      title: Text(
        conversation.title,
        style: text.titleMedium?.copyWith(
          color: selected ? palette.onSignalSoft : palette.text1,
          fontWeight: unread ? FontWeight.w700 : null,
        ),
      ),
      subtitle: Text(
        conversation.preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodyMedium?.copyWith(color: palette.text2),
      ),
      trailing: at == null && !unread
          ? null
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (at != null)
                  Text(
                    _timeLabel(at, DateTime.now()),
                    style: text.labelSmall?.copyWith(
                      color: palette.text3,
                      fontFeatures: JyTypography.tabularFigures,
                    ),
                  ),
                if (at != null && unread) const SizedBox(height: JySpace.xs),
                if (unread) JyBadge(count: conversation.unread),
              ],
            ),
      onTap: onTap,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Stack(
        children: [
          tile,
          if (selected)
            PositionedDirectional(
              start: 0,
              top: JySpace.md,
              bottom: JySpace.md,
              child: IgnorePointer(
                child: SizedBox(
                  width: 3,
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: palette.signal,
                      shape: JyShapes.pill,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Why the conversation list is empty, most specific cause first: not signed
/// in, offline, a failed read, then an account that simply has no chats yet.
class _ConversationsStatus extends StatelessWidget {
  const _ConversationsStatus({required this.model});
  final ShellViewModel model;

  @override
  Widget build(BuildContext context) {
    if (!model.authenticated) {
      return const StatusPanel(
        key: ValueKey('conversations-signed-out'),
        fill: true,
        tone: StatusTone.offline,
        icon: Icons.link_off,
        title: '尚未连接宿主',
        detail: '登录宿主后，这里会显示你的聊天。',
      );
    }
    if (!model.online) {
      return const StatusPanel(
        key: ValueKey('conversations-offline'),
        fill: true,
        tone: StatusTone.offline,
        icon: Icons.cloud_off_outlined,
        title: '暂时离线',
        detail: '恢复连接后，会显示你的聊天。',
      );
    }
    if (model.error != null) {
      return StatusPanel(
        key: const ValueKey('conversations-error'),
        fill: true,
        tone: StatusTone.error,
        icon: Icons.error_outline,
        title: '没有可显示的会话',
        detail: '出错原因见页面顶部的提示。可以重新读取，或稍后再试。',
        action: OutlinedButton(
          key: const Key('conversations-retry'),
          onPressed: model.locked || model.busy
              ? null
              : model.refreshConversations,
          child: const Text('重新读取'),
        ),
      );
    }
    return const StatusPanel(
      key: ValueKey('conversations-empty'),
      fill: true,
      icon: Icons.forum_outlined,
      title: '暂无会话',
      detail: '可以创建群聊，或等好友发来消息。',
    );
  }
}

class _GroupActionDialog extends StatefulWidget {
  const _GroupActionDialog({
    required this.model,
    this.groupId,
    this.mentionDraft,
  });
  final ShellViewModel model;
  final String? groupId;
  final String? mentionDraft;
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
  bool get mentioning => widget.mentionDraft != null;
  bool get adding => widget.groupId != null && !mentioning;
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
        (!mentioning && !model.online) ||
        form.currentState?.validate() != true) {
      return;
    }
    setState(() {
      submitting = true;
      failure = null;
    });
    if (mentioning) {
      await model.sendMentionedMessage(
        conversationId: widget.groupId!,
        expectedDraft: widget.mentionDraft!,
        aiAccountId: input.text.trim(),
      );
    } else if (adding) {
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
          model.connectedAccountId != initialAccount ||
          (mentioning &&
              !submitting &&
              (model.selectedConversationId != widget.groupId ||
                  model.draft != widget.mentionDraft))) {
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
      final permitted =
          model.authenticated && !model.locked && (mentioning || model.online);
      return PopScope(
        canPop: !submitting,
        child: AlertDialog(
          title: Text(
            mentioning
                ? '提及 AI 并发送本条消息'
                : adding
                ? '添加群成员'
                : '创建群聊',
          ),
          content: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    mentioning
                        ? '输入已知 AI 账户 ID，仅本条消息提及。是否回复由宿主策略决定；不保证模型回复。'
                        : adding
                        ? '输入对方已知的账户 ID。仅群主可添加成员。'
                        : '先创建群聊，再单独添加已知账户 ID。',
                  ),
                  if (mentioning)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        widget.mentionDraft!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: Key(
                      mentioning
                          ? 'mention-ai-id'
                          : adding
                          ? 'member-account-id'
                          : 'group-name',
                    ),
                    controller: input,
                    autofocus: true,
                    enabled: permitted && !submitting,
                    decoration: InputDecoration(
                      labelText: mentioning
                          ? 'AI 账户 ID'
                          : adding
                          ? '账户 ID'
                          : '群名称',
                    ),
                    validator: (value) {
                      final text = value ?? '';
                      if (!adding && !mentioning) {
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
              key: Key(
                mentioning
                    ? 'confirm-mention-message'
                    : adding
                    ? 'confirm-add-member'
                    : 'confirm-create-group',
              ),
              onPressed: permitted && !submitting && !model.busy
                  ? submit
                  : null,
              child: Text(
                mentioning
                    ? '确认提及并发送'
                    : adding
                    ? '添加'
                    : '创建',
              ),
            ),
          ],
        ),
      );
    },
  );
}

class ChatPane extends StatefulWidget {
  const ChatPane({
    super.key,
    required this.model,
    this.onBack,
    this.openRevision = 0,
  });
  final ShellViewModel model;
  final VoidCallback? onBack;
  final int openRevision;
  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane> {
  final composer = TextEditingController();
  ModalRoute<dynamic>? _voiceRoute;
  bool _paneActive = true;
  int _favoriteViewRevision = 0;
  List<Listenable> _navigationChanges = const [];
  bool _favoriteViewRefreshQueued = false;
  // Keep one tear-off so an old pane can stop only the attempt it owns.
  late final bool Function() _voiceViewIsCurrent = _isVoiceViewCurrent;
  bool _isVoiceViewCurrent() =>
      mounted && _paneActive && (_voiceRoute?.isCurrent ?? true);

  void _onFavoriteNavigationChanged() {
    // The shell's Navigator observer reports even a push and pop between
    // frames. Retire the old control synchronously before any callback runs.
    _favoriteViewRevision++;
    if (_favoriteViewRefreshQueued) return;
    _favoriteViewRefreshQueued = true;
    scheduleMicrotask(() {
      _favoriteViewRefreshQueued = false;
      if (mounted && _paneActive) setState(() {});
    });
  }

  void _removeNavigationListeners() {
    for (final changes in _navigationChanges) {
      changes.removeListener(_onFavoriteNavigationChanged);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _voiceRoute) || route?.isCurrent == false) {
      _favoriteViewRevision++;
    }
    _voiceRoute = route;
    _removeNavigationListeners();
    _navigationChanges =
        route?.navigator?.widget.observers.whereType<Listenable>().toList() ??
        const [];
    for (final changes in _navigationChanges) {
      changes.addListener(_onFavoriteNavigationChanged);
    }
    if (!_voiceViewIsCurrent()) _stopVoice();
  }

  @override
  void didUpdateWidget(ChatPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.model, widget.model)) {
      _favoriteViewRevision++;
      oldWidget.model.stopVoicePlayback(viewIsCurrent: _voiceViewIsCurrent);
    }
  }

  @override
  void activate() {
    super.activate();
    _paneActive = true;
  }

  @override
  void deactivate() {
    _paneActive = false;
    _favoriteViewRevision++;
    _stopVoice();
    super.deactivate();
  }

  @override
  void dispose() {
    _removeNavigationListeners();
    _stopVoice();
    composer.dispose();
    super.dispose();
  }

  void _stopVoice() =>
      widget.model.stopVoicePlayback(viewIsCurrent: _voiceViewIsCurrent);

  void _playVoice(ShellMessage message) {
    widget.model.playVoiceMessage(
      message.id,
      viewIsCurrent: _voiceViewIsCurrent,
      waitForView: () => WidgetsBinding.instance.endOfFrame,
    );
  }

  Future<void> _openMessageActions(
    ShellMessage message, {
    required Object expectedContext,
    required bool Function() viewIsCurrent,
  }) async {
    if (!_isVoiceViewCurrent() || !viewIsCurrent()) return;
    await openMessageActions(
      context,
      model: widget.model,
      message: message,
      conversationId: widget.model.selectedConversationId!,
      expectedContext: expectedContext,
      viewIsCurrent: viewIsCurrent,
    );
  }

  /// Explicit, bounded image open. Nothing is fetched until the user taps.
  Future<void> _openImage(ShellMessage message) async {
    final model = widget.model;
    final account = model.connectedAccountId;
    final conversation = model.selectedConversationId;
    final image = await model.openImageAttachment(message.id);
    if (!mounted) return;
    if (image == null) {
      if (!model.locked) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('图片暂不可用；不会自动重试。')));
      }
      return;
    }
    if (!model.authenticated ||
        model.locked ||
        model.connectedAccountId != account ||
        model.selectedConversationId != conversation) {
      return;
    }
    // Decode inside a bounded 1080 px box while keeping the original
    // proportions; evicting this same provider frees the decoded pixels.
    final provider = ResizeImage(
      MemoryImage(image.bytes),
      width: 1080,
      height: 1080,
      policy: ResizeImagePolicy.fit,
    );
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('message-image-dialog'),
        title: Text(message.attachmentName ?? '图片'),
        content: SizedBox(
          width: 360,
          child: InteractiveViewer(
            key: const Key('message-image-viewer'),
            minScale: 1,
            maxScale: 4,
            child: Image(
              image: provider,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Text('图片无法显示。'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              provider.evict();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    provider.evict();
  }

  Future<void> attach(String kind) async {
    final model = widget.model;
    final account = model.connectedAccountId;
    final conversation = model.selectedConversationId;
    final session = model.ownAiSessionContext;
    bool current() =>
        mounted &&
        identical(widget.model, model) &&
        account != null &&
        conversation != null &&
        model.connectedAccountId == account &&
        model.selectedConversationId == conversation &&
        model.ownAiSessionContext == session &&
        model.authenticated &&
        !model.busy &&
        !model.locked;

    if (!current()) return;
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
      if (granted != true || !current()) return;
      await model.setAiConsent(true);
      if (!current() || !model.aiConsentGranted || model.error != null) return;
    }
    await model.attachFile(kind);
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final conversationId = model.selectedConversationId;
    if (conversationId == null) {
      return const StatusPanel(
        fill: true,
        icon: Icons.chat_bubble_outline,
        title: '选择一个会话，开始聊天',
      );
    }
    final messages = model.messages;
    final messageIndices = {
      for (var i = 0; i < messages.length; i++)
        messages[i].id: messages.length - 1 - i,
    };
    final favoriteContext = model.messageFavoriteContext;
    final favoriteViewRevision = _favoriteViewRevision;
    final favoriteAccount = model.connectedAccountId;
    final favoriteSession = model.ownAiSessionContext;
    bool favoriteViewIsCurrent() =>
        mounted &&
        _paneActive &&
        identical(widget.model, model) &&
        _favoriteViewRevision == favoriteViewRevision &&
        _voiceRoute?.isCurrent == true &&
        model.authenticated &&
        !model.locked &&
        model.connectedAccountId == favoriteAccount &&
        model.ownAiSessionContext == favoriteSession &&
        model.selectedConversationId == conversationId &&
        model.messageFavoriteContext == favoriteContext;

    final operationsContext = model.messageOperationsContext;
    // Our own sheet/confirmation routes cover this pane, so they use the
    // session and selection pins rather than requiring the pane's route on top.
    bool operationsViewIsCurrent() =>
        mounted &&
        _paneActive &&
        identical(widget.model, model) &&
        model.authenticated &&
        !model.locked &&
        model.selectedConversationId == conversationId &&
        model.messageOperationsContext == operationsContext;

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
    final attachmentName = model.selectedAttachmentName;
    final canManageAttachment =
        model.authenticated && !model.busy && !model.locked;
    final canSendAttachment = canManageAttachment && model.online;
    final showVoice =
        model.supportsVoicePlayback && model.authenticated && !model.locked;
    final voice = showVoice ? model.voicePlayback : null;
    final voiceActive =
        voice?.phase == ShellVoicePhase.loading ||
        voice?.phase == ShellVoicePhase.playing;
    final scheduleScope = model.scheduledMessagesScope(conversationId);
    final chatActions = <Widget>[
      if (scheduleScope != null)
        IconButton(
          key: const Key('open-scheduled-messages'),
          tooltip: '定时消息',
          icon: const Icon(Icons.schedule_send_outlined),
          onPressed: () {
            if (!_isVoiceViewCurrent() || !scheduleScope.isCurrent()) return;
            openScheduledMessages(
              context,
              model: model,
              conversationId: conversationId,
              scope: scheduleScope,
            );
          },
        ),
      if (model.supportsChatPins && operationsContext != null)
        IconButton(
          key: const Key('open-chat-pins'),
          tooltip: '置顶消息',
          icon: const Icon(Icons.push_pin_outlined),
          onPressed: () {
            if (!_isVoiceViewCurrent() || !operationsViewIsCurrent()) return;
            openChatPins(
              context,
              model: model,
              conversationId: conversationId,
              expectedContext: operationsContext,
              viewIsCurrent: operationsViewIsCurrent,
            );
          },
        ),
      if (model.canAddMembersToSelectedGroup)
        IconButton(
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
        ),
    ];
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
          trailing: chatActions.isEmpty
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: chatActions),
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
          child: messages.isEmpty
              ? StatusPanel(
                  key: ValueKey(('no-messages', conversationId)),
                  fill: true,
                  tone: model.online ? StatusTone.empty : StatusTone.offline,
                  icon: model.online
                      ? Icons.chat_outlined
                      : Icons.cloud_off_outlined,
                  title: '还没有消息',
                  detail: model.online
                      ? '发一条消息，开始这段对话。'
                      : '离线时发出的文字消息会先排队，联网后会自动尝试发送。',
                )
              : ListView.builder(
                  key: ValueKey((
                    model,
                    favoriteAccount,
                    favoriteSession,
                    conversationId,
                    widget.openRevision,
                  )),
                  // Offset zero is the newest edge, even for lazily laid-out
                  // history. Invert indices so rows still read oldest to newest.
                  reverse: true,
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  findChildIndexCallback: (key) => key is ValueKey<String>
                      ? messageIndices[key.value]
                      : null,
                  itemBuilder: (context, index) {
                    final message = messages[messages.length - 1 - index];
                    return Align(
                      key: ValueKey(message.id),
                      alignment: message.outgoing
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(12),
                          decoration: ShapeDecoration(
                            color: message.outgoing
                                ? JyPalette.of(context).signal
                                : JyPalette.of(context).raised,
                            shape: JyShapes.bubble(mine: message.outgoing),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (message.recalled)
                                Text(
                                  '消息已撤回',
                                  key: Key('message-recalled-${message.id}'),
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        fontStyle: FontStyle.italic,
                                        color: JyPalette.of(context).text2,
                                      ),
                                )
                              else
                                SelectableText(
                                  message.text,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: message.outgoing
                                            ? JyPalette.of(context).onSignal
                                            : JyPalette.of(context).text1,
                                      ),
                                ),
                              if (!message.recalled &&
                                  message.imageAttachment &&
                                  message.attachmentId != null)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    key: Key('open-image-${message.id}'),
                                    onPressed: model.busy || model.locked
                                        ? null
                                        : () => _openImage(message),
                                    icon: const Icon(
                                      Icons.image_outlined,
                                      size: 18,
                                    ),
                                    label: const Text('查看图片'),
                                  ),
                                ),
                              if (!message.recalled &&
                                  showVoice &&
                                  message.voiceAttachment)
                                VoiceMessagePlaybackControl(
                                  messageId: message.id,
                                  phase: voice?.messageId == message.id
                                      ? voice?.phase
                                      : null,
                                  onPlay:
                                      model.online &&
                                          !model.busy &&
                                          !voiceActive
                                      ? () => _playVoice(message)
                                      : null,
                                  onStop: _stopVoice,
                                ),
                              if (!message.recalled &&
                                  message.favoriteEligible &&
                                  favoriteContext != null &&
                                  favoriteViewIsCurrent())
                                MessageFavoriteAction(
                                  key: ValueKey((
                                    favoriteViewRevision,
                                    favoriteContext,
                                    conversationId,
                                    message.id,
                                  )),
                                  model: model,
                                  conversationId: conversationId,
                                  messageId: message.id,
                                  expectedContext: favoriteContext,
                                  viewIsCurrent: favoriteViewIsCurrent,
                                ),
                              if (!message.recalled) ...[
                                const SizedBox(height: 4),
                                Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 8,
                                  children: [
                                    Text(
                                      message.status,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall,
                                    ),
                                    if (message.edited)
                                      Text(
                                        '已编辑',
                                        key: Key(
                                          'message-edited-${message.id}',
                                        ),
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall,
                                      ),
                                    if (operationsContext != null &&
                                        (message.canCopy ||
                                            message.canEdit ||
                                            message.canRecall ||
                                            (message.operationEligible &&
                                                (model.supportsChatPins ||
                                                    model
                                                        .supportsMessageReactions))))
                                      IconButton(
                                        key: Key(
                                          'message-actions-${message.id}',
                                        ),
                                        tooltip: '消息操作',
                                        onPressed: () => _openMessageActions(
                                          message,
                                          expectedContext: operationsContext,
                                          viewIsCurrent:
                                              operationsViewIsCurrent,
                                        ),
                                        icon: const Icon(
                                          Icons.more_horiz,
                                          size: 20,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        if (model.conversations.any(
          (item) =>
              item.id == model.selectedConversationId && item.kind == 'group',
        ))
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('mention-ai-message'),
              onPressed: model.canMentionAi
                  ? () {
                      final groupId = model.selectedConversationId;
                      final draft = model.draft;
                      showDialog<void>(
                        context: context,
                        builder: (_) => _GroupActionDialog(
                          model: model,
                          groupId: groupId,
                          mentionDraft: draft,
                        ),
                      );
                    }
                  : null,
              icon: const Icon(Icons.alternate_email),
              label: const Text('提及 AI 并发送'),
            ),
          ),
        if (attachmentName != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: attachmentName,
                    child: Text(
                      attachmentName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: canManageAttachment
                      ? model.discardSelectedAttachment
                      : null,
                  child: const Text('取消附件'),
                ),
                FilledButton(
                  onPressed: canSendAttachment
                      ? model.sendSelectedAttachment
                      : null,
                  child: const Text('发送附件'),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '添加图片',
                onPressed: canManageAttachment ? () => attach('image') : null,
                icon: const Icon(Icons.image_outlined),
              ),
              IconButton(
                tooltip: '添加文件',
                onPressed: canManageAttachment ? () => attach('file') : null,
                icon: const Icon(Icons.attach_file),
              ),
              Expanded(
                child: TextField(
                  key: const Key('composer'),
                  controller: composer,
                  minLines: 1,
                  maxLines: 5,
                  // Stays enabled while busy: disabling it drops focus and
                  // closes the keyboard mid-typing. Only sending waits.
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
