import 'package:material_ui/material_ui.dart';

import '../ui/jy_motion.dart';
import '../ui/jy_palette.dart';
import '../ui/jy_tokens.dart';

/// What a [StatusPanel] explains. The tone picks the colours of the icon
/// badge and whether assistive technology announces the panel when it
/// appears.
enum StatusTone {
  /// Nothing to show yet. A normal, calm state.
  empty,

  /// The content lives on the host, which cannot be reached right now.
  offline,

  /// Reading or saving failed. Announced as a live region.
  error,
}

/// A quiet explanation of why a surface is empty, offline or failed, with at
/// most one way forward (MASTER.md section 6).
///
/// A soft icon badge sits above the title and the detail. The badge is
/// decorative and hidden from screen readers; the text carries the message.
/// The panel fades in and rises [JySpace.sm] over [fadeDuration], so a state
/// that resolves a moment later does not flash; with reduced motion it
/// appears at once.
class StatusPanel extends StatelessWidget {
  const StatusPanel({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.tone = StatusTone.empty,
    this.action,
    this.fill = false,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final StatusTone tone;
  final Widget? action;

  /// Centers the panel in all of the available space and lets it scroll when
  /// large text would not fit. Use it when the panel replaces a whole list or
  /// pane; leave it off inside a list.
  final bool fill;

  /// How long the entrance takes.
  static const Duration fadeDuration = JyDurations.standard;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final JyPalette palette = JyPalette.of(context);
    final bool reduced = JyMotion.reducedOf(context);
    final Widget panel = Semantics(
      container: true,
      liveRegion: tone == StatusTone.error,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(JySpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _ToneBadge(icon: icon, tone: tone, palette: palette),
              const SizedBox(height: JySpace.lg),
              Text(
                title,
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(color: palette.text1),
              ),
              if (detail case final String line) ...<Widget>[
                const SizedBox(height: JySpace.xs),
                Text(
                  line,
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: palette.text2),
                ),
              ],
              if (action case final Widget button) ...<Widget>[
                const SizedBox(height: JySpace.xl),
                button,
              ],
            ],
          ),
        ),
      ),
    );
    // With reduced motion the panel appears at once. Otherwise only opacity
    // and a translation animate, over a repaint boundary; the panel is in the
    // semantics tree from the first frame, so an error is announced at once
    // rather than after the fade.
    final Widget entering = reduced
        ? panel
        : TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: fadeDuration,
            curve: JyCurves.enter,
            builder: (BuildContext context, double t, Widget? child) => Opacity(
              opacity: t,
              alwaysIncludeSemantics: true,
              child: Transform.translate(
                offset: Offset(0, JySpace.sm * (1 - t)),
                child: child,
              ),
            ),
            child: RepaintBoundary(child: panel),
          );
    if (!fill) {
      return Center(child: entering);
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          SingleChildScrollView(
            primary: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.hasBoundedHeight
                    ? constraints.maxHeight
                    : 0,
              ),
              child: Center(child: entering),
            ),
          ),
    );
  }
}

/// The icon on a soft superellipse: `raised` with a hairline edge when empty
/// or offline, `dangerSoft` for an error.
class _ToneBadge extends StatelessWidget {
  const _ToneBadge({
    required this.icon,
    required this.tone,
    required this.palette,
  });

  final IconData icon;
  final StatusTone tone;
  final JyPalette palette;

  static const double _size = 56;
  static const double _iconSize = 28;

  @override
  Widget build(BuildContext context) {
    final (Color fill, Color ink, BorderSide edge) = switch (tone) {
      StatusTone.empty => (
        palette.raised,
        palette.text2,
        BorderSide(color: palette.hairline),
      ),
      StatusTone.offline => (
        palette.raised,
        palette.warning,
        BorderSide(color: palette.hairline),
      ),
      StatusTone.error => (palette.dangerSoft, palette.danger, BorderSide.none),
    };
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: fill,
          shape: JyShapes.rounded(JyRadius.lg, side: edge),
        ),
        child: SizedBox.square(
          dimension: _size,
          child: Center(
            child: Icon(icon, size: _iconSize, color: ink),
          ),
        ),
      ),
    );
  }
}
