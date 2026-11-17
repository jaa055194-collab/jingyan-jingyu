/// Flutter ↔ WebView Live2D renderer bridge contract.
///
/// Pure Dart state machine and message builders. The shell owns the actual
/// WebView and asset serving; this type validates command/event shapes and
/// prevents illegal transitions. It never carries model bytes.
library;

enum Live2DRendererState { idle, loading, ready, error, disposed }

class Live2DRendererBridge {
  Live2DRendererState _state = Live2DRendererState.idle;
  String? _modelId;
  int? _profileRev;
  String? _lastError;

  Live2DRendererState get state => _state;
  String? get modelId => _modelId;
  int? get profileRev => _profileRev;
  String? get lastError => _lastError;

  void _requireNotDisposed() {
    if (_state == Live2DRendererState.disposed) {
      throw StateError('renderer bridge disposed');
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
    _lastError = message;
    _state = Live2DRendererState.error;
  }

  void dispose() {
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
      'textures': List<String>.unmodifiable(textureUrls),
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
    final name = event['event'];
    switch (name) {
      case 'ready':
        final modelId = event['modelId'];
        final rev = event['profileRev'];
        if (modelId is! String || rev is! int) {
          throw const FormatException('ready event needs modelId and profileRev');
        }
        if (_state != Live2DRendererState.loading && _state != Live2DRendererState.ready) {
          throw StateError('unexpected ready event');
        }
        _modelId = modelId;
        _profileRev = rev;
        _state = Live2DRendererState.ready;
      case 'error':
        final message = event['message'];
        if (message is! String || message.trim().isEmpty) {
          throw const FormatException('error event needs a message');
        }
        _lastError = message;
        _state = Live2DRendererState.error;
      case 'frame':
        // Progress ping; no state change.
        break;
      default:
        throw FormatException('unknown viewer event: $name');
    }
  }
}
