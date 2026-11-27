// Test doubles for the native side of the `jingyu/live2d_view` platform view.
//
// FakeLive2DPlatformViews answers SystemChannels.platform_views the way
// FakeAndroidPlatformViewsController in flutter/flutter does
// (packages/flutter/test/services/fake_platform_views.dart, BSD-3-Clause,
// https://github.com/flutter/flutter/blob/master/LICENSE); this is a reduced
// adaptation, not a copy. Native-to-Dart calls use
// TestDefaultBinaryMessenger.handlePlatformMessage, see
// https://api.flutter.dev/flutter/flutter_test/TestDefaultBinaryMessenger/handlePlatformMessage.html
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// The native side of one `jingyu/live2d_view` view: its method channel and
/// the page inside it.
final class FakeLive2DView {
  FakeLive2DView(this.viewId)
    : channel = MethodChannel('jingyu/live2d_view/$viewId'),
      baseUrl = 'https://appassets.androidplatform.net/live2d/model/t$viewId/' {
    _messenger.setMockMethodCallHandler(channel, _handle);
  }

  final int viewId;
  final MethodChannel channel;

  /// What `serve` returns unless [serveError] is set.
  String baseUrl;
  PlatformException? serveError;

  /// Like the shell, posts fail with `not_ready` until the page has sent a
  /// message, and with `gone` once the renderer went away.
  bool pageReady = false;
  bool gone = false;

  /// Every call from Dart, in order.
  final List<MethodCall> calls = <MethodCall>[];

  /// The commands Dart posted to the page, decoded, in order.
  final List<Map<String, Object?>> posted = <Map<String, Object?>>[];

  List<Object?> get postedCommands => [
    for (final command in posted) command['cmd'],
  ];

  /// The page's first message.
  Future<void> boot() => page(const <String, Object?>{'event': 'boot'});

  /// The viewer's first-frame report. [report] adds model report fields,
  /// such as `parameters`, `expressions` or `motions`.
  Future<void> ready({
    String modelId = 'preview',
    int profileRev = 1,
    Map<String, Object?> report = const <String, Object?>{},
  }) =>
      page(<String, Object?>{
        'event': 'ready',
        'modelId': modelId,
        'profileRev': profileRev,
        ...report,
      });

  /// A viewer error, while loading or after ready.
  Future<void> viewerError(String message, {String code = 'render_failed'}) =>
      page(<String, Object?>{'event': 'error', 'code': code, 'message': message});

  Future<void> page(Map<String, Object?> event) => pageText(jsonEncode(event));

  /// Forwards a page message unparsed, as the shell does.
  Future<void> pageText(String message) {
    pageReady = true;
    return _call('message', message);
  }

  Future<void> pageError(String description) =>
      _call('pageError', description);

  Future<void> renderProcessGone({bool didCrash = true}) {
    gone = true;
    return _call('renderProcessGone', <String, Object?>{'didCrash': didCrash});
  }

  void detach() => _messenger.setMockMethodCallHandler(channel, null);

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'serve':
        final failure = serveError;
        if (failure != null) throw failure;
        return baseUrl;
      case 'post':
        if (gone) {
          throw PlatformException(code: 'gone', message: 'renderer gone');
        }
        if (!pageReady) {
          throw PlatformException(code: 'not_ready', message: 'page not ready');
        }
        final arguments = call.arguments as Map<Object?, Object?>;
        final message = arguments['message']! as String;
        posted.add(jsonDecode(message) as Map<String, Object?>);
        return null;
    }
    throw MissingPluginException('no handler for ${call.method}');
  }

  Future<void> _call(String method, Object? arguments) async {
    await _messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      ),
      (_) {},
    );
  }
}

/// Answers `SystemChannels.platform_views` and gives each
/// `jingyu/live2d_view` view that Dart creates a [FakeLive2DView].
final class FakeLive2DPlatformViews {
  FakeLive2DPlatformViews() {
    _messenger.setMockMethodCallHandler(SystemChannels.platform_views, _handle);
  }

  /// Created views by id, in creation order.
  final Map<int, FakeLive2DView> views = <int, FakeLive2DView>{};

  /// Ids of the views that Dart disposed.
  final Set<int> disposed = <int>{};

  /// Runs for each new view before Dart learns that it exists.
  void Function(FakeLive2DView view)? onCreate;

  FakeLive2DView get last => views.values.last;

  void dispose() {
    _messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    for (final view in views.values) {
      view.detach();
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    final arguments = call.arguments;
    switch (call.method) {
      case 'create':
        final args = arguments as Map<Object?, Object?>;
        if (args['viewType'] != 'jingyu/live2d_view') {
          throw PlatformException(code: 'unknown_view_type');
        }
        final view = FakeLive2DView(args['id']! as int);
        views[view.viewId] = view;
        onCreate?.call(view);
        return 0; // A texture id: texture layer mode.
      case 'resize':
        final args = arguments as Map<Object?, Object?>;
        return <String, Object?>{
          'width': args['width'],
          'height': args['height'],
        };
      case 'dispose':
        final id = arguments is Map ? arguments['id'] : arguments;
        if (id is int) {
          disposed.add(id);
          views[id]?.detach();
        }
        return null;
    }
    return null; // offset, touch, setDirection, clearFocus and the like.
  }
}
