// Host side of the `jingyu/live2d_view` platform view. It uses the usual
// Flutter pattern of one MethodChannel per platform view, named after the id
// that AndroidView passes to onPlatformViewCreated, as described in
// https://docs.flutter.dev/platform-integration/android/platform-views and
// https://cloud.tencent.cn/developer/article/2034144 (pattern only; no code
// copied).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';

/// A failure of the native preview view, reported as an error on
/// [AndroidLive2DRendererHost.events].
final class Live2DHostException implements Exception {
  const Live2DHostException(this.code, this.message);

  /// `page_error`, `render_process_gone`, `bad_message` or `post_failed`.
  final String code;
  final String message;

  @override
  String toString() => 'Live2DHostException($code): $message';
}

/// A [Live2DRendererHost] over the method channel of one native
/// `jingyu/live2d_view` platform view.
///
/// Commands sent before the page's first message are queued and posted in
/// order when it arrives; the page's `boot` event is not forwarded. Page
/// errors and a lost renderer process become errors on [events]. Once the
/// renderer is gone, [send] reports an `error` event instead of throwing, so a
/// waiting preview fails at once instead of timing out.
final class AndroidLive2DRendererHost implements Live2DRendererHost {
  AndroidLive2DRendererHost(this.viewId, {BinaryMessenger? binaryMessenger})
    : _channel = MethodChannel(
        '$channelPrefix$viewId',
        const StandardMethodCodec(),
        binaryMessenger,
      ) {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  /// The platform view type that the Android shell registers.
  static const viewType = 'jingyu/live2d_view';

  /// The per-view method channel is this prefix followed by the view id.
  static const channelPrefix = 'jingyu/live2d_view/';

  final int viewId;
  final MethodChannel _channel;
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  final List<Map<String, Object?>> _queue = <Map<String, Object?>>[];
  bool _booted = false;
  bool _gone = false;
  bool _disposed = false;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  /// Whether the page has sent its first message.
  bool get isBooted => _booted;

  /// Whether the renderer is gone; only a new platform view can recover.
  bool get isGone => _gone;

  /// Serves the files in [directory], which must be inside
  /// `<cacheDir>/live2d-preview`, and returns their base URL, ending in `/`.
  ///
  /// Throws the shell's [PlatformException], such as `bad_directory`.
  Future<String> serve(String directory) async {
    final baseUrl = await _channel.invokeMethod<String>(
      'serve',
      <String, Object?>{'directory': directory},
    );
    if (baseUrl == null || baseUrl.isEmpty) {
      throw PlatformException(
        code: 'bad_base_url',
        message: 'serve returned no base URL',
      );
    }
    return baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
  }

  @override
  Future<void> send(Map<String, Object?> command) async {
    if (_disposed) return;
    if (_gone) {
      _reportGone(command);
    } else if (!_booted) {
      _queue.add(command);
    } else {
      await _post(command);
    }
  }

  /// Stops handling calls from the view and ends [events]. Later sends do
  /// nothing. The platform view itself goes away with its widget.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _queue.clear();
    _channel.setMethodCallHandler(null);
    unawaited(_events.close());
  }

  Future<void> _post(Map<String, Object?> command) async {
    try {
      await _channel.invokeMethod<void>(
        'post',
        <String, Object?>{'message': jsonEncode(command)},
      );
    } on PlatformException catch (error) {
      switch (error.code) {
        case 'gone':
          _markGone();
          _reportGone(command);
        case 'not_ready':
          // The page reloaded: keep the command until it boots again.
          _booted = false;
          _queue.add(command);
        default:
          rethrow;
      }
    }
  }

  Future<Object?> _onMethodCall(MethodCall call) async {
    if (_disposed || _gone) return null;
    switch (call.method) {
      case 'message':
        _onPageMessage(call.arguments);
      case 'pageError':
        _addError(Live2DHostException('page_error', '${call.arguments}'));
      case 'renderProcessGone':
        final arguments = call.arguments;
        final crashed = arguments is Map && arguments['didCrash'] == true;
        _markGone();
        _addError(
          Live2DHostException(
            'render_process_gone',
            crashed
                ? 'the renderer process crashed'
                : 'the renderer process was stopped',
          ),
        );
      default:
        throw MissingPluginException('unknown method ${call.method}');
    }
    return null;
  }

  void _onPageMessage(Object? message) {
    if (!_booted) {
      _booted = true;
      _flush();
    }
    Object? event;
    try {
      event = message is String ? jsonDecode(message) : null;
    } on FormatException {
      event = null;
    }
    if (event is! Map<String, Object?>) {
      _addError(
        const Live2DHostException(
          'bad_message',
          'page message is not a JSON object',
        ),
      );
      return;
    }
    if (event['event'] == 'boot') return;
    if (!_events.isClosed) _events.add(event);
  }

  /// Posts the queued commands in order. Their sends already completed, so a
  /// failure becomes a host error.
  void _flush() {
    final queued = List<Map<String, Object?>>.of(_queue);
    _queue.clear();
    for (final command in queued) {
      unawaited(
        _post(command).catchError((Object error) {
          _addError(
            Live2DHostException(
              'post_failed',
              'could not send ${command['cmd']}: $error',
            ),
          );
        }),
      );
    }
  }

  void _markGone() {
    _gone = true;
    _queue.clear();
  }

  void _reportGone(Map<String, Object?> command) {
    if (command['cmd'] == 'dispose' || _events.isClosed) return;
    _events.add(const <String, Object?>{
      'event': 'error',
      'code': 'renderer_gone',
      'message': 'the Live2D renderer is gone',
    });
  }

  void _addError(Live2DHostException error) {
    if (!_events.isClosed) _events.addError(error);
  }
}
