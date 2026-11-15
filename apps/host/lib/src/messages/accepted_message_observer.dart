import 'message_store.dart';

/// Optional local post-commit HTTP-send extension. Failure must not undo accepted
/// input. No delivery/retry guarantee; implementations own all dispatch policy.
abstract interface class AcceptedMessageObserver {
  Future<void> onAccepted(StoredMessage message);
}
