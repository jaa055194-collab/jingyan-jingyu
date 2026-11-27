import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/status_panel.dart';
import '../../net/host_connection.dart';
import 'street3d_protocol.dart';
import 'street3d_source.dart';

/// Why the view that hosts the 3D page stopped working.
enum Street3DSurfaceFailureKind {
  /// The page could not be loaded.
  loadFailed,

  /// The WebView's renderer process went away.
  crashed,

  /// The WebView is too old for the page's message bridge.
  unsupported,
}

class Street3DSurfaceFailure {
  const Street3DSurfaceFailure(this.kind, [this.detail]);

  final Street3DSurfaceFailureKind kind;
  final String? detail;
}

/// The view the 3D street page runs in: an Android WebView
/// (street3d_android_surface.dart), or a fake in tests. Messages are the JSON
/// envelopes of PROTOCOL.md in packages/jingyu_street3d_web.
abstract interface class Street3DSurface {
  /// Envelopes the page posted, in order.
  Stream<String> get messages;

  Stream<Street3DSurfaceFailure> get failures;

  /// Sends one envelope; the surface holds it until the page has said hello.
  Future<void> send(String json);

  Future<void> pause();

  Future<void> resume();

  void dispose();
}

/// Builds the view for the page and reports its surface once it exists.
typedef Street3DSurfaceBuilder = Widget Function(
  BuildContext context,
  ValueChanged<Street3DSurface> onCreated,
);

/// The independent 3D street page (FR-12, M10): the signed-in account's villa,
/// its AIs' and its friends' villas on one street, with residents moving as
/// the host reports. Positions are read twice a second while the page is
/// visible and interpolated by the page.
class Street3DScreen extends StatefulWidget {
  const Street3DScreen({
    super.key,
    required this.source,
    required this.surfaceBuilder,
    this.presenceInterval = const Duration(milliseconds: 500),
  });

  /// Null when there is no host connection.
  final Street3DDataSource? source;

  /// Null on platforms that have no 3D host view yet (Windows).
  final Street3DSurfaceBuilder? surfaceBuilder;

  final Duration presenceInterval;

  @override
  State<Street3DScreen> createState() => _Street3DScreenState();
}

class _Problem {
  const _Problem(
    this.icon,
    this.title,
    this.detail, {
    this.tone = StatusTone.error,
    this.canRetry = true,
  });

  final IconData icon;
  final String title;
  final String detail;
  final StatusTone tone;
  final bool canRetry;

  static const unsupported = _Problem(
    Icons.desktop_windows_outlined,
    '这个平台还不能显示 3D 街区',
    '目前只有 Android 端接入了 3D 街区；Windows 端的 WebView2 宿主还没有接入。',
    tone: StatusTone.empty,
    canRetry: false,
  );
  static const offline = _Problem(
    Icons.cloud_off_outlined,
    '没有连接宿主',
    '街区里的别墅和居民位置都来自宿主；连接宿主后再打开。',
    tone: StatusTone.offline,
    canRetry: false,
  );
  static const unreachable = _Problem(
    Icons.cloud_off_outlined,
    '暂时连不上宿主',
    '读不到街区里的别墅。',
    tone: StatusTone.offline,
  );
  static const denied = _Problem(
    Icons.lock_outline,
    '无权读取街区',
    '登录状态可能已失效，请重新登录后再打开。',
    canRetry: false,
  );
  static const loadFailed = _Problem(
    Icons.error_outline,
    '读取街区失败',
    '宿主返回的街区数据无法使用。',
  );
  static const pageFailed = _Problem(
    Icons.error_outline,
    '3D 页面没有加载出来',
    '应用内置的街区页面加载失败。',
  );
  static const crashed = _Problem(
    Icons.error_outline,
    '3D 画面意外停止',
    'WebView 的渲染进程退出了。',
  );
  static const webViewTooOld = _Problem(
    Icons.system_update_outlined,
    'WebView 版本过旧',
    '请在系统里更新 Android System WebView 后再打开。',
    canRetry: false,
  );
  static const noWebGl = _Problem(
    Icons.error_outline,
    '这台设备不能显示 3D 画面',
    'WebView 无法创建 WebGL 画布。',
    canRetry: false,
  );
  static const mismatch = _Problem(
    Icons.system_update_outlined,
    '3D 页面和应用版本不一致',
    '请把应用更新到同一个版本。',
    canRetry: false,
  );
  static const pageError = _Problem(
    Icons.error_outline,
    '3D 街区出错了',
    '页面报告了无法继续的错误。',
  );

  static _Problem forLoadError(Object error) {
    if (error is! HostRequestException) return loadFailed;
    return switch (error.failure.code) {
      FailureCode.unauthenticated || FailureCode.forbidden => denied,
      FailureCode.unavailable => unreachable,
      _ => loadFailed,
    };
  }

  static _Problem forPageError(String code) => switch (code) {
    'webgl_unavailable' => noWebGl,
    'protocol_mismatch' => mismatch,
    _ => pageError,
  };
}

class _Street3DScreenState extends State<Street3DScreen>
    with WidgetsBindingObserver {
  /// Failed position reads in a row before the page says so.
  static const _quietFailures = 4;

  final _host = Street3DHostMessages();
  final _clock = Stopwatch()..start();
  Key _surfaceKey = UniqueKey();
  Street3DSurface? _surface;
  StreamSubscription<String>? _pageMessages;
  StreamSubscription<Street3DSurfaceFailure>? _surfaceFailures;
  Street3DStreet? _street;
  _Problem? _problem;
  Timer? _timer;
  String? _theme;
  int _loads = 0;
  int _lastT = 0;
  int _failedPolls = 0;
  bool _acked = false;
  bool _laidOut = false;
  bool _ready = false;
  bool _paused = false;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.surfaceBuilder == null) {
      _problem = _Problem.unsupported;
    } else if (widget.source == null) {
      _problem = _Problem.offline;
    } else {
      _load();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = _themeOf(context);
    if (_acked && theme != _theme) {
      _theme = theme;
      _send(_host.theme(theme));
    }
  }

  // A brief inactive spell (a system dialog, the app switcher) keeps the street
  // running; hidden and paused stop it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resume();
    } else if (state != AppLifecycleState.inactive) {
      _pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    _detach();
    super.dispose();
  }

  String _themeOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? 'dark' : 'light';

  Future<void> _load() async {
    final load = ++_loads;
    try {
      final street = await widget.source!.loadStreet();
      if (!mounted || load != _loads) return;
      setState(() => _street = street);
      _sendLayout();
    } catch (error) {
      if (!mounted || load != _loads) return;
      _fail(_Problem.forLoadError(error));
    }
  }

  void _attach(Street3DSurface surface) {
    if (!mounted || _problem != null) {
      surface.dispose();
      return;
    }
    _detach();
    _surface = surface;
    _pageMessages = surface.messages.listen(_onPageMessage);
    _surfaceFailures = surface.failures.listen(_onSurfaceFailure);
    if (_paused) unawaited(surface.pause());
  }

  void _detach() {
    _pageMessages?.cancel();
    _surfaceFailures?.cancel();
    _pageMessages = null;
    _surfaceFailures = null;
    _surface?.dispose();
    _surface = null;
  }

  void _send(String json) {
    final surface = _surface;
    if (surface != null) unawaited(surface.send(json));
  }

  void _onPageMessage(String raw) {
    if (!mounted) return;
    switch (Street3DPageMessage.parse(raw)) {
      case final Street3DHello hello:
        if (!hello.compatible) {
          _fail(_Problem.mismatch);
          return;
        }
        // A reloaded page says hello again and is sent everything again.
        final theme = _themeOf(context);
        _theme = theme;
        _acked = true;
        _laidOut = false;
        _send(_host.helloAck(theme: theme));
        if (_paused) _send(_host.pause());
        _sendLayout();
        if (_ready) setState(() => _ready = false);
      case Street3DReady():
        if (!_ready) setState(() => _ready = true);
      case final Street3DTap tap:
        // The page flies to a tapped villa itself; a tapped resident is followed.
        if (tap.kind == 'resident') _send(_host.focusResident(tap.id));
      case final Street3DPageError error:
        if (error.fatal) _fail(_Problem.forPageError(error.code));
      default:
        break;
    }
  }

  void _onSurfaceFailure(Street3DSurfaceFailure failure) {
    if (!mounted) return;
    _fail(switch (failure.kind) {
      Street3DSurfaceFailureKind.loadFailed => _Problem.pageFailed,
      Street3DSurfaceFailureKind.crashed => _Problem.crashed,
      Street3DSurfaceFailureKind.unsupported => _Problem.webViewTooOld,
    });
  }

  void _sendLayout() {
    final street = _street;
    if (!_acked || _laidOut || street == null) return;
    _laidOut = true;
    _send(_host.layout(street.spaces));
    _startPolling();
  }

  void _startPolling() {
    _stopPolling();
    final street = _street;
    if (_paused || !_laidOut || _problem != null) return;
    if (street == null || street.spaces.isEmpty) return;
    unawaited(_poll());
    _timer = Timer.periodic(widget.presenceInterval, (_) => unawaited(_poll()));
  }

  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    final street = _street;
    final source = widget.source;
    if (_polling || _paused || street == null || source == null) return;
    if (street.spaces.isEmpty) return;
    _polling = true;
    try {
      final records = await source.presence(street.spaceIds);
      if (!mounted || _paused || _surface == null) return;
      _send(
        _host.presence(_nextT(), [
          for (final record in records) street.resident(record),
        ]),
      );
      if (_failedPolls >= _quietFailures) {
        setState(() => _failedPolls = 0);
      } else {
        _failedPolls = 0;
      }
    } catch (_) {
      if (!mounted) return;
      _failedPolls += 1;
      if (_failedPolls == _quietFailures) setState(() {});
    } finally {
      _polling = false;
    }
  }

  /// Presence times must increase strictly within one page session.
  int _nextT() {
    final now = _clock.elapsedMilliseconds;
    _lastT = now > _lastT ? now : _lastT + 1;
    return _lastT;
  }

  void _pause() {
    if (_paused) return;
    _paused = true;
    _stopPolling();
    if (_acked) _send(_host.pause());
    final surface = _surface;
    if (surface != null) unawaited(surface.pause());
  }

  void _resume() {
    if (!_paused) return;
    _paused = false;
    final surface = _surface;
    if (surface != null) unawaited(surface.resume());
    if (_acked) _send(_host.resume());
    _startPolling();
  }

  void _fail(_Problem problem) {
    _stopPolling();
    _detach();
    setState(() {
      _problem = problem;
      _acked = false;
      _laidOut = false;
      _ready = false;
    });
  }

  void _retry() {
    setState(() {
      _problem = null;
      _failedPolls = 0;
      _surfaceKey = UniqueKey();
    });
    if (_street == null) _load();
  }

  String? _bannerText() {
    if (_failedPolls >= _quietFailures) return '暂时读不到居民的位置，正在重试。';
    final street = _street;
    if (street == null) return null;
    if (street.spaces.isEmpty) {
      return '街区里还没有别墅：自己、自己的 AI 或好友保存房间布局后，别墅会出现在这条街上。';
    }
    final notes = [
      if (street.failedSpaces > 0) '有 ${street.failedSpaces} 栋别墅暂时读取失败，没有显示。',
      if (street.friendsFailed) '好友列表暂时读取失败，好友的别墅没有显示。',
    ];
    return notes.isEmpty ? null : notes.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    final builder = widget.surfaceBuilder;
    final Widget body;
    if (problem != null || builder == null) {
      final shown = problem ?? _Problem.unsupported;
      body = StatusPanel(
        key: const Key('street3d-problem'),
        icon: shown.icon,
        title: shown.title,
        detail: shown.detail,
        tone: shown.tone,
        fill: true,
        action: shown.canRetry
            ? FilledButton(
                key: const Key('street3d-retry'),
                onPressed: _retry,
                child: const Text('重试'),
              )
            : null,
      );
    } else {
      final banner = _bannerText();
      body = Stack(
        children: [
          Positioned.fill(
            child: KeyedSubtree(
              key: _surfaceKey,
              child: builder(context, _attach),
            ),
          ),
          if (!_ready)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(key: Key('street3d-loading')),
            ),
          if (banner != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: SafeArea(child: _Banner(banner)),
            ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('3D 街区')),
      body: body,
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const Key('street3d-banner'),
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(12),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(text, style: theme.textTheme.bodyMedium),
      ),
    );
  }
}
