import 'dart:async';

import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:material_ui/material_ui.dart';

import 'jy_motion.dart';
import 'jy_palette.dart';

/// Touch feedback from MASTER.md section 7, item 1.
///
/// While pressed the child shrinks to [pressedScale] over
/// [JyDurations.press] and a signal highlight at 8% opacity is laid over it;
/// on release it springs back with [JyCurves.spring]. Only transforms are
/// used, so the layout size never changes. A long press gives one light
/// haptic tick where the platform supports it.
///
/// With [onTap] or [onLongPress] the child is a button: it is focusable,
/// Enter and Space activate it, a focus ring follows keyboard focus and it
/// has the button role. With both null it only shows the pressed feedback
/// and never takes taps from the widgets inside it.
///
/// With reduced motion there is no scaling; the highlight still fades.
class JyPressable extends StatefulWidget {
  const JyPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.97,
    this.borderRadius,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 0.97 for rows and cards, 0.92 for icon buttons.
  final double pressedScale;

  /// Corners of the highlight and the focus ring; square when null.
  final BorderRadius? borderRadius;

  /// When false there is no feedback and the callbacks are not called.
  final bool enabled;

  @override
  State<JyPressable> createState() => _JyPressableState();
}

class _JyPressableState extends State<JyPressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  bool _pressed = false;
  bool _focused = false;
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = JyMotion.reducedOf(context);
  }

  bool get _visualOnly => widget.onTap == null && widget.onLongPress == null;

  @override
  void didUpdateWidget(JyPressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _pressed) {
      _setPressed(false);
    }
  }

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (_pressed == pressed || !mounted) {
      return;
    }
    setState(() => _pressed = pressed);
    if (_reduced) {
      _scale.value = 1;
      return;
    }
    if (pressed) {
      _scale.animateTo(
        widget.pressedScale,
        duration: JyDurations.press,
        curve: JyCurves.enter,
      );
    } else {
      _scale.animateWith(SpringSimulation(JyCurves.spring, _scale.value, 1, 0));
    }
  }

  void _handleLongPress() {
    unawaited(Feedback.forLongPress(context));
    widget.onLongPress?.call();
  }

  Object? _activate() {
    (widget.onTap ?? widget.onLongPress)?.call();
    return null;
  }

  void _handleFocusHighlight(bool value) {
    if (mounted && _focused != value) {
      setState(() => _focused = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final BorderRadius radius = widget.borderRadius ?? BorderRadius.zero;
    Widget content = Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _pressed ? 1 : 0,
              duration: JyMotion.of(context, JyDurations.press),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.signal.withValues(alpha: 0.08),
                  borderRadius: radius,
                ),
              ),
            ),
          ),
        ),
        if (_focused)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: palette.signal, width: 2),
                  borderRadius: radius,
                ),
              ),
            ),
          ),
      ],
    );
    content = RepaintBoundary(
      child: AnimatedBuilder(
        animation: _scale,
        child: content,
        builder: (BuildContext context, Widget? child) =>
            Transform.scale(scale: _scale.value, child: child),
      ),
    );

    if (_visualOnly) {
      if (!widget.enabled) {
        return content;
      }
      return Listener(
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: content,
      );
    }
    if (!widget.enabled) {
      return Semantics(
        container: true,
        button: true,
        enabled: false,
        child: content,
      );
    }
    final VoidCallback? onLongPress = widget.onLongPress == null
        ? null
        : _handleLongPress;
    return FocusableActionDetector(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) => _activate(),
        ),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
          onInvoke: (_) => _activate(),
        ),
      },
      onShowFocusHighlight: _handleFocusHighlight,
      mouseCursor: SystemMouseCursors.click,
      child: Semantics(
        container: true,
        button: true,
        enabled: true,
        onTap: widget.onTap,
        onLongPress: onLongPress,
        child: GestureDetector(
          excludeFromSemantics: true,
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          onTap: widget.onTap,
          onLongPress: onLongPress,
          child: content,
        ),
      ),
    );
  }
}

/// Expanding and collapsing, from MASTER.md section 7, item 2.
///
/// The height opens over [JyDurations.standard] while the content fades in
/// and rises 8px; collapsing uses the exit curve and is faster. A collapsed
/// [child] leaves the tree unless [maintainState] is true, in which case it
/// stays offstage and keeps its state. With reduced motion only a short fade
/// remains.
class JyExpand extends StatelessWidget {
  const JyExpand({
    super.key,
    required this.expanded,
    required this.child,
    this.maintainState = false,
  });

  final bool expanded;
  final Widget child;

  /// Keep the collapsed child in the tree, offstage.
  final bool maintainState;

  @override
  Widget build(BuildContext context) {
    return _JyExpandBody(
      expanded: expanded,
      maintainState: maintainState,
      reduced: JyMotion.reducedOf(context),
      child: child,
    );
  }
}

class _JyExpandBody extends StatefulWidget {
  const _JyExpandBody({
    required this.expanded,
    required this.maintainState,
    required this.reduced,
    required this.child,
  });

  final bool expanded;
  final bool maintainState;
  final bool reduced;
  final Widget child;

  @override
  State<_JyExpandBody> createState() => _JyExpandBodyState();
}

class _JyExpandBodyState extends State<_JyExpandBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.expanded ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    _configure();
  }

  @override
  void didUpdateWidget(_JyExpandBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    _configure();
    if (oldWidget.expanded != widget.expanded) {
      if (widget.expanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  void _configure() {
    _controller
      ..duration = widget.reduced ? JyDurations.reduced : JyDurations.standard
      ..reverseDuration = widget.reduced
          ? JyDurations.reduced
          : JyDurations.exit(JyDurations.standard);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The tree keeps the same shape in every state, so a child kept by
    // maintainState never loses its state.
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final double raw = _controller.value;
        final double t = _controller.status == AnimationStatus.reverse
            ? JyCurves.exitReverse.transform(raw)
            : JyCurves.enter.transform(raw);
        return Visibility(
          visible: !_controller.isDismissed,
          maintainState: widget.maintainState,
          child: IgnorePointer(
            ignoring: !widget.expanded,
            child: ClipRect(
              child: Align(
                alignment: AlignmentDirectional.topCenter,
                heightFactor: widget.reduced ? 1 : t,
                child: Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, widget.reduced ? 0 : 8 * (1 - t)),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The chevron that goes with [JyExpand]: it turns 180° when [expanded].
/// It is decorative; the toggle it sits in carries the expanded state.
class JyChevron extends StatelessWidget {
  const JyChevron({super.key, required this.expanded});

  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final bool reduced = JyMotion.reducedOf(context);
    return ExcludeSemantics(
      child: AnimatedRotation(
        turns: expanded ? 0.5 : 0,
        duration: reduced ? Duration.zero : JyDurations.standard,
        curve: JyCurves.enter,
        child: Icon(Icons.expand_more, color: JyPalette.of(context).text2),
      ),
    );
  }
}

/// Staggered entrance for the first items of a list (MASTER.md section 7,
/// item 4): items 0 to 7 fade in and rise 8px, 30ms apart, the first time
/// they are built on a route. Later items, rebuilt items and reduced motion
/// show the child at once.
class JyEntrance extends StatefulWidget {
  const JyEntrance({super.key, required this.index, required this.child});

  /// Position of the item in its list.
  final int index;
  final Widget child;

  /// Only this many leading items animate.
  static const int animatedCount = 8;

  @override
  State<JyEntrance> createState() => _JyEntranceState();
}

class _JyEntranceState extends State<JyEntrance>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  bool _decided = false;

  String get _storageId => 'jy-entrance-${widget.index}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) {
      return;
    }
    _decided = true;
    final PageStorageBucket? bucket = PageStorage.maybeOf(context);
    final bool played =
        bucket?.readState(context, identifier: _storageId) == true;
    bucket?.writeState(context, true, identifier: _storageId);
    if (played ||
        widget.index < 0 ||
        widget.index >= JyEntrance.animatedCount ||
        JyMotion.reducedOf(context)) {
      return;
    }
    _controller = AnimationController(
      vsync: this,
      duration: JyDurations.standard + JyDurations.stagger * widget.index,
    )..forward();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? controller = _controller;
    if (controller == null) {
      return widget.child;
    }
    final double start =
        (JyDurations.stagger * widget.index).inMicroseconds /
        controller.duration!.inMicroseconds;
    final Interval interval = Interval(start, 1, curve: JyCurves.enter);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: controller,
        child: widget.child,
        builder: (BuildContext context, Widget? child) {
          final double t = interval.transform(controller.value);
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - t)),
              child: child,
            ),
          );
        },
      ),
    );
  }
}

/// How [JySwitcher] brings in new content.
enum JySwitcherStyle {
  /// Fade in over 210ms while growing from 0.98 to 1 (dock tab changes).
  fadeThrough,

  /// The page transition: fade in, move in 24px from the end side and grow
  /// from 0.98 to 1 (list to chat, home to settings on narrow layouts).
  sharedAxisX,
}

/// Switches between children with different keys (MASTER.md section 7,
/// item 5). When the [child]'s key changes, the old subtree is removed in
/// the same frame and only the new one animates in. [reverse] makes
/// [JySwitcherStyle.sharedAxisX] come in from the start side instead, for
/// going back. With reduced motion it is a fade of at most 120ms.
class JySwitcher extends StatelessWidget {
  const JySwitcher({
    super.key,
    required this.child,
    this.style = JySwitcherStyle.fadeThrough,
    this.reverse = false,
  });

  /// Give it a [Key]; a new key starts the transition.
  final Widget child;
  final JySwitcherStyle style;
  final bool reverse;

  @override
  Widget build(BuildContext context) {
    return _JySwitcherBody(
      style: style,
      reverse: reverse,
      reduced: JyMotion.reducedOf(context),
      child: child,
    );
  }
}

class _JySwitcherBody extends StatefulWidget {
  const _JySwitcherBody({
    required this.style,
    required this.reverse,
    required this.reduced,
    required this.child,
  });

  final JySwitcherStyle style;
  final bool reverse;
  final bool reduced;
  final Widget child;

  @override
  State<_JySwitcherBody> createState() => _JySwitcherBodyState();
}

class _JySwitcherBodyState extends State<_JySwitcherBody>
    with SingleTickerProviderStateMixin {
  /// The fade-in half of fade-through, from MASTER.md section 7.
  static const Duration _fadeThroughIn = Duration(milliseconds: 210);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: 1,
  );

  @override
  void didUpdateWidget(_JySwitcherBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!Widget.canUpdate(oldWidget.child, widget.child)) {
      _controller.duration = widget.reduced
          ? JyDurations.reduced
          : switch (widget.style) {
              JySwitcherStyle.fadeThrough => _fadeThroughIn,
              JySwitcherStyle.sharedAxisX => JyDurations.emphasized,
            };
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double direction =
        (Directionality.of(context) == TextDirection.rtl ? -1 : 1) *
        (widget.reverse ? -1 : 1);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (BuildContext context, Widget? child) {
          final double raw = _controller.value;
          double opacity = raw;
          double move = 1;
          double grow = 1;
          if (!widget.reduced) {
            switch (widget.style) {
              case JySwitcherStyle.fadeThrough:
                opacity = JyCurves.enter.transform(raw);
                grow = opacity;
              case JySwitcherStyle.sharedAxisX:
                opacity = const Interval(
                  0,
                  0.6,
                  curve: Curves.easeOutCubic,
                ).transform(raw);
                move = JyCurves.emphasized.transform(raw);
                grow = move;
            }
          }
          return Opacity(
            opacity: opacity,
            child: Transform.translate(
              offset: Offset(direction * 24 * (1 - move), 0),
              child: Transform.scale(scale: 0.98 + 0.02 * grow, child: child),
            ),
          );
        },
      ),
    );
  }
}
