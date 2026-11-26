/// The Android host of the 3D street page (jingyu_street3d_web): a WebView
/// PlatformView that loads the page from the app's Flutter assets and carries
/// the JSON envelopes of PROTOCOL.md between the page and Dart.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The PlatformView type the plugin registers on Android.
const String street3dViewType = 'jingyu/street3d_view';

/// Why a street view stopped working.
enum Street3DAndroidFailureKind {
  /// The page did not load, or the view was given an entry it cannot serve.
  loadFailed,

  /// The WebView's renderer process went away. The view stays empty; build a
  /// new one to try again.
  crashed,

  /// The installed Android System WebView has no WebMessageListener.
  unsupported,
}

@immutable
class Street3DAndroidFailure {
  const Street3DAndroidFailure(this.kind, this.detail);

  final Street3DAndroidFailureKind kind;

  /// A short English description from the platform, for logs.
  final String detail;

  @override
  String toString() => 'Street3DAndroidFailure(${kind.name}: $detail)';
}

/// Drives one street view over its channel `jingyu/street3d_view_<id>`.
class Street3DAndroidController {
  Street3DAndroidController(int viewId, {BinaryMessenger? binaryMessenger})
    : _channel = MethodChannel(
        'jingyu/street3d_view_$viewId',
        const StandardMethodCodec(),
        binaryMessenger,
      ) {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final _messages = StreamController<String>();
  final _failures = StreamController<Street3DAndroidFailure>();
  bool _started = false;
  bool _disposed = false;

  /// The envelopes the page posted, in order. Single-subscription: what
  /// arrives before it is listened to waits.
  Stream<String> get messages => _messages.stream;

  /// The view's failures. Single-subscription, like [messages].
  Stream<Street3DAndroidFailure> get failures => _failures.stream;

  /// Loads the page. Only the first call does anything.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    try {
      await _channel.invokeMethod<void>('start');
    } on PlatformException catch (error) {
      _fail(_kindOf(error.code), error.message ?? error.code);
    } on MissingPluginException catch (error) {
      _fail(Street3DAndroidFailureKind.loadFailed, error.message ?? 'No street view.');
    }
  }

  /// Sends one envelope. Until the page has posted its first message (hello)
  /// the view holds envelopes, at most 64, dropping the oldest.
  Future<void> send(String json) => _invoke('send', json);

  Future<void> pause() => _invoke('pause');

  Future<void> resume() => _invoke('resume');

  /// Stops listening to the view. Flutter destroys the view itself when its
  /// widget leaves the tree.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    unawaited(_messages.close());
    unawaited(_failures.close());
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // The view is gone already; it reported its failure, if it had one.
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (_disposed) return null;
    switch (call.method) {
      case 'message':
        final data = call.arguments;
        if (data is String) _messages.add(data);
      case 'failure':
        final arguments = call.arguments;
        if (arguments is Map) {
          _fail(_kindOf(arguments['kind']), '${arguments['detail'] ?? ''}');
        }
      default:
        throw MissingPluginException('${call.method} is not a street view call.');
    }
    return null;
  }

  static Street3DAndroidFailureKind _kindOf(Object? code) => switch (code) {
    'crashed' => Street3DAndroidFailureKind.crashed,
    'unsupported' => Street3DAndroidFailureKind.unsupported,
    _ => Street3DAndroidFailureKind.loadFailed,
  };

  void _fail(Street3DAndroidFailureKind kind, String detail) {
    if (!_disposed) _failures.add(Street3DAndroidFailure(kind, detail));
  }
}

/// The page takes every touch in its area: orbiting, panning and taps.
final _allGestures = <Factory<OneSequenceGestureRecognizer>>{
  Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
};

/// The 3D street page in an Android WebView.
///
/// [onCreated] gets the view's controller as soon as the native view exists.
/// The page starts loading right after it returns, so listen there.
class Street3DAndroidView extends StatelessWidget {
  const Street3DAndroidView({
    super.key,
    required this.onCreated,
    this.entry = 'web/index.html',
    this.assetPackage = 'jingyu_street3d_web',
    this.bridgeName = 'Street3DBridge',
  });

  final ValueChanged<Street3DAndroidController> onCreated;

  /// The page, as a Flutter asset path inside a folder. The view serves that
  /// folder and nothing else.
  final String entry;

  /// The package that declares [entry]; empty for the app's own assets.
  final String assetPackage;

  /// The name of the JS object the page posts through.
  final String bridgeName;

  @override
  Widget build(BuildContext context) {
    return AndroidView(
      viewType: street3dViewType,
      creationParams: <String, Object?>{
        'entry': entry,
        'assetPackage': assetPackage,
        'bridgeName': bridgeName,
      },
      creationParamsCodec: const StandardMessageCodec(),
      gestureRecognizers: _allGestures,
      onPlatformViewCreated: (id) {
        final controller = Street3DAndroidController(id);
        onCreated(controller);
        unawaited(controller.start());
      },
    );
  }
}
