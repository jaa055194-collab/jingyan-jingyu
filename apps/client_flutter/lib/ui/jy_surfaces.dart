import 'package:material_ui/material_ui.dart';

import 'jy_palette.dart';
import 'jy_tokens.dart';
import 'jy_typography.dart';

/// The surface colour of a [JySlab].
enum JyTone {
  /// The main slab.
  slab,

  /// A secondary surface on a slab: inputs, the other side's bubbles.
  raised,

  /// Dialogs, sheets, the dock and the floating composer.
  overlay,
}

/// A flat surface in a tone colour, with a continuous-curvature outline and a
/// 1px highlight along the top edge.
///
/// Slabs are told apart by tone and hairlines, not elevation. Only a
/// [floating] slab casts the one soft shadow.
class JySlab extends StatelessWidget {
  /// Creates a slab around [child].
  const JySlab({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(JySpace.slab),
    this.tone = JyTone.slab,
    this.radius = JyRadius.lg,
    this.floating = false,
    this.onTap,
  });

  /// The content.
  final Widget child;

  /// The space between the outline and [child].
  final EdgeInsetsGeometry padding;

  /// The surface colour.
  final JyTone tone;

  /// The corner radius.
  final double radius;

  /// Whether the slab floats above the page and casts a shadow.
  final bool floating;

  /// Called when the slab is tapped. Null makes the slab inert.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final OutlinedBorder shape = JyShapes.rounded(radius);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    Widget content = Padding(padding: padding, child: child);
    if (onTap != null) {
      content = InkWell(onTap: onTap, customBorder: shape, child: content);
    }
    // The white highlight shows on every dark tone. In the light theme only
    // raised is dark enough to carry it.
    if (dark || tone == JyTone.raised) {
      content = CustomPaint(
        foregroundPainter: _TopEdgePainter(palette.edgeHighlight),
        child: content,
      );
    }
    final Widget slab = Material(
      color: switch (tone) {
        JyTone.slab => palette.slab,
        JyTone.raised => palette.raised,
        JyTone.overlay => palette.overlay,
      },
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: content,
    );
    if (!floating) {
      return slab;
    }
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: JyShadows.floating(context),
      ),
      child: slab,
    );
  }
}

/// Draws the 1px highlight along the top edge. The slab's clip rounds its
/// ends into the corners.
class _TopEdgePainter extends CustomPainter {
  const _TopEdgePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      const Offset(0, 0.5),
      Offset(size.width, 0.5),
      Paint()
        ..color = color
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_TopEdgePainter oldDelegate) => oldDelegate.color != color;
}

/// Rows on one slab with a hairline between them, an optional [header] above
/// and an optional [footer] below.
class JyGroup extends StatelessWidget {
  /// Creates a group of [children].
  const JyGroup({super.key, this.header, this.footer, required this.children});

  /// The section title above the slab.
  final String? header;

  /// A note below the slab.
  final String? footer;

  /// The rows.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final String? header = this.header;
    final String? footer = this.footer;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (header != null) JySectionHeader(title: header),
        JySlab(
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < children.length; i++) ...<Widget>[
                if (i > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: JySpace.lg,
                    color: palette.hairline,
                  ),
                children[i],
              ],
            ],
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              JySpace.lg,
              JySpace.sm,
              JySpace.lg,
              0,
            ),
            child: Text(
              footer,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: palette.text3),
            ),
          ),
      ],
    );
  }
}

/// A section title, read as a heading, with an optional [trailing] widget at
/// the end of the row.
class JySectionHeader extends StatelessWidget {
  /// Creates a header titled [title].
  const JySectionHeader({super.key, required this.title, this.trailing});

  /// The title.
  final String title;

  /// A widget at the end of the row, for example a text button.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final Widget? trailing = this.trailing;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        JySpace.lg,
        JySpace.lg,
        JySpace.lg,
        JySpace.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              container: true,
              header: true,
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(color: palette.text2),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A tinted tile behind a row's leading icon.
///
/// It is decorative and hidden from semantics: the row's text says what the
/// row is.
class JyIconTile extends StatelessWidget {
  /// Creates a tile for [icon].
  const JyIconTile({super.key, required this.icon, this.color});

  /// The side length of the tile.
  static const double size = 36;

  /// The icon.
  final IconData icon;

  /// The colour of the icon and, faintly, of the tile. Defaults to signal.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color tint = color ?? JyPalette.of(context).signal;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: tint.withValues(alpha: 0.14),
            shape: JyShapes.rounded(JyRadius.sm),
          ),
          child: Icon(icon, size: 20, color: tint),
        ),
      ),
    );
  }
}

/// An unread count in a pill. It shows nothing at zero and "99+" above 99.
class JyBadge extends StatelessWidget {
  /// Creates a badge for [count].
  const JyBadge({super.key, required this.count});

  /// The unread count.
  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) {
      return const SizedBox.shrink();
    }
    final JyPalette palette = JyPalette.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: palette.signalSoft,
        shape: JyShapes.pill,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: JySpace.xl,
          minHeight: JySpace.xl,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: JySpace.sm),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              count > 99 ? '99+' : '$count',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: palette.onSignalSoft,
                fontFeatures: JyTypography.tabularFigures,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a [JyBanner] reports.
enum JyBannerKind {
  /// Something failed.
  error,

  /// Something to know.
  info,

  /// Something worked.
  success,
}

/// An inset strip with an icon, a message read as a live region and an
/// optional close button.
///
/// The banner does not animate itself: wrap it in `JyExpand` to show and hide
/// it.
class JyBanner extends StatelessWidget {
  /// Creates a banner for [message].
  const JyBanner({
    super.key,
    required this.message,
    this.kind = JyBannerKind.error,
    this.onClose,
    this.closeTooltip = '关闭提示',
    this.messageKey,
  });

  /// The text of the banner.
  final String message;

  /// What the banner reports, which sets its colours and icon.
  final JyBannerKind kind;

  /// Called when the close button is tapped. Null hides the close button.
  final VoidCallback? onClose;

  /// The tooltip and semantic label of the close button.
  final String closeTooltip;

  /// A key for the message's [Text], so tests and callers can find it.
  final Key? messageKey;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final (
      Color background,
      Color foreground,
      Color tint,
      IconData icon,
    ) = switch (kind) {
      JyBannerKind.error => (
        palette.dangerSoft,
        palette.onDangerSoft,
        palette.onDangerSoft,
        Icons.error_outline,
      ),
      JyBannerKind.info => (
        palette.signalSoft,
        palette.onSignalSoft,
        palette.onSignalSoft,
        Icons.info_outline,
      ),
      JyBannerKind.success => (
        palette.raised,
        palette.text1,
        palette.success,
        Icons.check_circle_outline,
      ),
    };
    final bool closable = onClose != null;
    return Material(
      color: background,
      shape: JyShapes.rounded(JyRadius.md),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          JySpace.md,
          closable ? JySpace.xs : JySpace.md,
          closable ? JySpace.xs : JySpace.md,
          closable ? JySpace.xs : JySpace.md,
        ),
        child: Row(
          children: <Widget>[
            ExcludeSemantics(child: Icon(icon, size: 20, color: tint)),
            const SizedBox(width: JySpace.sm),
            Expanded(
              child: Semantics(
                container: true,
                liveRegion: true,
                child: Text(
                  message,
                  key: messageKey,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: foreground),
                ),
              ),
            ),
            if (closable)
              IconButton(
                tooltip: closeTooltip,
                onPressed: onClose,
                icon: Icon(Icons.close, color: foreground),
              ),
          ],
        ),
      ),
    );
  }
}
