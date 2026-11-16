import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'persistence.dart';

/// First AI image/file disclosure, remembered per conversation.
class ConversationConsentController {
  ConversationConsentController(this.persistence);
  final ClientPersistence persistence;
  final _serial = SerialOperations();
  final _granted = <String>{};
  bool _initialized = false;
  Future<void> initialize() => _serial.run(() async {
    if (_initialized) return;
    final data = await persistence.read();
    _granted.addAll(
      (data?['aiAttachmentConsent'] as List? ?? []).cast<String>(),
    );
    _initialized = true;
  });
  bool requiresConsent(
    String conversationId,
    MessageKind kind, {
    required bool isAi,
  }) {
    if (!_initialized) throw StateError('Call initialize first');
    return isAi &&
        (kind == MessageKind.image || kind == MessageKind.file) &&
        !_granted.contains(conversationId);
  }

  Future<void> grant(String conversationId) => _set(conversationId, true);
  Future<void> revoke(String conversationId) => _set(conversationId, false);
  Future<void> _set(String id, bool granted) => _serial.run(() async {
    if (!_initialized) throw StateError('Call initialize first');
    final next = {..._granted};
    granted ? next.add(id) : next.remove(id);
    await writeClientSection(persistence, 'aiAttachmentConsent', next.toList());
    _granted
      ..clear()
      ..addAll(next);
  });
}
