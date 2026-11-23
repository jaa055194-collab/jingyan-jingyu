import 'package:material_ui/material_ui.dart';

/// What a [StatusPanel] explains. The tone changes only the icon color and
/// whether assistive technology announces the panel when it appears.
enum StatusTone {
  /// Nothing to show yet. A normal, calm state.
  empty,

  /// The content lives on the host, which cannot be reached right now.
  offline,

  /// Reading or saving failed. Announced as a live region.
  error,
}

/// A quiet explanation of why a surface is empty, offline or failed, with at
/// most one way forward.
///
/// It fades in over [fadeDuration] so a state that resolves a moment later
/// does not flash, and appears at once when the platform disables animations.
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

  static const fadeDuration = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    Widget panel = Semantics(
      container: true,
      liveRegion: tone == StatusTone.error,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 32,
                color: tone == StatusTone.error
                    ? colors.error
                    : colors.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              if (detail case final text?) ...[
                const SizedBox(height: 4),
                Text(
                  text,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              if (action case final button?) ...[
                const SizedBox(height: 16),
                button,
              ],
            ],
          ),
        ),
      ),
    );
    if (!(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      panel = TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: fadeDuration,
        curve: Curves.easeOut,
        // Kept in the semantics tree from the first frame, so an error is
        // announced at once rather than after the fade.
        builder: (_, opacity, child) => Opacity(
          opacity: opacity,
          alwaysIncludeSemantics: true,
          child: child,
        ),
        child: panel,
      );
    }
    if (!fill) return Center(child: panel);
    return LayoutBuilder(
      builder: (_, constraints) => SingleChildScrollView(
        primary: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
          child: Center(child: panel),
        ),
      ),
    );
  }
}
