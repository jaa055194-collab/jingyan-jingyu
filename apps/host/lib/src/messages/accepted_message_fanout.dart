import 'accepted_message_observer.dart';
import 'message_store.dart';

/// Local sequential composition under one observer provider. This adds no
/// delivery/retry guarantee; each child still owns its dispatch policy.
final class AcceptedMessageFanout implements AcceptedMessageObserver {
  AcceptedMessageFanout(List<AcceptedMessageObserver> observers)
    : _observers = List<AcceptedMessageObserver>.unmodifiable(observers);

  final List<AcceptedMessageObserver> _observers;

  @override
  Future<void> onAccepted(StoredMessage message) async {
    for (final observer in _observers) {
      try {
        await observer.onAccepted(message);
      } catch (_) {
        // Accepted input is already committed. Isolate each child failure;
        // exception details may contain private content and must not be logged.
      }
    }
  }
}
