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
