import 'package:material_ui/material_ui.dart';

import 'jy_motion.dart';
import 'jy_palette.dart';
import 'jy_tokens.dart';

/// Scale a dialog grows from as it opens (MASTER.md section 7, scale).
const double _kDialogStartScale = 0.94;

/// A dialog route on the 镜语 motion (MASTER.md section 7, scale).
///
/// Takes the same arguments as [DialogRoute]; a null [barrierColor] becomes
/// [JyPalette.scrim]. The content grows from 0.94 to 1 and fades in over
/// [JyDurations.emphasized] on [JyCurves.emphasized], and leaves over
/// `JyDurations.exit(JyDurations.emphasized)` (252ms) on the exit curve.
/// Whether motion is reduced is read from [context] when the route is
/// created; if it is, the content only fades, over [JyDurations.reduced]
/// each way.
///
/// The route adds no surface of its own: the overlay colour and the xl
/// corners come from the theme's `dialogTheme`, so [builder] still returns
/// an [AlertDialog] or a [Dialog]. Keep the route object to take a dialog
/// that has gone stale down in the same frame with
/// [NavigatorState.removeRoute].
class JyDialogRoute<T> extends DialogRoute<T> {
  JyDialogRoute({
    required super.context,
    required super.builder,
    super.themes,
    Color? barrierColor,
    super.barrierDismissible = true,
    super.barrierLabel,
    super.useSafeArea = true,
    super.settings,
    super.requestFocus,
    super.anchorPoint,
    super.traversalEdgeBehavior,
    super.fullscreenDialog = false,
  }) : _reduced = JyMotion.reducedOf(context),
       super(barrierColor: barrierColor ?? JyPalette.of(context).scrim);

  final bool _reduced;

  @override
  Duration get transitionDuration =>
      _reduced ? JyDurations.reduced : JyDurations.emphasized;

  @override
  Duration get reverseTransitionDuration =>
      _reduced ? JyDurations.reduced : JyDurations.exit(JyDurations.emphasized);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _JyDialogTransition(
      animation: animation,
      reduced: _reduced,
      child: child,
    );
  }
}

class _JyDialogTransition extends StatefulWidget {
  const _JyDialogTransition({
    required this.animation,
    required this.reduced,
    required this.child,
  });

  final Animation<double> animation;
  final bool reduced;
  final Widget child;

  @override
  State<_JyDialogTransition> createState() => _JyDialogTransitionState();
}

class _JyDialogTransitionState extends State<_JyDialogTransition> {
  late CurvedAnimation _curve;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _createCurves();
  }

  @override
  void didUpdateWidget(_JyDialogTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _curve.dispose();
      _createCurves();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    super.dispose();
  }

  void _createCurves() {
    _curve = CurvedAnimation(
      parent: widget.animation,
      curve: JyCurves.emphasized,
      reverseCurve: JyCurves.exitReverse,
    );
    _scale = Tween<double>(begin: _kDialogStartScale, end: 1).animate(_curve);
  }

  @override
  Widget build(BuildContext context) {
    // The tree has the same shape either way, so the dialog keeps its state.
    // Reduced motion: a linear fade over the 120ms route, no scaling.
    return FadeTransition(
      opacity: widget.reduced ? widget.animation : _curve,
      child: ScaleTransition(
        scale: widget.reduced ? kAlwaysCompleteAnimation : _scale,
        child: widget.child,
      ),
    );
  }
}

/// [showDialog] on a [JyDialogRoute], with the same parameters and defaults.
///
/// Like [showDialog] it captures the themes between [context] and the
/// navigator, so the builder sees the caller's theme. [animationStyle] is
/// accepted so that call sites can switch over unchanged, but it is not
/// used: the motion is the route's (MASTER.md section 7).
Future<T?> showJyDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool fullscreenDialog = false,
  bool? requestFocus,
  AnimationStyle? animationStyle,
}) {
  assert(debugCheckHasMaterialLocalizations(context));
  final NavigatorState navigator = Navigator.of(
    context,
    rootNavigator: useRootNavigator,
  );
  final CapturedThemes themes = InheritedTheme.capture(
    from: context,
    to: navigator.context,
  );
  return navigator.push<T>(
    JyDialogRoute<T>(
      context: context,
      builder: builder,
      themes: themes,
      barrierColor:
          barrierColor ??
          DialogTheme.of(context).barrierColor ??
          Theme.of(context).dialogTheme.barrierColor,
      barrierDismissible: barrierDismissible,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      settings: routeSettings,
      requestFocus: requestFocus,
      anchorPoint: anchorPoint,
      traversalEdgeBehavior:
          traversalEdgeBehavior ?? TraversalEdgeBehavior.closedLoop,
      fullscreenDialog: fullscreenDialog,
    ),
  );
}

/// [showModalBottomSheet] with the 镜语 defaults (MASTER.md section 9).
///
/// Every parameter keeps its name and default from [showModalBottomSheet],
/// which this calls directly, so the sheet is still a [BottomSheet]. A null
/// argument becomes:
///
/// * [backgroundColor]: [JyPalette.overlay].
/// * [shape]: [JyShapes.sheet], xl top corners.
/// * [showDragHandle]: true.
/// * [barrierColor]: [JyPalette.scrim].
/// * [sheetAnimationStyle]: in over [JyDurations.emphasized] on
///   [JyCurves.emphasized], out over `JyDurations.exit` of that on the exit
///   curve; [JyDurations.reduced] each way when motion is reduced.
Future<T?> showJySheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  String? barrierLabel,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  double scrollControlDisabledMaxHeightRatio = 9.0 / 16.0,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  RouteSettings? routeSettings,
  AnimationController? transitionAnimationController,
  Offset? anchorPoint,
  AnimationStyle? sheetAnimationStyle,
  bool? requestFocus,
}) {
  final JyPalette palette = JyPalette.of(context);
  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    backgroundColor: backgroundColor ?? palette.overlay,
    barrierLabel: barrierLabel,
    elevation: elevation,
    shape: shape ?? JyShapes.sheet,
    clipBehavior: clipBehavior,
    constraints: constraints,
    barrierColor: barrierColor ?? palette.scrim,
    isScrollControlled: isScrollControlled,
    scrollControlDisabledMaxHeightRatio: scrollControlDisabledMaxHeightRatio,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle ?? true,
    useSafeArea: useSafeArea,
    routeSettings: routeSettings,
    transitionAnimationController: transitionAnimationController,
    anchorPoint: anchorPoint,
    sheetAnimationStyle:
        sheetAnimationStyle ?? _sheetMotion(JyMotion.reducedOf(context)),
    requestFocus: requestFocus,
  );
}

AnimationStyle _sheetMotion(bool reduced) {
  if (reduced) {
    return const AnimationStyle(
      duration: JyDurations.reduced,
      reverseDuration: JyDurations.reduced,
    );
  }
  return AnimationStyle(
    curve: JyCurves.emphasized,
    duration: JyDurations.emphasized,
    reverseCurve: JyCurves.exitReverse,
    reverseDuration: JyDurations.exit(JyDurations.emphasized),
  );
}
