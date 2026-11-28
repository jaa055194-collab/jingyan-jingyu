/// Flutter ↔ WebView Live2D renderer bridge contract.
///
/// Pure Dart state machine and message builders. The shell owns the actual
/// WebView and asset serving; this type validates command/event shapes and
/// prevents illegal transitions. It never carries model bytes.
library;

import 'live2d_model_info.dart';

enum Live2DRendererState { idle, loading, ready, error, disposed }

class Live2DRendererBridge {
  /// The most IDs each list of a [behaviorCommand] may hold.
  static const int maxBehaviorIds = 64;

  /// The most levels a [speakCommand] may carry.
  static const int maxSpeakLevels = 3000;

  /// The shortest [speakCommand] step, in milliseconds.
  static const int minSpeakStepMs = 10;

  /// The longest [speakCommand] step, in milliseconds.
  static const int maxSpeakStepMs = 100;

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

  /// The `setParam` command. The viewer writes [value] to the model parameter
  /// [name] as it is, so it is in the parameter's own units rather than
  /// 0..1, and holds it there every frame until a [parameterClearCommand] for
  /// [name] or a new load releases it. The value must be finite. When the
  /// model reported its parameter IDs, [name] must be one of them, and when it
  /// reported this parameter's range, [value] must lie within it.
  Map<String, Object?> parameterCommand(String name, double value) {
    if (_state != Live2DRendererState.ready) {
      throw StateError('parameters require a ready renderer');
    }
    if (name.trim().isEmpty) {
      throw const FormatException('parameter name must be non-empty');
    }
    if (!value.isFinite) {
      throw const FormatException('parameter value must be finite');
    }
    final info = modelInfo;
    final ids = info?.parameterIds;
    if (ids != null && !ids.contains(name)) {
      throw FormatException('unknown parameter', name);
    }
    final parameter = info?.parameter(name);
    final min = parameter?.min;
    final max = parameter?.max;
    if ((min != null && value < min) || (max != null && value > max)) {
      throw FormatException('parameter value outside its range', value);
    }
    return {'cmd': 'setParam', 'name': name, 'value': value};
  }

  /// The `clearParam` command: the viewer stops holding the value a
  /// [parameterCommand] set for [name], so its own animation drives that
  /// parameter again. When the model reported its parameter IDs, [name] must
  /// be one of them.
  Map<String, Object?> parameterClearCommand(String name) {
    if (_state != Live2DRendererState.ready) {
      throw StateError('parameters require a ready renderer');
    }
    if (name.trim().isEmpty) {
      throw const FormatException('parameter name must be non-empty');
    }
    final ids = modelInfo?.parameterIds;
    if (ids != null && !ids.contains(name)) {
      throw FormatException('unknown parameter', name);
    }
    return {'cmd': 'clearParam', 'name': name};
  }

  /// The `setExpression` command. When the model reported its expressions,
  /// [name] must be one of them.
  Map<String, Object?> expressionCommand(String name) {
    if (_state != Live2DRendererState.ready) {
      throw StateError('expressions require a ready renderer');
    }
    if (name.trim().isEmpty) {
      throw const FormatException('expression name must be non-empty');
    }
    final names = modelInfo?.expressionNames;
    if (names != null && !names.contains(name)) {
      throw FormatException('unknown expression', name);
    }
    return {'cmd': 'setExpression', 'name': name};
  }

  /// The `setExpression` command without a name, which clears the expression.
  Map<String, Object?> expressionClearCommand() {
    if (_state != Live2DRendererState.ready) {
      throw StateError('expressions require a ready renderer');
    }
    return const {'cmd': 'setExpression', 'name': null};
  }

  /// The `setMotion` command. [group] may be empty, as Cubism allows, and
  /// [index] must not be negative. When the model reported its motions,
  /// [group] must be one of their groups and [index] below its count.
  Map<String, Object?> motionCommand(String group, int index) {
    if (_state != Live2DRendererState.ready) {
      throw StateError('motions require a ready renderer');
    }
    if (index < 0) {
      throw FormatException('motion index must not be negative', index);
    }
    final info = modelInfo;
    if (info != null && info.motions != null) {
      final count = info.motionCount(group);
      if (count == null) {
        throw FormatException('unknown motion group', group);
      }
      if (index >= count) {
        throw FormatException('motion index beyond its group', index);
      }
    }
    return {'cmd': 'setMotion', 'group': group, 'index': index};
  }

  /// The `behavior` command: the parameters the viewer blinks with and the
  /// ones it moves for lip sync. Each list holds at most [maxBehaviorIds]
  /// distinct, non-empty IDs, and an empty list leaves that behaviour without
  /// parameters. When the model reported its parameter IDs, every ID must be
  /// one of them.
  Map<String, Object?> behaviorCommand({
    required List<String> blink,
    required List<String> mouth,
  }) {
    if (_state != Live2DRendererState.ready) {
      throw StateError('behavior requires a ready renderer');
    }
    _checkBehaviorIds(blink, 'blink');
    _checkBehaviorIds(mouth, 'mouth');
    return {
      'cmd': 'behavior',
      'blink': List<String>.unmodifiable(blink),
      'mouth': List<String>.unmodifiable(mouth),
    };
  }

  void _checkBehaviorIds(List<String> ids, String list) {
    if (ids.length > maxBehaviorIds) {
      throw FormatException('$list holds more than $maxBehaviorIds IDs');
    }
    final known = modelInfo?.parameterIds;
    final seen = <String>{};
    for (final id in ids) {
      if (id.trim().isEmpty) {
        throw FormatException('$list IDs must be non-empty');
      }
      if (!seen.add(id)) {
        throw FormatException('$list repeats an ID', id);
      }
      if (known != null && !known.contains(id)) {
        throw FormatException('unknown $list parameter', id);
      }
    }
  }

  /// The `blink` command: one blink at once, unless one is running.
  Map<String, Object?> blinkCommand() {
    if (_state != Live2DRendererState.ready) {
      throw StateError('blinks require a ready renderer');
    }
    return const {'cmd': 'blink'};
  }

  /// The `speak` command: a lip-sync envelope the viewer plays from its next
  /// frame, one mouth level from 0 to 1 per [stepMs] milliseconds, which it
  /// maps onto each lip-sync parameter's range. [levels] holds at most
  /// [maxSpeakLevels] finite levels, and an empty list stops speech. [stepMs]
  /// runs from [minSpeakStepMs] to [maxSpeakStepMs].
  Map<String, Object?> speakCommand(List<double> levels, int stepMs) {
    if (_state != Live2DRendererState.ready) {
      throw StateError('speech requires a ready renderer');
    }
    if (levels.length > maxSpeakLevels) {
      throw const FormatException(
        'speech holds more than $maxSpeakLevels levels',
      );
    }
    for (final level in levels) {
      if (!level.isFinite || level < 0 || level > 1) {
        throw FormatException('speech levels must be from 0 to 1', level);
      }
    }
    if (stepMs < minSpeakStepMs || stepMs > maxSpeakStepMs) {
      throw FormatException(
        'speech step must be $minSpeakStepMs to $maxSpeakStepMs ms',
        stepMs,
      );
    }
    return {
      'cmd': 'speak',
      'levels': List<double>.unmodifiable(levels),
      'step': stepMs,
    };
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
