import 'dart:async';

import 'live2d_renderer_bridge.dart';

/// Where the preview surface currently is.
enum Live2DPreviewState { idle, loading, ready, failed, disposed }

/// A failed or cancelled preview. [timedOut] distinguishes a missing first
/// frame from an explicit viewer error.
final class Live2DPreviewException implements Exception {
  const Live2DPreviewException(this.message, {this.timedOut = false});

  final String message;
  final bool timedOut;

  @override
  String toString() => 'Live2DPreviewException: $message';
}

/// The shell-owned WebView (or a test double) behind a preview.
///
/// Commands are plain maps so the same controller can drive an Android
/// WebView, a Windows WebView2 host or a fake in tests. Implementations must
/// not add model bytes: model files stay behind the local asset server.
abstract interface class Live2DRendererHost {
  Stream<Map<String, Object?>> get events;
  Future<void> send(Map<String, Object?> command);
}

/// Wires a [Live2DRendererBridge] to a [Live2DRendererHost] and owns the
/// first-frame lifecycle: loading, ready, error, timeout, retry and disposal.
///
/// A preview is ready only after the viewer reports that its renderer prepared
/// and drew the first frame. The controller never turns a core update into a
/// ready state by itself.
final class Live2DPreviewController {
  Live2DPreviewController({
    required this.host,
    this.firstFrameTimeout = const Duration(seconds: 20),
  }) : _bridge = Live2DRendererBridge() {
    _subscription = host.events.listen(_onEvent, onError: _onHostError);
  }

  final Live2DRendererHost host;
  final Duration firstFrameTimeout;
  final Live2DRendererBridge _bridge;
  late final StreamSubscription<Map<String, Object?>> _subscription;

  Timer? _timer;
  Completer<void>? _pending;
  Live2DPreviewState _state = Live2DPreviewState.idle;
  String? _error;
  _LoadRequest? _lastRequest;

  Live2DPreviewState get state => _state;
  String? get error => _error;

  /// Loads [model3Url] and its textures and completes when the first frame is
  /// ready. Throws [Live2DPreviewException] on a viewer error or timeout.
  Future<void> start({
    required String modelId,
    required String model3Url,
    required List<String> textureUrls,
    required int profileRev,
  }) {
    if (_state == Live2DPreviewState.disposed) {
      throw StateError('preview controller disposed');
    }
    final request = _LoadRequest(
      modelId: modelId,
      model3Url: model3Url,
      textureUrls: List<String>.unmodifiable(textureUrls),
      profileRev: profileRev,
    );
    _lastRequest = request;
    return _start(request);
  }

  /// Retries the most recent [start] request after a failure.
  Future<void> retry() {
    if (_state == Live2DPreviewState.disposed) {
      throw StateError('preview controller disposed');
    }
    final request = _lastRequest;
    if (request == null) {
      throw StateError('no preview to retry');
    }
    return _start(request);
  }

  /// Releases the viewer and makes this controller terminal. Safe to call
  /// repeatedly.
  Future<void> close() async {
    if (_state == Live2DPreviewState.disposed) return;
    _timer?.cancel();
    _timer = null;
    await _subscription.cancel();

    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const Live2DPreviewException('preview closed'));
    }

    _state = Live2DPreviewState.disposed;
    _error = null;
    try {
      await host.send(_bridge.disposeCommand());
    } catch (_) {
      // Best-effort cleanup; the controller is already terminal.
    }
    _bridge.dispose();
  }

  Future<void> _start(_LoadRequest request) async {
    _timer?.cancel();
    _timer = null;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const Live2DPreviewException('preview superseded'));
    }
    final completer = Completer<void>();
    _pending = completer;
    _error = null;

    try {
      _bridge.markLoading(request.modelId);
      _state = Live2DPreviewState.loading;
      await host.send(
        _bridge.loadCommand(
          modelId: request.modelId,
          model3Url: request.model3Url,
          textureUrls: request.textureUrls,
          profileRev: request.profileRev,
        ),
      );
    } catch (error, stackTrace) {
      _fail('could not start the preview: $error', stackTrace: stackTrace);
      return completer.future;
    }

    _timer = Timer(firstFrameTimeout, () {
      _fail('first frame timed out', timedOut: true, sendDispose: true);
    });
    return completer.future;
  }

  void _onEvent(Map<String, Object?> event) {
    if (_state != Live2DPreviewState.loading) return;
    try {
      _bridge.handleEvent(event);
    } catch (error) {
      _fail('invalid viewer event: $error');
      return;
    }
    switch (_bridge.state) {
      case Live2DRendererState.ready:
        _succeed();
      case Live2DRendererState.error:
        _fail(_bridge.lastError ?? 'viewer reported an error');
      default:
        break;
    }
  }

  void _onHostError(Object error) {
    if (_state != Live2DPreviewState.loading) return;
    _fail('renderer channel failed: $error');
  }

  void _succeed() {
    _timer?.cancel();
    _timer = null;
    _state = Live2DPreviewState.ready;
    _error = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  void _fail(
    String message, {
    bool timedOut = false,
    bool sendDispose = false,
    StackTrace? stackTrace,
  }) {
    if (_state == Live2DPreviewState.disposed) return;
    _timer?.cancel();
    _timer = null;
    try {
      _bridge.markError(message);
    } catch (_) {
      // Already ready or error: keep the controller state authoritative.
    }
    _state = Live2DPreviewState.failed;
    _error = message;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        Live2DPreviewException(message, timedOut: timedOut),
        stackTrace,
      );
    }
    if (sendDispose) unawaited(_sendDispose());
  }

  Future<void> _sendDispose() async {
    try {
      await host.send(_bridge.disposeCommand());
    } catch (_) {
      // The viewer may already be gone; retry can still send a fresh load.
    }
  }
}

final class _LoadRequest {
  const _LoadRequest({
    required this.modelId,
    required this.model3Url,
    required this.textureUrls,
    required this.profileRev,
  });

  final String modelId;
  final String model3Url;
  final List<String> textureUrls;
  final int profileRev;
}
