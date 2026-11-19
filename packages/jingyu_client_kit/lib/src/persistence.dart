import 'dart:async';

/// Durable JSON-compatible snapshot storage supplied by the platform adapter.
/// write must replace the snapshot atomically; errors must propagate.
abstract class ClientPersistence {
  Future<Map<String, Object?>?> read();
  Future<void> write(Map<String, Object?> snapshot);
}

/// Serializes read/modify/write across controllers sharing an adapter instance.
final Expando<Future<void>> _writes = Expando();

/// Writes a section without losing other controllers' changes. [checkActive]
/// may throw before the read or before starting the replacement, not cancel an
/// already-started write.
Future<void> writeClientSection(
  ClientPersistence store,
  String key,
  Object? value, {
  void Function()? checkActive,
}) {
  final previous = _writes[store] ?? Future<void>.value();
  final next = previous.then((_) async {
    checkActive?.call();
    final snapshot = await store.read() ?? <String, Object?>{};
    checkActive?.call();
    await store.write({...snapshot, key: value});
  });
  _writes[store] = next.then<void>(
    (_) {},
    onError: (Object _, StackTrace _) {},
  );
  return next;
}

class SerialOperations {
  Future<void> _tail = Future<void>.value();
  Future<T> run<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}
