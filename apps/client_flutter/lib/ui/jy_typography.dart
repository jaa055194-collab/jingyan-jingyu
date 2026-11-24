import 'package:material_ui/material_ui.dart';

/// 镜语的文字层级（MASTER.md 第 5 节）。
///
/// 字号/行高、字重、字距按规范，颜色统一给主文字色；组件要次要色时自己覆盖。
/// 设置里的字体大小经 MediaQuery 的 textScaler 作用于全部文字，这里不另缩放。
abstract final class JyTypography {
  /// 正文的最小字号。
  static const double minBodySize = 12;

  /// 时间、计数、百分比用的等宽数字：
  /// `style.copyWith(fontFeatures: JyTypography.tabularFigures)`。
  static const List<FontFeature> tabularFigures = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// 第 5 节的 [TextTheme]，[color] 是主文字色；表里没有的样式沿用 Material 默认。
  static TextTheme textTheme(Color color) {
    TextStyle style(
      double size,
      double lineHeight,
      FontWeight weight,
      double tracking,
    ) {
      return TextStyle(
        fontSize: size,
        height: lineHeight / size,
        fontWeight: weight,
        letterSpacing: tracking,
        color: color,
        leadingDistribution: TextLeadingDistribution.even,
      );
    }

    return TextTheme(
      displaySmall: style(32, 40, FontWeight.w700, -0.5),
      headlineSmall: style(26, 34, FontWeight.w700, -0.3),
      titleLarge: style(20, 28, FontWeight.w600, 0),
      titleMedium: style(16, 24, FontWeight.w600, 0),
      titleSmall: style(14, 20, FontWeight.w600, 0.1),
      bodyLarge: style(16, 24, FontWeight.w400, 0),
      bodyMedium: style(15, 22, FontWeight.w400, 0),
      bodySmall: style(13, 18, FontWeight.w400, 0.1),
      labelLarge: style(15, 20, FontWeight.w600, 0.1),
      labelMedium: style(13, 16, FontWeight.w600, 0.2),
      labelSmall: style(12, 16, FontWeight.w500, 0.4),
    );
  }
}
