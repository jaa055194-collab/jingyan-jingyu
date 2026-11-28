import 'package:material_ui/material_ui.dart';

import '../ui/jy_motion.dart';
import '../ui/jy_palette.dart';
import '../ui/jy_tokens.dart';
import '../ui/jy_typography.dart';

/// 品牌强调色：浅色调色板的 signal（MASTER.md 第 4 节）。
///
/// 主题不再从种子色推导，[buildAppTheme] 直接用 [JyPalette.dark] 或
/// [JyPalette.light]；这个常量只留给需要一个与亮度无关的强调色的地方。
const Color appAccentSeed = Color(0xFF0B6BD3);

/// 第 4 节的 ColorScheme 映射，见 [JyPalette.toColorScheme]。
ColorScheme appColorScheme(Brightness brightness) =>
    JyPalette.fallback(brightness).toColorScheme(brightness);

/// 镜语主题（MASTER.md 第 4–7 节）。
///
/// 层次靠色阶和发丝线，组件一律不用 elevation 阴影；悬浮物的柔和阴影由
/// lib/ui 的组件自己画。这里只覆盖规范定了的颜色、形状、文字和最小尺寸，
/// 其余沿用 Material 默认，免得无关页面的布局跟着变。
///
/// ColorScheme 的 secondary 系是伙伴色 ember。Material 默认拿
/// secondaryContainer 当选中底或未激活轨道的地方（导航栏、侧栏和抽屉的
/// 指示器，Chip，分段按钮，滑块，线性进度条，日期范围）在这里一律改成
/// signalSoft，上面的图标、文字、刻度和按压层改成 onSignalSoft。
/// FilledButton.tonal 和 IconButton.filledTonal 的底色在主题层改不了
/// （按钮主题分不出变体），要在调用处换掉。
ThemeData buildAppTheme(Brightness brightness) {
  final JyPalette p = JyPalette.fallback(brightness);
  final ColorScheme scheme = appColorScheme(brightness);
  final TextTheme text = JyTypography.textTheme(p.text1);
  final BorderSide hairline = BorderSide(color: p.hairline);
  final BorderSide outline = BorderSide(color: p.outline);

  bool isSelected(Set<WidgetState> states) =>
      states.contains(WidgetState.selected);
  bool isDisabled(Set<WidgetState> states) =>
      states.contains(WidgetState.disabled);

  // 三种按钮共用：JyShapes.button，最小高 48（触控目标）。
  final ButtonStyle button = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll<Size>(
      Size(64, kMinInteractiveDimension),
    ),
    shape: WidgetStatePropertyAll<OutlinedBorder>(JyShapes.button),
  );

  // 分段按钮：选中段 signalSoft 底；未选中段保持主文字色；禁用走默认。
  final WidgetStateProperty<Color?> segmentForeground =
      WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
        if (isDisabled(states)) {
          return null;
        }
        return isSelected(states) ? p.onSignalSoft : p.text1;
      });

  // 分段按钮的按压层跟着段上的文字走：选中段 onSignalSoft，其余 onSurface。
  final WidgetStateProperty<Color?> segmentOverlay =
      WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
        final Color layer = isSelected(states)
            ? p.onSignalSoft
            : scheme.onSurface;
        if (states.contains(WidgetState.pressed) ||
            states.contains(WidgetState.focused)) {
          return layer.withValues(alpha: 0.1);
        }
        if (states.contains(WidgetState.hovered)) {
          return layer.withValues(alpha: 0.08);
        }
        return null;
      });

  // 导航栏和抽屉共用：选中 onSignalSoft，未选中 text2；禁用走默认。
  final WidgetStateProperty<IconThemeData?> navIcon =
      WidgetStateProperty.resolveWith<IconThemeData?>((
        Set<WidgetState> states,
      ) {
        if (isDisabled(states)) {
          return null;
        }
        return IconThemeData(
          size: 24,
          color: isSelected(states) ? p.onSignalSoft : p.text2,
        );
      });

  OutlineInputBorder inputBorder(BorderSide side) => OutlineInputBorder(
    borderRadius: const BorderRadius.all(Radius.circular(JyRadius.md)),
    borderSide: side,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: text,
    scaffoldBackgroundColor: p.canvas,
    dividerColor: p.hairline,
    splashFactory: InkRipple.splashFactory,
    extensions: <ThemeExtension<dynamic>>[p],
    pageTransitionsTheme: PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        for (final TargetPlatform platform in TargetPlatform.values)
          platform: const JyPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarThemeData(
      backgroundColor: p.canvas,
      foregroundColor: p.text1,
      elevation: 0,
      scrolledUnderElevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: p.slab,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: JyShapes.rounded(JyRadius.lg, side: hairline),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.overlay,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: JyShapes.dialog,
      barrierColor: p.scrim,
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium?.copyWith(color: p.text2),
    ),
    datePickerTheme: DatePickerThemeData(
      rangeSelectionBackgroundColor: p.signalSoft,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.overlay,
      modalBackgroundColor: p.overlay,
      elevation: 0,
      modalElevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: JyShapes.sheet,
      clipBehavior: Clip.antiAlias,
      showDragHandle: true,
      dragHandleColor: p.outline,
      modalBarrierColor: p.scrim,
    ),
    listTileTheme: ListTileThemeData(
      selectedColor: p.onSignalSoft,
      selectedTileColor: p.signalSoft,
      contentPadding: const EdgeInsets.symmetric(horizontal: JySpace.lg),
      shape: JyShapes.rounded(JyRadius.md),
    ),
    filledButtonTheme: FilledButtonThemeData(style: button),
    outlinedButtonTheme: OutlinedButtonThemeData(style: button),
    textButtonTheme: TextButtonThemeData(style: button),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: button.copyWith(
        elevation: const WidgetStatePropertyAll<double>(0),
        shadowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        backgroundColor: WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) => isDisabled(states) ? null : p.raised,
        ),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) =>
              isSelected(states) && !isDisabled(states) ? p.signalSoft : null,
        ),
        foregroundColor: segmentForeground,
        iconColor: segmentForeground,
        overlayColor: segmentOverlay,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      disabledElevation: 0,
      shape: JyShapes.rounded(JyRadius.lg),
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll<double>(0),
      backgroundColor: WidgetStatePropertyAll<Color>(p.raised),
      shadowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      side: WidgetStatePropertyAll<BorderSide>(outline),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: p.raised,
      hintStyle: TextStyle(color: p.text3),
      border: inputBorder(outline),
      enabledBorder: inputBorder(outline),
      focusedBorder: inputBorder(BorderSide(color: p.signal, width: 2)),
      errorBorder: inputBorder(BorderSide(color: p.danger)),
      focusedErrorBorder: inputBorder(BorderSide(color: p.danger, width: 2)),
      disabledBorder: inputBorder(hairline),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        if (isDisabled(states)) {
          return null;
        }
        return isSelected(states) ? p.onSignal : p.outline;
      }),
      trackColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        if (isDisabled(states)) {
          return null;
        }
        return isSelected(states) ? p.signal : p.raised;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        if (isDisabled(states)) {
          return null;
        }
        return isSelected(states) ? Colors.transparent : p.outline;
      }),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.signal,
      inactiveTrackColor: p.signalSoft,
      inactiveTickMarkColor: p.onSignalSoft.withValues(alpha: 0.38),
      thumbColor: p.signal,
      overlayColor: p.signal.withValues(alpha: 0.12),
    ),
    chipTheme: ChipThemeData(
      selectedColor: p.signalSoft,
      checkmarkColor: p.onSignalSoft,
      labelStyle: text.labelLarge?.copyWith(
        color: WidgetStateColor.resolveWith((Set<WidgetState> states) {
          if (isDisabled(states)) {
            return p.text1.withValues(alpha: 0.38);
          }
          return isSelected(states) ? p.onSignalSoft : p.text2;
        }),
      ),
      side: WidgetStateBorderSide.resolveWith((Set<WidgetState> states) {
        if (isSelected(states)) {
          return BorderSide.none;
        }
        return isDisabled(states) ? hairline : outline;
      }),
      shape: JyShapes.pill,
    ),
    dividerTheme: DividerThemeData(color: p.hairline, thickness: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.signal,
      linearTrackColor: p.signalSoft,
      circularTrackColor: Colors.transparent,
      refreshBackgroundColor: p.overlay,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.overlay,
      contentTextStyle: text.bodyMedium,
      actionTextColor: p.signal,
      closeIconColor: p.text2,
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      shape: JyShapes.rounded(JyRadius.md, side: hairline),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.text1,
        borderRadius: const BorderRadius.all(Radius.circular(JyRadius.sm)),
      ),
      textStyle: text.bodySmall?.copyWith(color: p.canvas),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.overlay,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: JyShapes.rounded(JyRadius.md, side: hairline),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color>(p.overlay),
        elevation: const WidgetStatePropertyAll<double>(0),
        shadowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        surfaceTintColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          JyShapes.rounded(JyRadius.md, side: hairline),
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.slab,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.signalSoft,
      iconTheme: navIcon,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.canvas,
      elevation: 0,
      indicatorColor: p.signalSoft,
      selectedIconTheme: IconThemeData(size: 24, color: p.onSignalSoft),
      unselectedIconTheme: IconThemeData(size: 24, color: p.text2),
    ),
    navigationDrawerTheme: NavigationDrawerThemeData(
      elevation: 0,
      indicatorColor: p.signalSoft,
      iconTheme: navIcon,
      labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((
        Set<WidgetState> states,
      ) {
        if (isDisabled(states)) {
          return null;
        }
        return text.labelLarge?.copyWith(
          color: isSelected(states) ? p.onSignalSoft : p.text2,
        );
      }),
    ),
  );
}
