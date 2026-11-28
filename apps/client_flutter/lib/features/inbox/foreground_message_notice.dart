import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../ui/ui.dart';
import 'foreground_message_activity.dart';

/// The shell mounts this slot only on the Contacts/Inbox main page. The
/// surrounding shell and the user's current route/focus are never changed.
class ForegroundMessageNotice extends StatefulWidget {
  const ForegroundMessageNotice({
    super.key,
    required this.model,
    required this.activity,
    required this.navigation,
    required this.activeViewGeneration,
  });

  final ShellViewModel model;
  final ForegroundMessageActivity activity;
  final Listenable navigation;
  final int? Function() activeViewGeneration;

  @override
  State<ForegroundMessageNotice> createState() =>
      _ForegroundMessageNoticeState();
}

class _ForegroundMessageNoticeState extends State<ForegroundMessageNotice> {
  static const _duration = Duration(seconds: 8);
  ModalRoute<dynamic>? _route;
  Object? _ticket, _presentation;
  Timer? _expiry;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(ForegroundMessageNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.model != oldWidget.model ||
        widget.activity != oldWidget.activity ||
        widget.navigation != oldWidget.navigation) {
      _unlisten(oldWidget);
      _clear();
      _listen();
    }
  }

  void _listen() {
    widget.activity.attachView(this, _scope, _show);
    widget.activity.addListener(_invalidate);
    widget.model.addListener(_invalidate);
    widget.navigation.addListener(_invalidate);
  }

  void _unlisten(ForegroundMessageNotice source) {
    source.activity.detachView(this);
    source.activity.removeListener(_invalidate);
    source.model.removeListener(_invalidate);
    source.navigation.removeListener(_invalidate);
  }

  Object? _scope() {
    final model = widget.model;
    final session = model.ownAiSessionContext;
    final unlocked = model.ownAiDirectContext;
    final view = widget.activeViewGeneration();
    if (!mounted ||
        view == null ||
        _route?.isCurrent != true ||
        !model.authenticated ||
        model.locked ||
        !model.online ||
        session == null ||
        unlocked == null) {
      return null;
    }
    return (session, unlocked, view);
  }

  void _show(Object ticket) {
    if (!mounted || widget.activity.viewTicket != ticket) return;
    final presentation = Object();
    setState(() {
      _clear();
      _ticket = ticket;
      _presentation = presentation;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _presentation != presentation) return;
      _expiry = Timer(_duration, _dismiss);
    });
  }

  void _clear() {
    _ticket = _presentation = null;
    _expiry?.cancel();
    _expiry = null;
  }

  void _invalidate() {
    final ticket = _ticket;
    if (ticket == null || widget.activity.viewTicket == ticket) return;
    // A Navigator observer can fire while Navigator is rebuilding. Drop this
    // ticket immediately; schedule only the repaint outside that call stack.
    _clear();
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
  }

  void _dismiss() {
    if (mounted && _ticket != null) setState(_clear);
  }

  @override
  void dispose() {
    _unlisten(widget);
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ticket = _ticket;
    final visible = ticket != null && ticket == widget.activity.viewTicket;
    return JySwitcher(
      child: visible
          ? KeyedSubtree(
              key: ObjectKey(_presentation),
              child: JyBanner(
                kind: JyBannerKind.info,
                message: '收到新消息，可在聊天中查看。',
                onClose: _dismiss,
                closeTooltip: '关闭新消息提示',
              ),
            )
          : const SizedBox.shrink(key: ValueKey('foreground-notice-none')),
    );
  }
}
