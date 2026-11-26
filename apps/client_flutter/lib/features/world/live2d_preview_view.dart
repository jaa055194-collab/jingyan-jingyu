// Live2D model preview hosted in the native `jingyu/live2d_view` platform
// view. The AndroidView + per-view MethodChannel wiring follows the pattern
// in https://docs.flutter.dev/platform-integration/android/platform-views
// (pattern only; no code copied).
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'android_live2d_renderer_host.dart';

/// Shows a staged Live2D model in the native `jingyu/live2d_view` view.
///
/// Serves [directory] (a stage inside the app's `live2d-preview` cache
/// directory) to the viewer page and loads [model3Name] from it. Covers the
/// view while the model loads; on failure shows the reason and a retry
/// button. Retrying starts a new native view; only a failed serve is retried
/// in the same view.
class Live2DPreviewView extends StatefulWidget {
  const Live2DPreviewView({
    super.key,
    required this.directory,
    this.modelId = 'preview',
    this.profileRev = 1,
    this.firstFrameTimeout = const Duration(seconds: 20),
  });

  /// The model file at the root of every preview stage.
  static const model3Name = 'model.model3.json';

  /// The native view type registered by the Android shell.
  static const viewType = 'jingyu/live2d_view';

  /// Absolute path of the stage directory.
  final String directory;
  final String modelId;

  /// Echoed by the viewer's ready event; must be at least 1.
  final int profileRev;
  final Duration firstFrameTimeout;

  @override
  State<Live2DPreviewView> createState() => _Live2DPreviewViewState();
}

enum _Status { loading, ready, failed }

class _Live2DPreviewViewState extends State<Live2DPreviewView> {
  /// Keys the native view; bumped to replace it with a new renderer.
  int _generation = 0;
  AndroidLive2DRendererHost? _host;
  Live2DPreviewController? _controller;
  StreamSubscription<Live2DPreviewState>? _stateChanges;
  String? _baseUrl;
  _Status _status = _Status.loading;
  String? _reason;
  String? _detail;

  @override
  void didUpdateWidget(Live2DPreviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.directory != widget.directory ||
        oldWidget.modelId != widget.modelId ||
        oldWidget.profileRev != widget.profileRev ||
        oldWidget.firstFrameTimeout != widget.firstFrameTimeout) {
      // build always follows didUpdateWidget, so no setState here.
      _replaceView();
    }
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  /// Drops the current host and controller. The native view itself goes
  /// away with its AndroidView.
  void _release() {
    unawaited(_stateChanges?.cancel());
    _stateChanges = null;
    final controller = _controller;
    final host = _host;
    _controller = null;
    _host = null;
    _baseUrl = null;
    if (controller != null) unawaited(controller.close());
    host?.dispose();
  }

  void _replaceView() {
    _release();
    _generation++;
    _status = _Status.loading;
    _reason = null;
    _detail = null;
  }

  void _onPlatformViewCreated(int generation, int viewId) {
    if (!mounted || generation != _generation) return;
    _release();
    final host = AndroidLive2DRendererHost(viewId);
    final controller = Live2DPreviewController(
      host: host,
      firstFrameTimeout: widget.firstFrameTimeout,
    );
    _host = host;
    _controller = controller;
    _stateChanges = controller.states.listen((_) => _sync(controller));
    unawaited(_serveAndLoad(host, controller));
  }

  Future<void> _serveAndLoad(
    AndroidLive2DRendererHost host,
    Live2DPreviewController controller,
  ) async {
    _show(_Status.loading);
    final String served;
    try {
      served = await host.serve(widget.directory);
    } on MissingPluginException {
      if (identical(host, _host)) {
        _show(_Status.failed, reason: '此设备暂不支持模型预览。');
      }
      return;
    } on PlatformException catch (error) {
      if (identical(host, _host)) {
        _show(
          _Status.failed,
          reason: '无法读取临时预览文件。',
          detail: _text(error.message) ?? error.code,
        );
      }
      return;
    } on Object catch (error) {
      if (identical(host, _host)) {
        _show(
          _Status.failed,
          reason: '无法读取临时预览文件。',
          detail: _text('$error'),
        );
      }
      return;
    }
    if (!identical(host, _host)) return;
    final baseUrl = served.endsWith('/') ? served : '$served/';
    _baseUrl = baseUrl;
    // Failures arrive through controller.states.
    controller
        .start(
          modelId: widget.modelId,
          model3Url: '$baseUrl${Live2DPreviewView.model3Name}',
          textureUrls: const <String>[],
          profileRev: widget.profileRev,
        )
        .ignore();
    _sync(controller);
  }

  void _sync(Live2DPreviewController controller) {
    if (!mounted || !identical(controller, _controller)) return;
    switch (controller.state) {
      case Live2DPreviewState.loading:
        _show(_Status.loading);
      case Live2DPreviewState.ready:
        _show(_Status.ready);
      case Live2DPreviewState.failed:
        _showFailure(controller.failure);
      case Live2DPreviewState.idle:
      case Live2DPreviewState.disposed:
        break;
    }
  }

  void _showFailure(Live2DPreviewException? failure) {
    final host = _host;
    final cause = failure?.cause;
    if (host == null || host.isGone) {
      _show(_Status.failed, reason: '预览渲染器已停止。');
    } else if (failure != null && failure.timedOut) {
      _show(_Status.failed, reason: '模型加载超时。');
    } else if (cause is Live2DHostException) {
      _show(
        _Status.failed,
        reason: cause.code == 'page_error' ? '预览页面加载失败。' : '预览通道出错。',
        detail: _text(cause.message),
      );
    } else {
      _show(
        _Status.failed,
        reason: '模型无法显示。',
        detail: _text(failure?.message),
      );
    }
  }

  /// A page that loaded cannot be trusted again: the controller disposes the
  /// viewer on a first-frame timeout (the viewer's dispose is terminal), and
  /// a lost WebGL context or renderer does not come back in the same page.
  /// So retry uses a new native view, unless only serving failed.
  void _retry() {
    final host = _host;
    final controller = _controller;
    if (host != null &&
        controller != null &&
        !host.isGone &&
        _baseUrl == null) {
      unawaited(_serveAndLoad(host, controller));
    } else {
      setState(_replaceView);
    }
  }

  void _show(_Status status, {String? reason, String? detail}) {
    if (!mounted) return;
    if (status == _status && reason == _reason && detail == _detail) return;
    setState(() {
      _status = status;
      _reason = reason;
      _detail = detail;
    });
  }

  static String? _text(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  @override
  Widget build(BuildContext context) {
    final generation = _generation;
    return Semantics(
      container: true,
      label: 'Live2D 模型预览',
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          AndroidView(
            key: ValueKey<int>(generation),
            viewType: Live2DPreviewView.viewType,
            onPlatformViewCreated: (viewId) =>
                _onPlatformViewCreated(generation, viewId),
          ),
          if (_status == _Status.loading)
            const _LoadingCover(key: Key('live2d-preview-loading')),
          if (_status == _Status.failed)
            _FailedCover(
              key: const Key('live2d-preview-failed'),
              reason: _reason ?? '模型无法显示。',
              detail: _detail,
              onRetry: _retry,
            ),
        ],
      ),
    );
  }
}

class _LoadingCover extends StatelessWidget {
  const _LoadingCover({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox.square(
              dimension: 32,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 12),
            Text(
              '正在加载模型…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FailedCover extends StatelessWidget {
  const _FailedCover({
    super.key,
    required this.reason,
    required this.detail,
    required this.onRetry,
  });

  final String reason;
  final String? detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = this.detail;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, size: 32, color: scheme.error),
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  reason,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (detail != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const Key('live2d-preview-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
