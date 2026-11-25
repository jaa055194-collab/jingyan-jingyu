import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../net/host_connection.dart' show HostReadCancellation;
import '../../net/message_reactions_api.dart';

Future<void> openMessageReactions(
  BuildContext context, {
  required ShellViewModel model,
  required String conversationId,
  required String messageId,
  required Object expectedContext,
  required bool Function() viewIsCurrent,
}) {
  if (!viewIsCurrent()) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    showDragHandle: false,
    builder: (_) => _MessageReactionsSheet(
      model: model,
      conversationId: conversationId,
      messageId: messageId,
      expectedContext: expectedContext,
      viewIsCurrent: viewIsCurrent,
    ),
  );
}

class _MessageReactionsSheet extends StatefulWidget {
  const _MessageReactionsSheet({
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
  State<_MessageReactionsSheet> createState() => _MessageReactionsSheetState();
}

enum _Notice { confirmed, refused, unknown, unconfirmed, cancelled }

class _MessageReactionsSheetState extends State<_MessageReactionsSheet> {
  HostReadCancellation? _reading;
  ReactionsLoaded? _snapshot;
  _Notice? _notice;
  bool _starting = true;
  bool _saving = false;
  bool _retired = false;
  bool _readFailed = false;

  bool get _scopeCurrent => mounted && !_retired && widget.viewIsCurrent();
  bool get _current => _scopeCurrent && ModalRoute.isCurrentOf(context) == true;
  bool get _working => _starting || _reading != null || _saving;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_read());
    });
  }

  @override
  void dispose() {
    _reading?.cancel();
    super.dispose();
  }

  Future<void> _read({(ChatReaction, bool)? receipt}) async {
    if (!_current || _reading != null || (receipt == null && _saving)) return;
    final cancellation = HostReadCancellation();
    final online = widget.model.online;
    setState(() {
      _starting = false;
      _snapshot = null;
      _readFailed = false;
      _reading = online ? cancellation : null;
    });
    if (!online) return;
    final result = await widget.model.readMessageReactions(
      conversationId: widget.conversationId,
      messageId: widget.messageId,
      expectedContext: widget.expectedContext,
      viewIsCurrent: () => _current,
      cancellation: cancellation,
    );
    if (!mounted || !identical(_reading, cancellation)) return;
    setState(() {
      _reading = null;
      if (!_current || !widget.model.online) return;
      if (result is! ReactionsLoaded) {
        _readFailed = true;
        if (receipt != null) _notice = _Notice.unconfirmed;
      } else if (receipt != null &&
          result.forChoice(receipt.$1).mine != receipt.$2) {
        // Concurrent changes may make an exact write receipt differ from the
        // current list. As with a lost receipt, require a fresh explicit read.
        _notice = _Notice.unconfirmed;
      } else {
        _snapshot = result;
        _notice = receipt == null ? null : _Notice.confirmed;
      }
    });
  }

  Future<void> _toggle(ChatReaction choice, ReactionsLoaded expected) async {
    if (!_current ||
        _working ||
        !identical(_snapshot, expected) ||
        !widget.model.messageOperationsAvailable) {
      return;
    }
    setState(() {
      _saving = true;
      _snapshot = null;
      _notice = null;
      _readFailed = false;
    });
    final result = await widget.model.toggleMessageReaction(
      conversationId: widget.conversationId,
      messageId: widget.messageId,
      choice: choice,
      expectedContext: widget.expectedContext,
      viewIsCurrent: () => _current,
    );
    if (!mounted) return;
    if (_current && widget.model.online && result is ReactionToggled) {
      // Exactly one GET after a good receipt. Never POST again automatically.
      await _read(receipt: (choice, result.active));
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!_current) return;
      switch (result) {
        case ReactionToggled():
          if (_snapshot == null && _notice == null) {
            _notice = _Notice.unconfirmed;
          }
        case ReactionRefused():
          _notice = _Notice.refused;
        case ReactionUnknown():
          _notice = _Notice.unknown;
        case ReactionCancelled():
          _notice = _Notice.cancelled;
      }
    });
  }

  Widget _feedback(String text, String key) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Semantics(liveRegion: true, child: Text(text, key: Key(key))),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      if (!_scopeCurrent) _retired = true;
      final online = widget.model.online;
      if (_retired || !online) {
        _reading?.cancel();
        _snapshot = null;
      }
      final snapshot = _snapshot;
      final mayWrite = !_working && widget.model.messageOperationsAvailable;
      final mayClose = !_saving || _retired;
      return PopScope(
        canPop: mayClose,
        child: SafeArea(
          key: const Key('message-reactions-sheet'),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('表情回应', style: Theme.of(context).textTheme.titleMedium),
                if (_retired)
                  _feedback('消息或会话已变化，请关闭后再打开。', 'message-reactions-retired')
                else if (!online)
                  _feedback('连接宿主后可读取和更改表情回应。', 'message-reactions-offline')
                else ...[
                  if (_working) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      key: const Key('message-reactions-working'),
                      semanticsLabel: _saving ? '正在确认回应' : '正在读取回应',
                    ),
                  ] else ...[
                    if (_notice case final notice?)
                      switch (notice) {
                        _Notice.confirmed => _feedback(
                          '回应已确认。',
                          'message-reactions-confirmed',
                        ),
                        _Notice.refused => _feedback(
                          '宿主未允许更改回应。请刷新查看当前状态。',
                          'message-reactions-refused',
                        ),
                        _Notice.unknown => _feedback(
                          '更改结果未知，可能已生效。请刷新查看，不会自动重试。',
                          'message-reactions-unknown',
                        ),
                        _Notice.unconfirmed => _feedback(
                          '未能核对当前回应。请刷新查看，不会重复提交。',
                          'message-reactions-unconfirmed',
                        ),
                        _Notice.cancelled => _feedback(
                          '操作未确认，请刷新后再试。',
                          'message-reactions-cancelled',
                        ),
                      },
                    if (_readFailed)
                      _feedback(
                        '暂时无法读取回应，请刷新。',
                        'message-reactions-unavailable',
                      ),
                    if (snapshot != null) ...[
                      if (snapshot.counts.isEmpty)
                        _feedback('还没有可显示的常用表情回应。', 'message-reactions-empty'),
                      const SizedBox(height: 8),
                      const Text('点按添加，再点已选表情可取消。'),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final choice in ChatReaction.values)
                            _ReactionChoice(
                              choice: choice,
                              count: snapshot.forChoice(choice),
                              onSelected: mayWrite
                                  ? (_) => _toggle(choice, snapshot)
                                  : null,
                            ),
                        ],
                      ),
                    ] else if (!_readFailed && _notice == null)
                      const Text('请刷新以读取当前回应。'),
                  ],
                ],
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!_retired)
                      TextButton(
                        key: const Key('message-reactions-refresh'),
                        onPressed: !_working && online ? () => _read() : null,
                        child: const Text('刷新'),
                      ),
                    const SizedBox(width: 8),
                    TextButton(
                      key: const Key('message-reactions-close'),
                      onPressed: mayClose
                          ? () {
                              if (!_saving || _retired) {
                                Navigator.of(context).pop();
                              }
                            }
                          : null,
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ReactionChoice extends StatelessWidget {
  const _ReactionChoice({
    required this.choice,
    required this.count,
    this.onSelected,
  });

  final ChatReaction choice;
  final ReactionCount count;
  final ValueChanged<bool>? onSelected;

  @override
  Widget build(BuildContext context) => FilterChip(
    key: Key('message-reaction-${choice.name}'),
    tooltip: '${choice.label}，${count.count} 个回应${count.mine ? '，我已回应' : ''}',
    materialTapTargetSize: MaterialTapTargetSize.padded,
    selected: count.mine,
    onSelected: onSelected,
    label: Semantics(
      label: '${choice.label}，${count.count} 个回应${count.mine ? '，我已回应' : ''}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            choice.emoji,
            style: const TextStyle(
              fontSize: 20,
              fontFamilyFallback: ['Noto Color Emoji', 'Segoe UI Emoji'],
            ),
          ),
          if (count.count > 0) ...[
            const SizedBox(width: 4),
            Text('${count.count}'),
          ],
        ],
      ),
    ),
  );
}
