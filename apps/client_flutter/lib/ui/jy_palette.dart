import 'package:material_ui/material_ui.dart';

/// 镜语的颜色 token（MASTER.md 第 4 节）。
///
/// 挂在 [ThemeData.extensions] 上；页面用 [JyPalette.of] 取色，不写
/// `Color(0x…)`。字段名和规范表格里的 token 同名，[dark]、[light] 是两套值。
@immutable
class JyPalette extends ThemeExtension<JyPalette> {
  /// 一套完整的 token。
  const JyPalette({
    required this.canvas,
    required this.slab,
    required this.raised,
    required this.overlay,
    required this.text1,
    required this.text2,
    required this.text3,
    required this.signal,
    required this.onSignal,
    required this.signalSoft,
    required this.onSignalSoft,
    required this.ember,
    required this.onEmber,
    required this.emberSoft,
    required this.onEmberSoft,
    required this.success,
    required this.warning,
    required this.danger,
    required this.onDanger,
    required this.dangerSoft,
    required this.onDangerSoft,
    required this.outline,
    required this.hairline,
    required this.edgeHighlight,
    required this.scrim,
    required this.shadow,
  });

  /// 深色。
  static const JyPalette dark = JyPalette(
    canvas: Color(0xFF070B12),
    slab: Color(0xFF0E1520),
    raised: Color(0xFF141D2B),
    overlay: Color(0xFF1A2536),
    text1: Color(0xFFE9EEF5),
    text2: Color(0xFFA9B4C2),
    text3: Color(0xFF8693A4),
    signal: Color(0xFF5BC4FF),
    onSignal: Color(0xFF03131F),
    signalSoft: Color(0xFF0F2A40),
    onSignalSoft: Color(0xFFBFE6FF),
    ember: Color(0xFFFFB45E),
    onEmber: Color(0xFF1F1206),
    emberSoft: Color(0xFF33220F),
    onEmberSoft: Color(0xFFFFDDB5),
    success: Color(0xFF5FD3A2),
    warning: Color(0xFFF4C95D),
    danger: Color(0xFFFF7884),
    onDanger: Color(0xFF2A0509),
    dangerSoft: Color(0xFF3A161B),
    onDangerSoft: Color(0xFFFFD3D7),
    outline: Color(0xFF66768B),
    hairline: Color(0xFF1F2A3B),
    edgeHighlight: Color(0x14FFFFFF), // 白，8%
    scrim: Color(0x99000000), // 黑，60%
    shadow: Color(0x73000000), // 黑，45%
  );

  /// 浅色。
  static const JyPalette light = JyPalette(
    canvas: Color(0xFFEEF2F7),
    slab: Color(0xFFFFFFFF),
    raised: Color(0xFFF5F7FA),
    overlay: Color(0xFFFFFFFF),
    text1: Color(0xFF0C1727),
    text2: Color(0xFF48566A),
    text3: Color(0xFF5E6C82),
    signal: Color(0xFF0B6BD3),
    onSignal: Color(0xFFFFFFFF),
    signalSoft: Color(0xFFDCEBFC),
    onSignalSoft: Color(0xFF06335F),
    ember: Color(0xFFA65A0A),
    onEmber: Color(0xFFFFFFFF),
    emberSoft: Color(0xFFFBEBD8),
    onEmberSoft: Color(0xFF5A2F03),
    success: Color(0xFF127A55),
    warning: Color(0xFF8A6100),
    danger: Color(0xFFC42F40),
    onDanger: Color(0xFFFFFFFF),
    dangerSoft: Color(0xFFFBE3E6),
    onDangerSoft: Color(0xFF6E0F1B),
    outline: Color(0xFF76849A),
    hairline: Color(0xFFDCE2EA),
    edgeHighlight: Color(0xFFFFFFFF), // 白，100%
    scrim: Color(0x660C1727), // #0C1727，40%
    shadow: Color(0x1F0C1727), // #0C1727，12%
  );

  /// 按亮度取 [dark] 或 [light]。
  static JyPalette fallback(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// 当前主题挂的调色板；主题没挂时按主题亮度退回 [fallback]。
  static JyPalette of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return theme.extension<JyPalette>() ?? fallback(theme.brightness);
  }

  /// 页面底色。
  final Color canvas;

  /// 主板。
  final Color slab;

  /// 板上的次级面：输入框、对方气泡、按下底。
  final Color raised;

  /// 弹窗、底部面板、dock、浮动输入条。
  final Color overlay;

  /// 主文字。
  final Color text1;

  /// 次要文字。
  final Color text2;

  /// 说明、时间。
  final Color text3;

  /// 交互主色、己方气泡。
  final Color signal;

  /// signal 上的文字。
  final Color onSignal;

  /// 选中底、徽标底。
  final Color signalSoft;

  /// signalSoft 上的文字。
  final Color onSignalSoft;

  /// AI 伙伴的在场。
  final Color ember;

  /// ember 上的文字。
  final Color onEmber;

  /// 伙伴相关的底。
  final Color emberSoft;

  /// emberSoft 上的文字。
  final Color onEmberSoft;

  /// 成功。
  final Color success;

  /// 警告。
  final Color warning;

  /// 错误、危险操作。
  final Color danger;

  /// danger 上的文字。
  final Color onDanger;

  /// 错误提示条底。
  final Color dangerSoft;

  /// dangerSoft 上的文字。
  final Color onDangerSoft;

  /// 可交互控件的边界（对各面 ≥3:1）。
  final Color outline;

  /// 装饰性分隔，不承载信息。
  final Color hairline;

  /// 板上沿高光；浅色只画在 raised 和 canvas 上。
  final Color edgeHighlight;

  /// 遮罩。
  final Color scrim;

  /// 悬浮物阴影。
  final Color shadow;

  /// 第 4 节的 ColorScheme 映射。surfaceContainerHighest 没有对应 token：
  /// 深色 #223047、浅色 #E6EBF2。关掉 surfaceTint，面只用 token 色。
  ColorScheme toColorScheme(Brightness brightness) {
    return ColorScheme(
      brightness: brightness,
      primary: signal,
      onPrimary: onSignal,
      primaryContainer: signalSoft,
      onPrimaryContainer: onSignalSoft,
      secondary: ember,
      onSecondary: onEmber,
      secondaryContainer: emberSoft,
      onSecondaryContainer: onEmberSoft,
      tertiary: success,
      onTertiary: onSignal,
      error: danger,
      onError: onDanger,
      errorContainer: dangerSoft,
      onErrorContainer: onDangerSoft,
      surface: slab,
      onSurface: text1,
      onSurfaceVariant: text2,
      surfaceDim: canvas,
      surfaceContainerLowest: canvas,
      surfaceContainerLow: slab,
      surfaceContainer: raised,
      surfaceContainerHigh: overlay,
      surfaceContainerHighest: brightness == Brightness.dark
          ? const Color(0xFF223047)
          : const Color(0xFFE6EBF2),
      outline: outline,
      outlineVariant: hairline,
      shadow: shadow.withAlpha(0xFF),
      scrim: scrim.withAlpha(0xFF),
      surfaceTint: const Color(0x00000000),
    );
  }

  @override
  JyPalette copyWith({
    Color? canvas,
    Color? slab,
    Color? raised,
    Color? overlay,
    Color? text1,
    Color? text2,
    Color? text3,
    Color? signal,
    Color? onSignal,
    Color? signalSoft,
    Color? onSignalSoft,
    Color? ember,
    Color? onEmber,
    Color? emberSoft,
    Color? onEmberSoft,
    Color? success,
    Color? warning,
    Color? danger,
    Color? onDanger,
    Color? dangerSoft,
    Color? onDangerSoft,
    Color? outline,
    Color? hairline,
    Color? edgeHighlight,
    Color? scrim,
    Color? shadow,
  }) {
    return JyPalette(
      canvas: canvas ?? this.canvas,
      slab: slab ?? this.slab,
      raised: raised ?? this.raised,
      overlay: overlay ?? this.overlay,
      text1: text1 ?? this.text1,
      text2: text2 ?? this.text2,
      text3: text3 ?? this.text3,
      signal: signal ?? this.signal,
      onSignal: onSignal ?? this.onSignal,
      signalSoft: signalSoft ?? this.signalSoft,
      onSignalSoft: onSignalSoft ?? this.onSignalSoft,
      ember: ember ?? this.ember,
      onEmber: onEmber ?? this.onEmber,
      emberSoft: emberSoft ?? this.emberSoft,
      onEmberSoft: onEmberSoft ?? this.onEmberSoft,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      onDanger: onDanger ?? this.onDanger,
      dangerSoft: dangerSoft ?? this.dangerSoft,
      onDangerSoft: onDangerSoft ?? this.onDangerSoft,
      outline: outline ?? this.outline,
      hairline: hairline ?? this.hairline,
      edgeHighlight: edgeHighlight ?? this.edgeHighlight,
      scrim: scrim ?? this.scrim,
      shadow: shadow ?? this.shadow,
    );
  }

  @override
  JyPalette lerp(covariant ThemeExtension<JyPalette>? other, double t) {
    if (other is! JyPalette) {
      return this;
    }
    final List<Color> a = _colors;
    final List<Color> b = other._colors;
    return _fromColors(<Color>[
      for (int i = 0; i < a.length; i++) Color.lerp(a[i], b[i], t)!,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! JyPalette) {
      return false;
    }
    final List<Color> a = _colors;
    final List<Color> b = other._colors;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_colors);

  List<Color> get _colors => <Color>[
    canvas,
    slab,
    raised,
    overlay,
    text1,
    text2,
    text3,
    signal,
    onSignal,
    signalSoft,
    onSignalSoft,
    ember,
    onEmber,
    emberSoft,
    onEmberSoft,
    success,
    warning,
    danger,
    onDanger,
    dangerSoft,
    onDangerSoft,
    outline,
    hairline,
    edgeHighlight,
    scrim,
    shadow,
  ];

  static JyPalette _fromColors(List<Color> c) {
    return JyPalette(
      canvas: c[0],
      slab: c[1],
      raised: c[2],
      overlay: c[3],
      text1: c[4],
      text2: c[5],
      text3: c[6],
      signal: c[7],
      onSignal: c[8],
      signalSoft: c[9],
      onSignalSoft: c[10],
      ember: c[11],
      onEmber: c[12],
      emberSoft: c[13],
      onEmberSoft: c[14],
      success: c[15],
      warning: c[16],
      danger: c[17],
      onDanger: c[18],
      dangerSoft: c[19],
      onDangerSoft: c[20],
      outline: c[21],
      hairline: c[22],
      edgeHighlight: c[23],
      scrim: c[24],
      shadow: c[25],
    );
  }
}
