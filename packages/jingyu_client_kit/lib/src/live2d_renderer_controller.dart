import 'dart:async';

import 'live2d_model_info.dart';
import 'live2d_renderer_bridge.dart';

/// Where the preview surface currently is.
enum Live2DPreviewState { idle, loading, ready, failed, disposed }

/// A failed or cancelled preview. [timedOut] distinguishes a missing first
/// frame from an explicit viewer error.
final class Live2DPreviewException implements Exception {
  const Live2DPreviewException(
    this.message, {
    this.timedOut = false,
    this.cause,
  });

  final String message;
  final bool timedOut;

  /// The error behind the failure when there is one: a host stream error, a
  /// failed send or an invalid viewer event. Null for errors the viewer
  /// reported itself, for timeouts and for cancellations.
  final Object? cause;

  @override
  String toString() => 'Live2DPreviewException: $message';
}

/// The shell-owned WebView (or a test double) behind a preview.
///
/// Commands are plain maps so the same controller can drive an Android
/// WebView, a Windows WebView2 host or a fake in tests. Implementations must
/// not add model bytes: model files stay behind the local asset server.
///
/// Errors on [events] are host failures, such as a page that failed to load
/// or a renderer process that went away.
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
///
/// A ready preview still fails when the viewer reports an error (for example a
/// lost WebGL context) or the host reports a failure. The failure is reported
/// once, through [state], [failure] and [states], and [retry] loads the model
/// again. Events and host errors while idle, failed or disposed are ignored.
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
  final StreamController<Live2DPreviewState> _states =
      StreamController<Live2DPreviewState>.broadcast();

  Timer? _timer;
  Completer<void>? _pending;
  Live2DPreviewState _state = Live2DPreviewState.idle;
  Live2DPreviewException? _failure;
  _LoadRequest? _lastRequest;

  Live2DPreviewState get state => _state;

  /// The message of [failure], or null when the preview has not failed.
  String? get error => _failure?.message;

  /// Why the preview is [Live2DPreviewState.failed]; null in other states.
  Live2DPreviewException? get failure => _failure;

  /// What the viewer reported about the model with its first frame, such as
  /// the runtime's parameter and part IDs. Null unless [state] is
  /// [Live2DPreviewState.ready], and null when that report was malformed
  /// (see [modelInfoError]).
  Live2DModelInfo? get modelInfo =>
      _state == Live2DPreviewState.ready ? _bridge.modelInfo : null;

  /// Why the viewer's model report was rejected, or null. A rejected report
  /// does not fail the preview; it only leaves [modelInfo] null, so no
  /// mapping can be checked against that model. Null unless [state] is
  /// [Live2DPreviewState.ready].
  String? get modelInfoError =>
      _state == Live2DPreviewState.ready ? _bridge.modelInfoError : null;

  /// Each state change, in order. A broadcast stream that ends after [close]
  /// reports [Live2DPreviewState.disposed].
  Stream<Live2DPreviewState> get states => _states.stream;

  /// Loads [model3Url] and its textures and completes when the first frame is
  /// ready. Throws [Live2DPreviewException] on a viewer error or timeout, and
  /// when a newer [start] or [retry] supersedes this load or [close] cancels
  /// it.
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

  /// Sets the model parameter [id] to [value], in the parameter's own units,
  /// on the ready preview. Completes with a [StateError] unless [state] is
  /// [Live2DPreviewState.ready], and with a [FormatException] for an ID the
  /// model did not report or a value outside the reported range; neither
  /// sends anything.
  Future<void> setParameter(String id, double value) async {
    if (_state != Live2DPreviewState.ready) {
      throw StateError('parameters require a ready preview');
    }
    await host.send(_bridge.parameterCommand(id, value));
  }

  /// Releases the model parameter [id] that [setParameter] holds, so the
  /// viewer's own animation drives it again. Completes with a [StateError]
  /// unless [state] is [Live2DPreviewState.ready], and with a
  /// [FormatException] for an ID the model did not report; neither sends
  /// anything.
  Future<void> clearParameter(String id) async {
    if (_state != Live2DPreviewState.ready) {
      throw StateError('parameters require a ready preview');
    }
    await host.send(_bridge.parameterClearCommand(id));
  }

  /// Shows the expression [name] on the ready preview. Completes with a
  /// [StateError] unless [state] is [Live2DPreviewState.ready], and with a
  /// [FormatException] for a name the model did not report; neither sends
  /// anything.
  Future<void> setExpression(String name) async {
    if (_state != Live2DPreviewState.ready) {
      throw StateError('expressions require a ready preview');
    }
    await host.send(_bridge.expressionCommand(name));
  }

  /// Clears the expression of the ready preview. Completes with a
  /// [StateError] unless [state] is [Live2DPreviewState.ready], without
  /// sending anything.
  Future<void> clearExpression() async {
    if (_state != Live2DPreviewState.ready) {
      throw StateError('expressions require a ready preview');
    }
    await host.send(_bridge.expressionClearCommand());
  }

  /// Plays motion [index] of [group] on the ready preview. Completes with a
  /// [StateError] unless [state] is [Live2DPreviewState.ready], and with a
  /// [FormatException] for a negative index or a group or index the model
  /// did not report; neither sends anything.
  Future<void> playMotion(String group, int index) async {
    if (_state != Live2DPreviewState.ready) {
      throw StateError('motions require a ready preview');
    }
    await host.send(_bridge.motionCommand(group, index));
  }

  /// Sets the parameters the ready preview blinks with ([blink]) and the ones
  /// it moves for lip sync ([mouth]). Completes with a [StateError] unless
  /// [state] is [Live2DPreviewState.ready], and with a [FormatException] for
  /// a list the bridge rejects; neither sends anything.
  Future<void> setBehavior({
    required List<String> blink,
    required List<String> mouth,
  }) async {
    if (_state != Live2DPreviewState.ready) {
      throw StateError('behavior requires a ready preview');
    }
    await host.send(_bridge.behaviorCommand(blink: blink, mouth: mouth));
  }

  /// Makes the ready preview blink once. Completes with a [StateError] unless
  /// [state] is [Live2DPreviewState.ready], without sending anything.
  Future<void> blink() async {
    if (_state != Live2DPreviewState.ready) {
      throw StateError('blinks require a ready preview');
    }
    await host.send(_bridge.blinkCommand());
  }

  /// Plays the lip-sync envelope [levels], one mouth level from 0 to 1 per
  /// [stepMs] milliseconds, on the ready preview; an empty list stops speech.
  /// Completes with a [StateError] unless [state] is
  /// [Live2DPreviewState.ready], and with a [FormatException] for levels or a
  /// step the bridge rejects; neither sends anything.
  Future<void> speak(List<double> levels, int stepMs) async {
    if (_state != Live2DPreviewState.ready) {
      throw StateError('speech requires a ready preview');
    }
    await host.send(_bridge.speakCommand(levels, stepMs));
  }

  /// Stops the viewer's frame loop without releasing the model, so an avatar
  /// that is not on screen costs less. Idempotent. Throws [StateError] after
  /// [close].
  Future<void> pause() async {
    if (_state == Live2DPreviewState.disposed) {
      throw StateError('preview controller disposed');
    }
    await host.send(_bridge.pauseCommand());
  }

  /// Resumes the frame loop after [pause]. Idempotent. Throws [StateError]
  /// after [close].
  Future<void> resume() async {
    if (_state == Live2DPreviewState.disposed) {
      throw StateError('preview controller disposed');
    }
    await host.send(_bridge.resumeCommand());
  }

  /// Releases the viewer and makes this controller terminal. Safe to call
  /// repeatedly.
  Future<void> close() async {
    if (_state == Live2DPreviewState.disposed) return;
    _cancelTimer();
    final pending = _pending;
    _pending = null;
    _failure = null;
    _setState(Live2DPreviewState.disposed);
    unawaited(_states.close());
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const Live2DPreviewException('preview closed'));
    }
    await _subscription.cancel();
    try {
      await host.send(_bridge.disposeCommand());
    } catch (_) {
      // Best-effort cleanup; the controller is already terminal.
    }
    _bridge.dispose();
  }

  /// Returns the completer's own future, so callers can listen before a
  /// superseded or failed load completes it with an error.
  Future<void> _start(_LoadRequest request) {
    _cancelTimer();
    final previous = _pending;
    if (previous != null && !previous.isCompleted) {
      previous.completeError(
        const Live2DPreviewException('preview superseded'),
      );
    }
    final completer = Completer<void>();
    _pending = completer;
    _failure = null;
    unawaited(_load(request, completer));
    return completer.future;
  }

  /// Runs synchronously up to the send, so callers see the loading state and
  /// the load command as soon as [start] or [retry] returns.
  Future<void> _load(_LoadRequest request, Completer<void> completer) async {
    try {
      _bridge.markLoading(request.modelId);
      _setState(Live2DPreviewState.loading);
      await host.send(
        _bridge.loadCommand(
          modelId: request.modelId,
          model3Url: request.model3Url,
          textureUrls: request.textureUrls,
          profileRev: request.profileRev,
        ),
      );
    } catch (error, stackTrace) {
      // A send that fails after a newer load or close took over is stale.
      if (identical(_pending, completer)) {
        _fail(
          'could not start the preview: $error',
          cause: error,
          stackTrace: stackTrace,
        );
      }
      return;
    }
    // The first frame may have arrived while the command was in flight; only
    // a load that is still waiting gets a timeout.
    if (!identical(_pending, completer)) return;
    _timer = Timer(firstFrameTimeout, () {
      if (identical(_pending, completer)) {
        _fail('first frame timed out', timedOut: true, sendDispose: true);
      }
    });
  }

  void _onEvent(Map<String, Object?> event) {
    if (_state == Live2DPreviewState.loading) {
      _onLoadingEvent(event);
    } else if (_state == Live2DPreviewState.ready) {
      _onReadyEvent(event);
    }
    // Idle, failed or disposed: stray and late events change nothing.
  }

  void _onLoadingEvent(Map<String, Object?> event) {
    try {
      _bridge.handleEvent(event);
    } catch (error, stackTrace) {
      _fail(
        'invalid viewer event: $error',
        cause: error,
        stackTrace: stackTrace,
      );
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

  /// After the first frame only errors matter: frame pings and repeated ready
  /// events change nothing.
  void _onReadyEvent(Map<String, Object?> event) {
    if (event['event'] != 'error') return;
    final message = event['message'];
    _fail(
      message is String && message.trim().isNotEmpty
          ? message
          : 'viewer reported an error',
    );
  }

  void _onHostError(Object error, StackTrace stackTrace) {
    if (_state != Live2DPreviewState.loading &&
        _state != Live2DPreviewState.ready) {
      return; // Before a load, after a failure or after close.
    }
    _fail(
      'renderer channel failed: $error',
      cause: error,
      stackTrace: stackTrace,
    );
  }

  void _succeed() {
    _cancelTimer();
    _failure = null;
    _setState(Live2DPreviewState.ready);
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  void _fail(
    String message, {
    bool timedOut = false,
    bool sendDispose = false,
    Object? cause,
    StackTrace? stackTrace,
  }) {
    if (_state == Live2DPreviewState.disposed) return;
    _cancelTimer();
    try {
      _bridge.markError(message);
    } catch (_) {
      // Not loading or ready: keep the controller state authoritative.
    }
    final failure = Live2DPreviewException(
      message,
      timedOut: timedOut,
      cause: cause,
    );
    _failure = failure;
    _setState(Live2DPreviewState.failed);
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(failure, stackTrace);
    }
    if (sendDispose) unawaited(_sendDispose());
  }

  void _setState(Live2DPreviewState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
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
