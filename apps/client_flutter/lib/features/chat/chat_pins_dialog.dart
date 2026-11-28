import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../net/chat_pins_api.dart';
import '../../net/host_connection.dart' show HostReadCancellation;
import '../../ui/ui.dart';

/// With a target, this is an explicit pin/unpin confirmation. Without a target,
/// it is a read-only list of the pins already visible in the current history.
Future<void> openChatPins(
  BuildContext context, {
  required ShellViewModel model,
  required String conversationId,
  required Object expectedContext,
  required bool Function() viewIsCurrent,
  String? targetId,
}) {
  if (!viewIsCurrent()) return Future.value();
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ChatPinsDialog(
      model: model,
      conversationId: conversationId,
      expectedContext: expectedContext,
      viewIsCurrent: viewIsCurrent,
      targetId: targetId,
    ),
  );
}

class _ChatPinsDialog extends StatefulWidget {
  const _ChatPinsDialog({
    required this.model,
    required this.conversationId,
    required this.expectedContext,
    required this.viewIsCurrent,
    this.targetId,
  });

  final ShellViewModel model;
  final String conversationId;
  final Object expectedContext;
  final bool Function() viewIsCurrent;
  final String? targetId;

  @override
  State<_ChatPinsDialog> createState() => _ChatPinsDialogState();
}

class _ChatPinsDialogState extends State<_ChatPinsDialog> {
  HostReadCancellation? _reading;
  List<String>? _ids;
  bool _saving = false;
  bool _starting = true;
  bool _readFailed = false;
  bool _retired = false;
  ChatPinWrite? _receipt;

  bool get _current =>
      mounted &&
      !_retired &&
      widget.viewIsCurrent() &&
      ModalRoute.of(context)?.isCurrent == true;
  bool get _online => widget.model.online;
  Map<String, ShellMessage> get _visible => {
    for (final row in widget.model.messages)
      if (row.operationEligible && !row.recalled) row.id: row,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _reading?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current || _reading != null) return;
    final read = HostReadCancellation();
    setState(() {
      _starting = false;
      _ids = null;
      _readFailed = false;
      if (_receipt != ChatPinWrite.unknown) _receipt = null;
      _reading = _online ? read : null;
    });
    if (!_online) return;
    final result = await widget.model.readChatPins(
      conversationId: widget.conversationId,
      expectedContext: widget.expectedContext,
      viewIsCurrent: () => _current,
      cancellation: read,
    );
    if (!mounted || !identical(_reading, read)) return;
    setState(() {
      _reading = null;
      if (!_current || !_online) return;
      if (result is ChatPinsLoaded) {
        _ids = result.ids;
        _receipt = null;
      } else {
        _readFailed = true;
      }
    });
  }

  Future<void> _write(ShellMessage target, {required bool pinned}) async {
    final liveTarget = _current ? _visible[target.id] : null;
    if (liveTarget == null ||
        liveTarget.sentAt != target.sentAt ||
        _saving ||
        !widget.model.messageOperationsAvailable ||
        _reading != null ||
        _ids == null ||
        _ids!.contains(target.id) == pinned) {
      return;
    }
    setState(() {
      _saving = true;
      _receipt = null;
    });
    final result = await widget.model.setMessagePinned(
      conversationId: widget.conversationId,
      messageId: target.id,
      pinned: pinned,
      expectedContext: widget.expectedContext,
      viewIsCurrent: () => _current,
    );
    if (!mounted) return;
    // Do not optimistically update a list. An exact success can trigger a
    // readback; a lost/refused response awaits the user's explicit refresh.
    if (_current && result == ChatPinWrite.confirmed) await _load();
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result != ChatPinWrite.confirmed || !_current) _ids = null;
      _receipt = _current ? result : null;
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      if (!widget.viewIsCurrent()) _retired = true;
      if (_retired || !_online) {
        _reading?.cancel();
        _ids = null;
      }
      final visible = _retired ? const <String, ShellMessage>{} : _visible;
      final target = visible[widget.targetId];
      final ids = _ids;
      final pins = [for (final id in ids ?? const <String>[]) ?visible[id]];
      final working = _saving || _reading != null;
      final manage = widget.targetId != null;
      final pinned = target != null && ids?.contains(target.id) == true;
      final mayWrite =
          !working &&
          ids != null &&
          target != null &&
          widget.model.messageOperationsAvailable;
      final receipt = _receipt;
      final canClose = !_saving || _retired || !_online;
      return PopScope(
        canPop: canClose,
        child: AlertDialog(
          key: const Key('chat-pins-dialog'),
          title: Text(manage ? '管理消息置顶' : '置顶消息'),
          scrollable: true,
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_retired)
                  const Text('会话已变化，请关闭后重新打开。')
                else if (!_online)
                  const Text('连接宿主后才能查看或修改置顶。')
                else ...[
                  if (working || _starting)
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        JyBusyIndicator(
                          key: Key('chat-pins-loading'),
                          label: '正在读取置顶消息',
                          linear: true,
                        ),
                        SizedBox(height: 8),
                      ],
                    ),
                  if (!working && !_starting && receipt != null)
                    switch (receipt) {
                      ChatPinWrite.confirmed => const Text(
                        '宿主已确认置顶变更。',
                        key: Key('chat-pin-confirmed'),
                      ),
                      ChatPinWrite.refused => const Text(
                        '宿主拒绝了变更。请确认会话权限；也可能已达置顶上限。',
                        key: Key('chat-pin-refused'),
                      ),
                      ChatPinWrite.unknown => const Text(
                        '变更结果未确认，可能已经生效。请刷新查看当前状态；本机不会重试写入。',
                        key: Key('chat-pin-unknown'),
                      ),
                      ChatPinWrite.cancelled => const Text('操作已失效，未确认变更。'),
                    },
                  if (!working && !_starting) ...[
                    if (manage && target == null)
                      const Text('这条消息已不可见。')
                    else if (_readFailed)
                      const Text(
                        '无法读取置顶状态，请刷新重试。',
                        key: Key('chat-pins-read-failure'),
                      )
                    else if (ids == null && receipt == null)
                      const Text(
                        '请刷新以读取当前置顶状态。',
                        key: Key('chat-pins-refresh-needed'),
                      )
                    else if (ids != null && target != null) ...[
                      if (receipt != null) const SizedBox(height: 8),
                      Text(
                        target.text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Text(pinned ? '当前已置顶' : '当前未置顶'),
                      const Text('这项变更适用于整个会话，不是个人收藏。'),
                    ] else if (ids != null && pins.isEmpty)
                      const Text('当前可见消息中没有置顶。', key: Key('chat-pins-empty'))
                    else
                      for (final pin in pins)
                        ListTile(
                          key: Key('chat-pinned-message-${pin.id}'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.push_pin_outlined),
                          title: Text(
                            pin.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                  ],
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const Key('close-chat-pins'),
              onPressed: canClose ? () => Navigator.of(context).pop() : null,
              child: const Text('关闭'),
            ),
            if (!_retired)
              TextButton(
                key: const Key('chat-pins-refresh'),
                onPressed: _online && !working ? _load : null,
                child: const Text('刷新'),
              ),
            if (mayWrite)
              FilledButton(
                key: const Key('chat-pin-confirm'),
                onPressed: () => _write(target, pinned: !pinned),
                child: Text(pinned ? '取消置顶' : '置顶'),
              ),
          ],
        ),
      );
    },
  );
}
