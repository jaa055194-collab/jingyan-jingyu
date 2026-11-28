import 'package:material_ui/material_ui.dart';

import 'jy_palette.dart';

/// Spacing scale from MASTER.md section 6.
abstract final class JySpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double x3 = 32;
  static const double x4 = 40;
  static const double x5 = 48;

  /// Horizontal page padding on narrow layouts.
  static const double pageNarrow = 16;

  /// Horizontal page padding on wide layouts.
  static const double pageWide = 24;

  /// Inner padding of a slab.
  static const double slab = 16;

  /// Minimum height of a list row.
  static const double rowMinHeight = 64;

  /// Minimum size of a touch target.
  static const double touchTarget = 48;
}

/// Corner radii from MASTER.md section 6.
abstract final class JyRadius {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;
}

/// Shared shapes.
///
/// Every rounded corner is a continuous-curvature superellipse. If a
/// platform renders it badly, fall back to [RoundedRectangleBorder] in
/// [roundedBy] and [clip] only; nothing else builds corner shapes.
abstract final class JyShapes {
  /// A shape with the same [radius] on every corner.
  static OutlinedBorder rounded(
    double radius, {
    BorderSide side = BorderSide.none,
  }) => roundedBy(BorderRadius.all(Radius.circular(radius)), side: side);

  /// A shape with per-corner radii.
  static OutlinedBorder roundedBy(
    BorderRadiusGeometry radius, {
    BorderSide side = BorderSide.none,
  }) => RoundedSuperellipseBorder(borderRadius: radius, side: side);

  /// Slabs and cards.
  static OutlinedBorder get slab => rounded(JyRadius.lg);

  /// Buttons and text fields.
  static OutlinedBorder get button => rounded(JyRadius.md);

  /// Dialogs.
  static OutlinedBorder get dialog => rounded(JyRadius.xl);

  /// Bottom sheets: only the two top corners are rounded.
  static OutlinedBorder get sheet =>
      roundedBy(const BorderRadius.vertical(top: Radius.circular(JyRadius.xl)));

  /// Pills: chips, badges, the dock.
  static OutlinedBorder get pill => const StadiumBorder();

  /// A chat bubble. Corners next to a neighbouring bubble from the same
  /// sender use [JyRadius.xs]; [mine] bubbles sit on the end side.
  static OutlinedBorder bubble({
    required bool mine,
    bool joinedAbove = false,
    bool joinedBelow = false,
  }) {
    const Radius big = Radius.circular(JyRadius.lg);
    const Radius small = Radius.circular(JyRadius.xs);
    return roundedBy(
      BorderRadiusDirectional.only(
        topStart: !mine && joinedAbove ? small : big,
        topEnd: mine && joinedAbove ? small : big,
        bottomStart: !mine && joinedBelow ? small : big,
        bottomEnd: mine && joinedBelow ? small : big,
      ),
    );
  }

  /// Clips [child] to the same curve as [rounded].
  static Widget clip({required double radius, required Widget child}) {
    return ClipRSuperellipse(
      borderRadius: BorderRadius.all(Radius.circular(radius)),
      child: child,
    );
  }
}

/// Soft shadow for floating things only: the dock, sheets, dialogs, the
/// floating composer and an expanded stack card (MASTER.md section 6).
abstract final class JyShadows {
  static List<BoxShadow> floating(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final JyPalette palette = JyPalette.of(context);
    return <BoxShadow>[
      BoxShadow(
        color: palette.shadow,
        offset: Offset(0, dark ? 12 : 8),
        blurRadius: dark ? 32 : 24,
      ),
    ];
  }
}
