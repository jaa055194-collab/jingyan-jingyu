import 'package:material_ui/material_ui.dart';

/// The single accent. Identity, links, current state and primary actions all
/// derive from it; nothing else in the app introduces a competing hue.
const appAccentSeed = Color(0xff16776e);

/// Accent roles come from [appAccentSeed]; the surfaces are warm neutrals so
/// structure reads as quiet paper and ink rather than a tinted screen.
ColorScheme appColorScheme(Brightness brightness) {
  final accent = ColorScheme.fromSeed(
    seedColor: appAccentSeed,
    brightness: brightness,
  );
  return switch (brightness) {
    Brightness.light => accent.copyWith(
      surface: const Color(0xfffaf8f5),
      onSurface: const Color(0xff1d1b18),
      surfaceDim: const Color(0xffddd9d4),
      surfaceBright: const Color(0xfffaf8f5),
      surfaceContainerLowest: const Color(0xffffffff),
      surfaceContainerLow: const Color(0xfff4f1ed),
      surfaceContainer: const Color(0xffeeebe6),
      surfaceContainerHigh: const Color(0xffe9e5e0),
      surfaceContainerHighest: const Color(0xffe3dfda),
      onSurfaceVariant: const Color(0xff4c4640),
      outline: const Color(0xff7e776f),
      outlineVariant: const Color(0xffcfc8c0),
      inverseSurface: const Color(0xff32302c),
      onInverseSurface: const Color(0xfff5f0ea),
    ),
    Brightness.dark => accent.copyWith(
      surface: const Color(0xff161513),
      onSurface: const Color(0xffe9e3dd),
      surfaceDim: const Color(0xff161513),
      surfaceBright: const Color(0xff3c3a37),
      surfaceContainerLowest: const Color(0xff110f0e),
      surfaceContainerLow: const Color(0xff1e1c1a),
      surfaceContainer: const Color(0xff23211f),
      surfaceContainerHigh: const Color(0xff2d2b29),
      surfaceContainerHighest: const Color(0xff383633),
      onSurfaceVariant: const Color(0xffcec7bf),
      outline: const Color(0xff979088),
      outlineVariant: const Color(0xff4b4742),
      inverseSurface: const Color(0xffe9e3dd),
      onInverseSurface: const Color(0xff32302c),
    ),
  };
}

/// Layers are separated by tone and hairlines instead of shadows, corners stay
/// small, and touch feedback is a plain ripple. Only colors and shapes are
/// themed here: sizes, spacing and type metrics keep the framework defaults.
ThemeData buildAppTheme(Brightness brightness) {
  final scheme = appColorScheme(brightness);
  final hairline = BorderSide(color: scheme.outlineVariant);
  const corners = BorderRadius.all(Radius.circular(8));
  const buttonShape = WidgetStatePropertyAll<OutlinedBorder>(
    RoundedRectangleBorder(borderRadius: corners),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    splashFactory: InkRipple.splashFactory,
    appBarTheme: AppBarThemeData(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: Border(bottom: hairline),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: corners, side: hairline),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    filledButtonTheme: const FilledButtonThemeData(
      style: ButtonStyle(shape: buttonShape),
    ),
    outlinedButtonTheme: const OutlinedButtonThemeData(
      style: ButtonStyle(shape: buttonShape),
    ),
    textButtonTheme: const TextButtonThemeData(
      style: ButtonStyle(shape: buttonShape),
    ),
  );
}
