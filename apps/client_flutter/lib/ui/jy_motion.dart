import 'package:material_ui/material_ui.dart';

/// Motion durations from MASTER.md section 7.
abstract final class JyDurations {
  /// Press feedback.
  static const Duration press = Duration(milliseconds: 90);

  /// Small fades, colour and selection changes.
  static const Duration quick = Duration(milliseconds: 160);

  /// Expanding and collapsing, elements entering or leaving, tab changes.
  static const Duration standard = Duration(milliseconds: 240);

  /// Page transitions, bottom sheets, dialogs.
  static const Duration emphasized = Duration(milliseconds: 360);

  /// The presence orb lighting up, one sonar wave, onboarding.
  static const Duration gentle = Duration(milliseconds: 520);

  /// Delay between items of a staggered entrance or an expanding stack.
  static const Duration stagger = Duration(milliseconds: 30);

  /// Longest fade that is kept when motion is reduced.
  static const Duration reduced = Duration(milliseconds: 120);

  /// Exit duration for something that entered over [enter]: about 0.7x.
  static Duration exit(Duration enter) =>
      Duration(microseconds: (enter.inMicroseconds * 0.7).round());
}

/// Motion curves from MASTER.md section 7.
abstract final class JyCurves {
  /// Elements entering.
  static const Curve enter = Curves.easeOutCubic;

  /// Elements leaving, for an animation that runs forwards in time, such
  /// as `controller.animateTo(0, curve: JyCurves.exit)`.
  static const Curve exit = Curves.easeInCubic;

  /// [exit] for `CurvedAnimation.reverseCurve`, which is applied to a parent
  /// value running from 1 back to 0.
  static const Curve exitReverse = Curves.easeOutCubic;

  /// Emphasised motion: page transitions, sheets, dialogs.
  static const Curve emphasized = Cubic(0.2, 0, 0, 1);

  /// Settling spring: overshoots a little and stops quickly.
  static const SpringDescription spring = SpringDescription(
    mass: 1,
    stiffness: 520,
    damping: 34,
  );
}

/// Reduced-motion policy (MASTER.md section 7).
///
/// When motion is reduced, movement, scaling, springs and sonar waves are
/// turned off; only fades of at most [JyDurations.reduced] remain, and loops
/// become static indicators that still have a text description.
abstract final class JyMotion {
  /// Whether motion is reduced, by the system setting or by the in-app
  /// switch passed down through [JyMotionScope].
  static bool reducedOf(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return true;
    }
    return JyMotionScope.maybeReduceOf(context) ?? false;
  }

  /// [duration], capped at [JyDurations.reduced] when motion is reduced.
  /// Use it for fades only.
  static Duration of(BuildContext context, Duration duration) {
    if (duration <= JyDurations.reduced || !reducedOf(context)) {
      return duration;
    }
    return JyDurations.reduced;
  }
}

/// Passes the in-app reduced-motion preference down the tree.
///
/// Put it above the Navigator, for example in `MaterialApp.builder`, so
/// that routes, dialogs and sheets see it too.
class JyMotionScope extends InheritedWidget {
  const JyMotionScope({super.key, required this.reduce, required super.child});

  /// Whether the user turned on reduced motion in settings.
  final bool reduce;

  /// The nearest scope's preference, or null when there is none.
  static bool? maybeReduceOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<JyMotionScope>()?.reduce;

  @override
  bool updateShouldNotify(JyMotionScope oldWidget) =>
      reduce != oldWidget.reduce;
}

/// Page transition for every platform: the new page fades in, moves in
/// 24px from the end side and grows from 0.98 to 1; going back reverses it
/// faster. With reduced motion it is a fade of at most 120ms.
class JyPageTransitionsBuilder extends PageTransitionsBuilder {
  const JyPageTransitionsBuilder();

  @override
  Duration get transitionDuration => JyDurations.emphasized;

  @override
  Duration get reverseTransitionDuration =>
      JyDurations.exit(JyDurations.emphasized);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _JyPageTransition(animation: animation, child: child);
  }
}

class _JyPageTransition extends StatefulWidget {
  const _JyPageTransition({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  State<_JyPageTransition> createState() => _JyPageTransitionState();
}

class _JyPageTransitionState extends State<_JyPageTransition> {
  late CurvedAnimation _move;
  late CurvedAnimation _fade;
  late CurvedAnimation _reducedFade;

  @override
  void initState() {
    super.initState();
    _createCurves();
  }

  @override
  void didUpdateWidget(_JyPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _disposeCurves();
      _createCurves();
    }
  }

  @override
  void dispose() {
    _disposeCurves();
    super.dispose();
  }

  void _createCurves() {
    _move = CurvedAnimation(
      parent: widget.animation,
      curve: JyCurves.emphasized,
      reverseCurve: JyCurves.exitReverse,
    );
    _fade = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0, 0.6, curve: Curves.easeOutCubic),
    );
    // 120ms of the 360ms transition.
    _reducedFade = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0, 1 / 3),
    );
  }

  void _disposeCurves() {
    _move.dispose();
    _fade.dispose();
    _reducedFade.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool reduced = JyMotion.reducedOf(context);
    final double direction = Directionality.of(context) == TextDirection.rtl
        ? -1
        : 1;
    // The tree shape stays the same when the preference changes, so the
    // page keeps its state.
    return FadeTransition(
      opacity: reduced ? _reducedFade : _fade,
      child: AnimatedBuilder(
        animation: _move,
        child: widget.child,
        builder: (BuildContext context, Widget? child) {
          final double t = reduced ? 1 : _move.value;
          return Transform.translate(
            offset: Offset(direction * 24 * (1 - t), 0),
            child: Transform.scale(scale: 0.98 + 0.02 * t, child: child),
          );
        },
      ),
    );
  }
}
