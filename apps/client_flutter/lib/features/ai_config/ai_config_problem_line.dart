import 'package:material_ui/material_ui.dart';

import '../../ui/jy_palette.dart';
import '../../ui/jy_tokens.dart';

/// AI 配置页的一行问题提示：图标加同色文字，出现时读屏会播报。
///
/// 默认构造是失败：错误图标加 danger 色。[AiConfigProblemLine.warning] 用于不算失败、
/// 但挡住了操作的情况（例如未连接宿主）：警告图标加 warning 色。
/// 两种都不能只靠颜色表达（design-system/jingyu/pages/ai-config.md：结果色都要带图标和文字）。
/// [textKey] 挂在文字上，给原来按 key 找这段文字的地方用。
class AiConfigProblemLine extends StatelessWidget {
  const AiConfigProblemLine(this.message, {super.key, this.textKey})
    : _warning = false;

  /// 不算失败、但挡住了操作的提示，例如未连接宿主时无法编辑。
  const AiConfigProblemLine.warning(this.message, {super.key, this.textKey})
    : _warning = true;

  final String message;
  final Key? textKey;
  final bool _warning;

  @override
  Widget build(BuildContext context) {
    final palette = JyPalette.of(context);
    final (icon, color) = _warning
        ? (Icons.warning_amber_outlined, palette.warning)
        : (Icons.error_outline, palette.danger);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 装饰图标没有 semanticLabel，读屏只读文字；尺寸跟写入状态块的图标一致。
          Icon(icon, color: color),
          const SizedBox(width: JySpace.sm),
          Expanded(
            child: Text(
              message,
              key: textKey,
              style: TextStyle(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// AI 配置页的一行状态提示：平常是普通文字，[problem] 为 true 时换成 [AiConfigProblemLine]。
///
/// 两种样子读屏都会播报；[textKey] 照样挂在文字上。
class AiConfigNoticeLine extends StatelessWidget {
  const AiConfigNoticeLine(
    this.message, {
    super.key,
    required this.problem,
    this.textKey,
  });

  final String message;
  final Key? textKey;

  /// 这条提示是不是失败（读不到、写不进、冲突、宿主不认识等）。
  final bool problem;

  @override
  Widget build(BuildContext context) {
    if (problem) {
      return AiConfigProblemLine(message, textKey: textKey);
    }
    return Semantics(
      container: true,
      liveRegion: true,
      child: Text(message, key: textKey),
    );
  }
}
