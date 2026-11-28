// App-layer session for the chat-page Live2D avatar (increment D1).
//
// It reads the model this device has enabled from the kit's Live2DFileStore,
// then serves that model's directory to the existing native
// `jingyu/live2d_view` platform view and drives it with the existing
// Live2DPreviewController. It owns no rendering itself and never adds model
// bytes: files stay behind the local asset server.
import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/services.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';

import 'android_live2d_renderer_host.dart';

/// Where the chat-page avatar card is.
///
/// [hidden] means no card at all: the platform has no Live2D host, no model is
/// enabled, the enabled selection is stale, or the device store cannot be read.
enum Live2DAvatarStatus { hidden, loading, ready, failed }

/// The native surface behind one avatar card: the per-view channel that serves
/// the model directory, and the preview controller that loads it and reports
/// its lifecycle.
///
/// It is an interface so tests can drive a session without platform channels;
/// the product uses [AndroidLive2DAvatarRenderer].
abstract interface class Live2DAvatarRenderer {
  Future<String> serve(String directory);
  Live2DPreviewController get controller;
  bool get isGone;
  void dispose();
}

/// The Android `jingyu/live2d_view` surface: one [AndroidLive2DRendererHost]
/// (per-view method channel) wrapped by a [Live2DPreviewController].
final class AndroidLive2DAvatarRenderer implements Live2DAvatarRenderer {
  AndroidLive2DAvatarRenderer(
    int viewId, {
    Duration firstFrameTimeout = const Duration(seconds: 20),
  }) : _host = AndroidLive2DRendererHost(viewId) {
    _controller = Live2DPreviewController(
      host: _host,
      firstFrameTimeout: firstFrameTimeout,
    );
  }

  final AndroidLive2DRendererHost _host;
  late final Live2DPreviewController _controller;

  @override
  Live2DPreviewController get controller => _controller;

  @override
  bool get isGone => _host.isGone;

  @override
  Future<String> serve(String directory) => _host.serve(directory);

  @override
  void dispose() {
    unawaited(_controller.close());
    _host.dispose();
  }
}

/// Opens the device model store. Injected so tests use an in-memory store.
typedef Live2DStoreOpener = Future<Live2DFileStore> Function();

/// Resolves the active model, serves it and starts the viewer.
///
/// State machine: [Live2DAvatarStatus.hidden] until [refresh] finds an enabled
/// model, then [Live2DAvatarStatus.loading] once the model is mounted,
/// [Live2DAvatarStatus.ready] after the viewer's first frame, and
/// [Live2DAvatarStatus.failed] (with honest [errorText]) on a real failure.
///
/// The widget attaches a [Live2DAvatarRenderer] when its platform view is
/// created (see [attach]) and releases it when the view goes away (see
/// [releaseView]). Mounting again reloads the model; that is acceptable for D1.
final class Live2DAvatarSession extends ChangeNotifier {
  Live2DAvatarSession({required this.openStore, this.supported = true});

  /// Opens the device model store.
  final Live2DStoreOpener openStore;

  /// Whether this platform can host the viewer (Android only today).
  final bool supported;

  Live2DAvatarStatus _status = Live2DAvatarStatus.hidden;
  Live2DStoredModel? _model;
  Live2DProfile? _profile;
  String? _directory;
  String? _errorText;
  String? _errorDetail;

  Live2DAvatarRenderer? _renderer;
  Live2DSwitchCoordinator? _switcher;
  StreamSubscription<Live2DPreviewState>? _states;
  int _generation = 0;
  int _switchId = 0;
  bool _disposed = false;
  bool _active = true;

  Live2DAvatarStatus get status => _status;

  /// The enabled model's display name, or the empty string when hidden.
  String get displayName => _model?.displayName ?? '';

  /// The enabled model's ID, or the empty string when hidden.
  String get modelId => _model?.id ?? '';

  /// The model3 file relative to [directory].
  String get model3File => _model?.model3 ?? '';

  /// The profile revision to echo back to the viewer, at least 1.
  int get profileRev => _profile?.profileRev ?? 1;

  /// Absolute model directory to serve, or null when there is nothing to show.
  String? get directory => _directory;

  /// A short Chinese reason shown on the failure cover, or null.
  String? get errorText => _errorText;

  /// Optional technical detail under [errorText] when the cause is known.
  String? get errorDetail => _errorDetail;

  /// Bumped whenever the widget must mount a fresh platform view (on retry).
  int get generation => _generation;

  /// Whether the card is on screen. When false the viewer's frame loop is
  /// paused but its model stays loaded, so returning does not reload it.
  bool get active => _active;

  /// Pauses or resumes the frame loop. Pausing does not release the model.
  void setActive(bool active) {
    if (_disposed || _active == active) return;
    _active = active;
    final Live2DAvatarRenderer? renderer = _renderer;
    if (renderer == null) return;
    if (active) {
      unawaited(renderer.controller.resume().catchError((Object _) {}));
    } else {
      unawaited(renderer.controller.pause().catchError((Object _) {}));
    }
  }

  /// Re-reads the enabled model after the World page changed it.
  ///
  /// With a mounted view the new model is served and loaded behind the hidden
  /// card, so returning to chat does not wait for a reload and no blank frame
  /// is shown. The same model is a no-op; no enabled model hides the card.
  Future<void> onActiveModelChanged() async {
    if (_disposed || !supported) return;
    final Live2DFileStore store;
    try {
      store = await openStore();
    } catch (_) {
      return;
    }
    if (_disposed) return;
    final String? id = store.activeModelId;
    if (id == null) {
      _hide();
      return;
    }
    final Live2DStoredModel? model = store.model(id);
    if (model == null) {
      _hide();
      return;
    }
    if (id == _model?.id && _status != Live2DAvatarStatus.hidden) return;
    final String directory;
    try {
      directory = store.modelDirectory(id);
    } catch (_) {
      _fail('形象文件无法读取。');
      return;
    }
    _model = model;
    _profile = store.profile(id);
    _directory = directory;
    _errorText = null;
    _errorDetail = null;
    final Live2DAvatarRenderer? renderer = _renderer;
    if (renderer == null) {
      // Collapsed card: resolve the model; expanding mounts and loads it.
      _status = Live2DAvatarStatus.loading;
      _notify();
      return;
    }
    if (_active && _status == Live2DAvatarStatus.ready && _switcher != null) {
      // Visible switch: stage the new model behind the old one and cross-fade.
      // The old model stays until the incoming first frame succeeds.
      await _switchTo(renderer, directory);
      return;
    }
    _status = Live2DAvatarStatus.loading;
    _notify();
    await _serveAndLoad(renderer, directory);
  }

  /// Reads the enabled model from the device store.
  ///
  /// Stays hidden when this platform cannot host the viewer, when no model is
  /// enabled, when the enabled ID no longer exists, or when the store cannot be
  /// read at all (so a broken store does not put an error bar on every chat).
  /// A model whose directory cannot be resolved fails honestly.
  Future<void> refresh() async {
    if (_disposed) return;
    if (!supported) {
      _hide();
      return;
    }
    final Live2DFileStore store;
    try {
      store = await openStore();
    } catch (_) {
      _hide();
      return;
    }
    if (_disposed) return;
    final String? id = store.activeModelId;
    if (id == null) {
      _hide();
      return;
    }
    final Live2DStoredModel? model = store.model(id);
    if (model == null) {
      // The active selection points at a model that is no longer kept.
      _hide();
      return;
    }
    final String directory;
    try {
      directory = store.modelDirectory(id);
    } catch (_) {
      _fail('形象文件无法读取。');
      return;
    }
    _model = model;
    _profile = store.profile(id);
    _directory = directory;
    _errorText = null;
    _errorDetail = null;
    _status = Live2DAvatarStatus.loading;
    _notify();
  }

  /// Serves [directory] and starts the viewer on [renderer].
  ///
  /// Called once per mounted platform view. Releases any renderer already held.
  void attach(Live2DAvatarRenderer renderer) {
    if (_disposed) {
      renderer.dispose();
      return;
    }
    final String? directory = _directory;
    if (_status == Live2DAvatarStatus.hidden || directory == null) {
      renderer.dispose();
      return;
    }
    _releaseRenderer();
    _renderer = renderer;
    _switcher = Live2DSwitchCoordinator(host: renderer.controller.host);
    _states = renderer.controller.states.listen(_onControllerState);
    _errorText = null;
    _errorDetail = null;
    _status = Live2DAvatarStatus.loading;
    _notify();
    unawaited(_serveAndLoad(renderer, directory));
  }

  /// Drops the current renderer without changing the resolved model, so the
  /// header can stay while the card is collapsed. The widget mounts a new view
  /// (and calls [attach] again) when it expands.
  void releaseView() {
    _releaseRenderer();
  }

  /// Re-reads the store and forces a fresh platform view. Used by the failure
  /// cover so both store changes and a dead viewer recover.
  Future<void> retry() async {
    if (_disposed) return;
    _releaseRenderer();
    _generation++;
    _notify();
    await refresh();
  }

  Future<void> _serveAndLoad(
    Live2DAvatarRenderer renderer,
    String directory,
  ) async {
    final String served;
    try {
      served = await renderer.serve(directory);
    } on MissingPluginException {
      if (identical(renderer, _renderer)) _fail('此设备暂不支持形象显示。');
      return;
    } on PlatformException catch (error) {
      if (identical(renderer, _renderer)) {
        _fail('无法读取本机形象文件。', detail: _cleanText(error.message) ?? error.code);
      }
      return;
    } on Object catch (error) {
      if (identical(renderer, _renderer)) {
        _fail('无法读取本机形象文件。', detail: _cleanText('$error'));
      }
      return;
    }
    if (_disposed || !identical(renderer, _renderer)) return;
    final Live2DStoredModel? model = _model;
    if (model == null) return;
    final String baseUrl = served.endsWith('/') ? served : '$served/';
    final String model3Url = '$baseUrl${Uri(path: model.model3).path}';
    unawaited(
      renderer.controller
          .start(
            modelId: model.id,
            model3Url: model3Url,
            textureUrls: const <String>[],
            profileRev: profileRev,
          )
          // Failures are reported through controller.states; the future also
          // completes with an error, so ignore it here.
          .catchError((Object _) {}),
    );
  }

  Future<void> _switchTo(
    Live2DAvatarRenderer renderer,
    String directory,
  ) async {
    final Live2DStoredModel? model = _model;
    final Live2DSwitchCoordinator? switcher = _switcher;
    if (model == null || switcher == null) return;
    String served;
    try {
      served = await renderer.serve(directory);
    } on Object catch (error) {
      if (identical(renderer, _renderer)) {
        _fail('无法读取本机形象文件。', detail: _cleanText('$error'));
      }
      return;
    }
    if (_disposed || !identical(renderer, _renderer)) return;
    final String baseUrl = served.endsWith('/') ? served : '$served/';
    final String model3Url = '$baseUrl${Uri(path: model.model3).path}';
    final String loadId = 'switch-${++_switchId}';
    try {
      await switcher.preload(
        loadId: loadId,
        modelId: model.id,
        model3Url: model3Url,
        textureUrls: const <String>[],
        profileRev: profileRev,
      );
      await switcher.swap(loadId: loadId);
      if (_disposed || !identical(renderer, _renderer)) return;
      _status = Live2DAvatarStatus.ready;
      _notify();
    } on Object catch (error) {
      if (_disposed || !identical(renderer, _renderer)) return;
      // The viewer kept the old model on a rejected/failed swap. Fall back to
      // a normal reload so the selected model still becomes visible.
      _status = Live2DAvatarStatus.loading;
      _notify();
      await _serveAndLoad(renderer, directory);
      _errorDetail = _cleanText('$error');
      _notify();
    }
  }

  void _onControllerState(Live2DPreviewState state) {
    if (_disposed || _renderer == null) return;
    switch (state) {
      case Live2DPreviewState.loading:
        _status = Live2DAvatarStatus.loading;
        _notify();
      case Live2DPreviewState.ready:
        _errorText = null;
        _errorDetail = null;
        _status = Live2DAvatarStatus.ready;
        _notify();
        if (!_active && _renderer != null) {
          unawaited(_renderer!.controller.pause().catchError((Object _) {}));
        }
      case Live2DPreviewState.failed:
        _failFromController(_renderer!.controller.failure);
      case Live2DPreviewState.idle:
      case Live2DPreviewState.disposed:
        break;
    }
  }

  void _failFromController(Live2DPreviewException? failure) {
    final Live2DAvatarRenderer? renderer = _renderer;
    if (renderer == null || renderer.isGone) {
      _fail('形象渲染器已停止。');
      return;
    }
    if (failure != null && failure.timedOut) {
      _fail('形象加载超时。');
      return;
    }
    final Object? cause = failure?.cause;
    if (cause is Live2DHostException) {
      _fail(
        cause.code == 'page_error' ? '形象页面加载失败。' : '形象通道出错。',
        detail: _cleanText(cause.message),
      );
      return;
    }
    _fail('形象无法显示。', detail: _cleanText(failure?.message));
  }

  void _hide() {
    if (_disposed) return;
    _releaseRenderer();
    _model = null;
    _profile = null;
    _directory = null;
    _errorText = null;
    _errorDetail = null;
    _status = Live2DAvatarStatus.hidden;
    _notify();
  }

  void _fail(String text, {String? detail}) {
    if (_disposed) return;
    _errorText = text;
    _errorDetail = detail;
    _status = Live2DAvatarStatus.failed;
    _notify();
  }

  void _releaseRenderer() {
    final StreamSubscription<Live2DPreviewState>? states = _states;
    final Live2DSwitchCoordinator? switcher = _switcher;
    final Live2DAvatarRenderer? renderer = _renderer;
    _states = null;
    _switcher = null;
    _renderer = null;
    if (states != null) unawaited(states.cancel());
    if (switcher != null) unawaited(switcher.close());
    renderer?.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Trims a platform detail so it can sit under [errorText], or null.
  static String? _cleanText(String? value) {
    final String? text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  @override
  void dispose() {
    _disposed = true;
    _releaseRenderer();
    super.dispose();
  }
}
