import 'package:flutter/foundation.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

/// A live, in-memory signal. No count, payload, destination, or account data is
/// published to the widget; it has no notification history to replay.
class ForegroundMessageActivity extends ChangeNotifier {
  Object? _foreground;
  ({Object owner, Object? Function() scope, void Function(Object) show})? _view;
  Object? _session, _baselineForeground;
  Map<String, int> _floors = const {};

  void setForeground(bool foreground) {
    if (foreground == (_foreground != null)) return;
    _foreground = foreground ? Object() : null;
    notifyListeners();
  }

  void attachView(
    Object owner,
    Object? Function() readScope,
    void Function(Object) show,
  ) => _view = (owner: owner, scope: readScope, show: show);

  void detachView(Object owner) {
    if (identical(_view?.owner, owner)) _view = null;
  }

  Object? get viewTicket {
    final view = _view;
    final foreground = _foreground;
    if (view == null || foreground == null) return null;
    final scope = view.scope();
    return scope == null ? null : (view.owner, foreground, scope);
  }

  ForegroundMessageRefresh begin({
    required Object session,
    required String self,
    required bool wasOnline,
  }) => ForegroundMessageRefresh._(
    session,
    _foreground,
    self,
    viewTicket,
    wasOnline && session == _session && _foreground == _baselineForeground
        ? _floors
        : const {},
  );

  /// Only a wholly successful, still-authorized refresh can seed or emit.
  /// A changed floor or first visit is a baseline, not a new arrival.
  void complete(ForegroundMessageRefresh refresh) {
    _session = refresh._session;
    _baselineForeground = refresh._foreground;
    _floors = refresh._floors;
    final ticket = refresh._ticket;
    if (refresh._incoming && ticket != null && ticket == viewTicket) {
      _view?.show(ticket);
    }
  }

  @override
  void dispose() {
    _view = null;
    super.dispose();
  }
}

class ForegroundMessageRefresh {
  ForegroundMessageRefresh._(
    this._session,
    this._foreground,
    this._self,
    this._ticket,
    this._previousFloors,
  );

  final Object _session;
  final Object? _foreground, _ticket;
  final String _self;
  final Map<String, int> _previousFloors;
  final _floors = <String, int>{};
  bool _incoming = false;

  /// Called only after the existing controller durably applies the frame.
  bool isIncoming(MessageEventFrame row) {
    if (_ticket == null ||
        !_previousFloors.containsKey(row.conversationId) ||
        row.senderId == _self ||
        (row.body.containsKey('recalled') && row.body['recalled'] != false)) {
      return false;
    }
    try {
      ConversationId.parse(row.conversationId);
      AccountId.parse(row.senderId);
      MessageId.parse(row.messageId);
      switch (row.kind) {
        case MessageKind.text:
          final text = row.body['text'];
          return row.body['attachmentId'] == null &&
              text is String &&
              text.trim().isNotEmpty;
        case MessageKind.image || MessageKind.file || MessageKind.audio:
          final attachment = row.body['attachmentId'];
          if (attachment is! String) return false;
          AttachmentId.parse(attachment);
          return true;
        case MessageKind.generatedImage || MessageKind.card:
          // No supported canonical shape for these additional kinds here.
          return false;
      }
    } on FormatException {
      return false;
    }
  }

  void observe(String conversation, int floor, {required bool incoming}) {
    _floors[conversation] = floor;
    if (incoming && _previousFloors[conversation] == floor) _incoming = true;
  }
}
