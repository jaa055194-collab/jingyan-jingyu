/// Flutter ↔ WebView Live2D renderer bridge contract.
///
/// Pure Dart state machine and message builders. The shell owns the actual
/// WebView and asset serving; this type validates command/event shapes and
/// prevents illegal transitions. It never carries model bytes.
library;

import 'live2d_model_info.dart';

enum Live2DRendererState { idle, loading, ready, error, disposed }

class Live2DRendererBridge {
  Live2DRendererState _state = Live2DRendererState.idle;
  String? _modelId;
  int? _profileRev;
  String? _lastError;
  Live2DModelInfo? _modelInfo;
  String? _modelInfoError;

  Live2DRendererState get state => _state;
  String? get modelId => _modelId;
  int? get profileRev => _profileRev;
  String? get lastError => _lastError;

  /// What the viewer's `ready` event reported about the loaded model. Null
  /// until a `ready` event is handled, after an error or a new load, and when
  /// the report was malformed (see [modelInfoError]). Its lists are null when
  /// the viewer left them out.
  Live2DModelInfo? get modelInfo => _modelInfo;

  /// Why the model information in the `ready` event was rejected, or null.
  /// A rejected report does not fail the preview; it only leaves [modelInfo]
  /// null, so no mapping can be checked against that model.
  String? get modelInfoError => _modelInfoError;

  void _requireNotDisposed() {
    if (_state == Live2DRendererState.disposed) {
      throw StateError('renderer bridge disposed');
    }
  }

  void _clearModelInfo() {
    _modelInfo = null;
    _modelInfoError = null;
  }

  /// Model information never fails a load: a malformed report is recorded in
  /// [modelInfoError] and leaves [modelInfo] null.
  void _readModelInfo(Map<String, Object?> event) {
    try {
      _modelInfo = Live2DModelInfo.fromReadyEvent(event);
      _modelInfoError = null;
    } on FormatException catch (error) {
      _modelInfo = null;
      _modelInfoError = error.message;
    }
  }

  void markLoading(String modelId) {
    _requireNotDisposed();
    if (modelId.trim().isEmpty) {
      throw const FormatException('modelId must be non-empty');
    }
    _modelId = modelId;
    _profileRev = null;
    _lastError = null;
    _clearModelInfo();
    _state = Live2DRendererState.loading;
  }

  void markReady(String modelId, {required int profileRev}) {
    if (_state != Live2DRendererState.loading) {
      throw StateError('ready is only valid while loading');
    }
    if (modelId != _modelId) {
      throw StateError('ready modelId does not match loading model');
    }
    if (profileRev < 1) {
      throw const FormatException('profileRev must be positive');
    }
    _profileRev = profileRev;
    _state = Live2DRendererState.ready;
  }

  void markError(String message) {
    _requireNotDisposed();
    if (_state != Live2DRendererState.loading &&
        _state != Live2DRendererState.ready) {
      throw StateError('error is only valid after a load starts');
    }
    _lastError = message;
    _clearModelInfo();
    _state = Live2DRendererState.error;
  }

  void dispose() {
    _clearModelInfo();
    _state = Live2DRendererState.disposed;
  }

  Map<String, Object?> loadCommand({
    required String modelId,
    required String model3Url,
    required List<String> textureUrls,
    required int profileRev,
  }) {
    if (modelId.trim().isEmpty || model3Url.trim().isEmpty) {
      throw const FormatException('model references must be non-empty');
    }
    if (profileRev < 1) {
      throw const FormatException('profileRev must be positive');
    }
    return {
      'cmd': 'load',
      'modelId': modelId,
      'model3': model3Url,
      'textureUrls': List<String>.unmodifiable(textureUrls),
      'profileRev': profileRev,
    };
  }

  Map<String, Object?> parameterCommand(String name, double value) {
    if (_state != Live2DRendererState.ready) {
      throw StateError('parameters require a ready renderer');
    }
    if (name.trim().isEmpty) {
      throw const FormatException('parameter name must be non-empty');
    }
    if (value.isNaN || value.isInfinite || value < 0 || value > 1) {
      throw const FormatException('parameter value must be within 0..1');
    }
    return {'cmd': 'setParam', 'name': name, 'value': value};
  }

  Map<String, Object?> expressionCommand(String name) {
    if (_state != Live2DRendererState.ready) {
      throw StateError('expressions require a ready renderer');
    }
    if (name.trim().isEmpty) {
      throw const FormatException('expression name must be non-empty');
    }
    return {'cmd': 'setExpression', 'name': name};
  }

  Map<String, Object?> motionCommand(String group, int index) {
    if (_state != Live2DRendererState.ready) {
      throw StateError('motions require a ready renderer');
    }
    if (group.trim().isEmpty || index < 0) {
      throw const FormatException('invalid motion reference');
    }
    return {'cmd': 'setMotion', 'group': group, 'index': index};
  }

  Map<String, Object?> disposeCommand() => const {'cmd': 'dispose'};

  /// Parses an event emitted by the viewer page.
  void handleEvent(Map<String, Object?> event) {
    _requireNotDisposed();
    final name = event['event'];
    switch (name) {
      case 'ready':
        final modelId = event['modelId'];
        final rev = event['profileRev'];
        if (modelId is! String || rev is! int) {
          throw const FormatException(
            'ready event needs modelId and profileRev',
          );
        }
        if (_state != Live2DRendererState.loading) {
          throw StateError('unexpected ready event');
        }
        if (modelId != _modelId) {
          throw StateError('ready modelId does not match loading model');
        }
        if (rev < 1) {
          throw const FormatException('profileRev must be positive');
        }
        _profileRev = rev;
        _lastError = null;
        _readModelInfo(event);
        _state = Live2DRendererState.ready;
      case 'error':
        final message = event['message'];
        if (message is! String || message.trim().isEmpty) {
          throw const FormatException('error event needs a message');
        }
        if (_state != Live2DRendererState.loading &&
            _state != Live2DRendererState.ready) {
          throw StateError('unexpected error event');
        }
        _lastError = message;
        _clearModelInfo();
        _state = Live2DRendererState.error;
      case 'frame':
        // Progress ping; no state change.
        break;
      default:
        throw FormatException('unknown viewer event: $name');
    }
  }
}
