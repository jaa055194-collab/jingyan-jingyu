import 'package:material_ui/material_ui.dart';

import '../../ui/jy_palette.dart';
import '../../ui/jy_tokens.dart';

/// AI 配置页的一行失败提示：错误图标加 danger 色文字，出现时读屏会播报。
///
/// 失败不能只靠颜色表达（design-system/jingyu/pages/ai-config.md：结果色都要带图标和文字）。
/// [textKey] 挂在文字上，给原来按 key 找这段文字的地方用。
class AiConfigProblemLine extends StatelessWidget {
  const AiConfigProblemLine(this.message, {super.key, this.textKey});

  final String message;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final danger = JyPalette.of(context).danger;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 装饰图标没有 semanticLabel，读屏只读文字；尺寸跟写入状态块的图标一致。
          Icon(Icons.error_outline, color: danger),
          const SizedBox(width: JySpace.sm),
          Expanded(
            child: Text(
              message,
              key: textKey,
              style: TextStyle(color: danger),
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
