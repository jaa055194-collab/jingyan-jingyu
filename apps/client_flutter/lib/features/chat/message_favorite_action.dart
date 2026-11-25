import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../net/favorites_api.dart' show FavoriteSaveOutcome;

/// Inline, non-toggle save. The parent keys the action to its opening view and
/// selection, and the runtime remains the authority on eligible references.
class MessageFavoriteAction extends StatefulWidget {
  const MessageFavoriteAction({
    super.key,
    required this.model,
    required this.conversationId,
    required this.messageId,
    required this.expectedContext,
    required this.viewIsCurrent,
  });

  final ShellViewModel model;
  final String conversationId;
  final String messageId;
  final Object expectedContext;
  final bool Function() viewIsCurrent;

  @override
  State<MessageFavoriteAction> createState() => _MessageFavoriteActionState();
}

class _MessageFavoriteActionState extends State<MessageFavoriteAction> {
  bool _active = true;
  bool _pending = false;
  FavoriteSaveOutcome? _outcome;

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  Future<void> _save(MessageFavoriteAction action) async {
    final model = action.model;
    bool current() => mounted && _active && action.viewIsCurrent();
    bool canSubmit() =>
        current() &&
        model.online &&
        !model.busy &&
        !model.hasSubmittedMessageFavorite(action.messageId);
    if (_pending || _outcome != null || !canSubmit()) return;
    setState(() => _pending = true);
    // A same-frame tab/back change can schedule pane removal before Flutter
    // deactivates it. Do not dispatch or publish against that old pane.
    await WidgetsBinding.instance.endOfFrame;
    if (!current()) return;
    if (!canSubmit()) {
      setState(() => _pending = false);
      return;
    }
    final outcome = await model.saveMessageFavorite(
      conversationId: action.conversationId,
      messageId: action.messageId,
      expectedContext: action.expectedContext,
      viewIsCurrent: current,
    );
    await WidgetsBinding.instance.endOfFrame;
    if (!current()) return;
    setState(() {
      _pending = false;
      _outcome = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final action = widget;
    final model = action.model;
    final spent = model.hasSubmittedMessageFavorite(action.messageId);
    final status = switch (_outcome) {
      FavoriteSaveOutcome.rejected => '宿主拒绝收藏。',
      FavoriteSaveOutcome.unknown => '收藏结果未确认，请到「我的收藏」核对。',
      FavoriteSaveOutcome.cancelled ||
      null when spent && !_pending => '此登录会话已提交过，请到「我的收藏」核对。',
      _ => null,
    };
    final label = _pending
        ? '正在收藏…'
        : _outcome == FavoriteSaveOutcome.saved
        ? '已收藏'
        : model.online
        ? '收藏消息'
        : '收藏需联网';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          key: Key('save-favorite-${action.messageId}'),
          onPressed:
              !_pending &&
                  _outcome == null &&
                  !spent &&
                  model.online &&
                  !model.busy &&
                  action.viewIsCurrent()
              ? () => _save(action)
              : null,
          icon: Icon(
            _outcome == FavoriteSaveOutcome.saved
                ? Icons.bookmark
                : Icons.bookmark_border,
            size: 18,
          ),
          label: Text(label),
        ),
        if (status != null)
          Semantics(
            liveRegion: true,
            child: Text(status, style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }
}
