// Chat-page Live2D avatar card (increment D1): a collapsible Material card
// that hosts the native `jingyu/live2d_view` platform view, with a handle at
// the bottom edge to drag its height.
//
// Patterns consulted, no code copied (sources in tmp/d1/notes.md):
// - header + chevron toggling a card body: Flutter SDK ExpansionTile
//   (flutter/flutter, BSD-3-Clause) and skylled/expansion_tile_card (MIT);
// - drag delta clamped to [min, max]: Flutter SDK DraggableScrollableSheet
//   (flutter/flutter, BSD-3-Clause).
//
// The platform view is never animated or composited with Flutter Opacity or
// Transform. Collapsing unmounts it (the native view is disposed); expanding
// mounts a new one, which reloads the model.
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'android_live2d_renderer_host.dart';
import 'live2d_avatar_session.dart';

/// Collapsed state and height of the avatar card.
///
/// Kept in memory for the app run only: the app has no simple per-device
/// preference store for UI layout, so a restart returns to the defaults.
final class Live2DAvatarLayout {
  Live2DAvatarLayout();

  /// Shared by every chat pane in this app run, so switching chats keeps it.
  static final Live2DAvatarLayout appRun = Live2DAvatarLayout();

  bool collapsed = false;

  /// The height the user dragged to, or null for the default.
  double? height;
}

/// Shows this device's enabled Live2D model above the chat messages.
///
/// Shows nothing when [supported] is false or no model is enabled. On a
/// failure it says what went wrong and offers retry.
class Live2DAvatarCard extends StatefulWidget {
  const Live2DAvatarCard({
    super.key,
    required this.openStore,
    required this.supported,
    this.active = true,
    this.revision = 0,
    this.layout,
    this.maxHeight,
    this.firstFrameTimeout = const Duration(seconds: 20),
  });

  static const double minHeight = 120;
  static const double defaultHeight = 220;

  final Live2DStoreOpener openStore;

  /// Whether this platform hosts the Live2D view (Android only today).
  final bool supported;

  /// Whether the card is on screen. When false the session pauses its frame
  /// loop but keeps the model loaded, so returning to chat does not reload.
  final bool active;

  /// Bumped after the World page enables another model; the session re-reads
  /// the active model and loads it behind the hidden card.
  final int revision;

  /// Defaults to [Live2DAvatarLayout.appRun].
  final Live2DAvatarLayout? layout;

  /// Upper bound for the dragged height; defaults to half the window height.
  final double? maxHeight;
  final Duration firstFrameTimeout;

  @override
  State<Live2DAvatarCard> createState() => _Live2DAvatarCardState();
}

class _Live2DAvatarCardState extends State<Live2DAvatarCard> {
  late final Live2DAvatarSession _session = Live2DAvatarSession(
    openStore: widget.openStore,
    supported: widget.supported,
  );

  Live2DAvatarLayout get _layout => widget.layout ?? Live2DAvatarLayout.appRun;

  @override
  void initState() {
    super.initState();
    _session.addListener(_changed);
    _session.setActive(widget.active);
    _session.refresh();
  }

  @override
  void didUpdateWidget(Live2DAvatarCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _session.setActive(widget.active);
    }
    if (oldWidget.revision != widget.revision) {
      unawaited(_session.onActiveModelChanged());
    }
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _session.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  double _maxHeight(BuildContext context) {
    final max = widget.maxHeight ?? MediaQuery.sizeOf(context).height / 2;
    return max < Live2DAvatarCard.minHeight ? Live2DAvatarCard.minHeight : max;
  }

  double _height(BuildContext context) => (_layout.height ??
          Live2DAvatarCard.defaultHeight)
      .clamp(Live2DAvatarCard.minHeight, _maxHeight(context))
      .toDouble();

  void _resize(BuildContext context, double delta) {
    setState(() => _layout.height = (_height(context) + delta)
        .clamp(Live2DAvatarCard.minHeight, _maxHeight(context))
        .toDouble());
  }

  void _toggle() {
    final collapse = !_layout.collapsed;
    // Collapsing removes the platform view; drop its renderer now.
    if (collapse) _session.releaseView();
    setState(() => _layout.collapsed = collapse);
  }

  void _onPlatformViewCreated(int generation, int viewId) {
    if (!mounted || generation != _session.generation) return;
    _session.attach(
      AndroidLive2DAvatarRenderer(
        viewId,
        firstFrameTimeout: widget.firstFrameTimeout,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _session.status;
    if (status == Live2DAvatarStatus.hidden) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final collapsed = _layout.collapsed;
    final name = _session.displayName;
    return Card(
      key: const Key('live2d-avatar-card'),
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            dense: true,
            leading: const Icon(Icons.face_outlined),
            title: Text(
              name.isEmpty ? '形象' : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            trailing: IconButton(
              key: const Key('live2d-avatar-toggle'),
              tooltip: collapsed ? '展开形象' : '收起形象',
              icon: Icon(collapsed ? Icons.expand_more : Icons.expand_less),
              onPressed: _toggle,
            ),
          ),
          if (!collapsed) ...<Widget>[
            SizedBox(
              key: const Key('live2d-avatar-body'),
              height: _height(context),
              child: _body(status),
            ),
            _ResizeHandle(
              key: const Key('live2d-avatar-resize'),
              onDrag: (delta) => _resize(context, delta),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body(Live2DAvatarStatus status) {
    final generation = _session.generation;
    final directory = _session.directory;
    return Semantics(
      container: true,
      label: 'Live2D 形象',
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (directory != null)
            AndroidView(
              key: ValueKey<int>(generation),
              viewType: AndroidLive2DRendererHost.viewType,
              onPlatformViewCreated: (viewId) =>
                  _onPlatformViewCreated(generation, viewId),
            ),
          if (status == Live2DAvatarStatus.loading)
            const _LoadingCover(key: Key('live2d-avatar-loading')),
          if (status == Live2DAvatarStatus.failed)
            _FailedCover(
              key: const Key('live2d-avatar-failed'),
              reason: _session.errorText ?? '形象无法显示。',
              detail: _session.errorDetail,
              onRetry: _session.retry,
            ),
        ],
      ),
    );
  }
}

/// A grip at the card's bottom edge; dragging it changes the body height.
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({super.key, required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '拖动调整形象高度',
      onIncrease: () => onDrag(24),
      onDecrease: () => onDrag(-24),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
        child: SizedBox(
          height: 20,
          child: Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
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
              '正在加载形象…',
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
                key: const Key('live2d-avatar-retry'),
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
