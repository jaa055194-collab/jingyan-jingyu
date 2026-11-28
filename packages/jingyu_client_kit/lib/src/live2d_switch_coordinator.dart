import 'dart:async';

import 'live2d_renderer_controller.dart';

/// A failed preload or swap step. [code] is the viewer's reason, such as
/// `texture_budget`, `busy`, `not_preloaded`, `render_failed` or `timeout`.
final class Live2DSwitchException implements Exception {
  const Live2DSwitchException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'Live2DSwitchException($code): $message';
}

/// Drives the viewer's two-stage hot switch (`preload` then `swap`) on a host
/// that is already running a model.
///
/// The preview controller owns `load`/`ready`; this coordinator only handles
/// the additive switch protocol, so it can share the same broadcast event
/// stream. It never releases the old model itself: the viewer does that only
/// after the incoming model's first frame succeeds.
final class Live2DSwitchCoordinator {
  Live2DSwitchCoordinator({
    required this.host,
    this.timeout = const Duration(seconds: 30),
  }) {
    _subscription = host.events.listen(_onEvent);
  }

  final Live2DRendererHost host;
  final Duration timeout;
  late final StreamSubscription<Map<String, Object?>> _subscription;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  bool _disposed = false;

  /// Stages [model3Url] behind the shown model. Completes with the
  /// `preloaded` event, or throws [Live2DSwitchException] for
  /// `preload_rejected`, `preload_failed`, a host error or a timeout.
  Future<Map<String, Object?>> preload({
    required String loadId,
    required String modelId,
    required String model3Url,
    required List<String> textureUrls,
    required int profileRev,
  }) {
    _requireUsable();
    final key = 'preload:$loadId';
    final completer = Completer<Map<String, Object?>>();
    _pending[key] = completer;
    unawaited(
      host
          .send(<String, Object?>{
            'cmd': 'preload',
            'loadId': loadId,
            'modelId': modelId,
            'model3': model3Url,
            'textureUrls': List<String>.unmodifiable(textureUrls),
            'profileRev': profileRev,
          })
          .catchError((Object error, StackTrace stack) {
            _completeError(
              key,
              Live2DSwitchException('send_failed', '$error'),
              stack,
            );
          }),
    );
    return _wait(key, completer);
  }

  /// Fades from the shown model to the model staged as [loadId]. Completes
  /// with the `swapped` event, or throws for `swap_failed`, a host error or a
  /// timeout. [fadeMs] defaults to 250 and is clamped by the viewer.
  Future<Map<String, Object?>> swap({
    required String loadId,
    int fadeMs = 250,
  }) {
    _requireUsable();
    final key = 'swap:$loadId';
    final completer = Completer<Map<String, Object?>>();
    _pending[key] = completer;
    unawaited(
      host
          .send(<String, Object?>{
            'cmd': 'swap',
            'loadId': loadId,
            'fadeMs': fadeMs,
          })
          .catchError((Object error, StackTrace stack) {
            _completeError(
              key,
              Live2DSwitchException('send_failed', '$error'),
              stack,
            );
          }),
    );
    return _wait(key, completer);
  }

  /// Stops listening. Pending calls fail with `disposed`.
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _pending.entries) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(
          const Live2DSwitchException('disposed', 'switch coordinator closed'),
        );
      }
    }
    _pending.clear();
    await _subscription.cancel();
  }

  Future<Map<String, Object?>> _wait(
    String key,
    Completer<Map<String, Object?>> completer,
  ) {
    final future = completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(key);
        throw const Live2DSwitchException('timeout', 'switch step timed out');
      },
    );
    return future.whenComplete(() => _pending.remove(key));
  }

  void _completeError(String key, Object error, StackTrace stack) {
    final completer = _pending.remove(key);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error, stack);
    }
  }

  void _onEvent(Map<String, Object?> event) {
    if (_disposed) return;
    final name = event['event'];
    final loadId = event['loadId'];
    if (loadId is! String) return;
    switch (name) {
      case 'preloaded':
        _complete('preload:$loadId', event);
      case 'preload_rejected':
      case 'preload_failed':
        _completeError(
          'preload:$loadId',
          Live2DSwitchException(
            '${event['code'] ?? 'preload_failed'}',
            '${event['message'] ?? event['code'] ?? 'preload failed'}',
          ),
          StackTrace.current,
        );
      case 'swapped':
        _complete('swap:$loadId', event);
      case 'swap_failed':
        _completeError(
          'swap:$loadId',
          Live2DSwitchException(
            '${event['code'] ?? 'swap_failed'}',
            '${event['message'] ?? event['code'] ?? 'swap failed'}',
          ),
          StackTrace.current,
        );
    }
  }

  void _complete(String key, Map<String, Object?> event) {
    final completer = _pending.remove(key);
    if (completer != null && !completer.isCompleted) completer.complete(event);
  }

  void _requireUsable() {
    if (_disposed) {
      throw StateError('switch coordinator disposed');
    }
  }
}
