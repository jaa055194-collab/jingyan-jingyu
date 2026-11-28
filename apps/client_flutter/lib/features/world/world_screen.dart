import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../ui/ui.dart';
import '../diagnostics/module_test_panel.dart';
import 'street3d_entry.dart';

/// Independent 3D world / avatar module surface (FR-12: not embedded in chat).
///
/// This is the shell entry: it surfaces room/avatar setup status and entry
/// points. The 3D street section is its own widget (Street3DEntry), which
/// says where the street runs so far and opens it as a separate page.
/// Per product direction each terminal uses its own locally uploaded avatar
/// model; there is no cross-device avatar consistency requirement.
class WorldScreen extends StatelessWidget {
  const WorldScreen({
    super.key,
    required this.model,
    required this.onOpenSetup,
    this.onOpenStreet,
  });
  final ShellViewModel model;
  final VoidCallback onOpenSetup;

  /// Opens the 3D street page; without it the page shows no street entry.
  final VoidCallback? onOpenStreet;

  @override
  Widget build(BuildContext context) {
    // A plain scroll view builds every row, so the optional setup action can
    // still be scrolled into view on a short screen with large text.
    final palette = JyPalette.of(context);
    final text = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(JySpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          JySlab(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '世界与形象',
                  style: text.titleMedium?.copyWith(color: palette.text1),
                ),
                const SizedBox(height: JySpace.sm),
                Text(
                  model.onboarded
                      ? '形象与房间已设置。'
                      : '形象和房间属于可选世界设置，可稍后在这里完成；聊天不受影响。',
                ),
                const SizedBox(height: JySpace.xs),
                Text(
                  '数据来自宿主实时读取；状态在本页只读展示，不修改世界配置。',
                  key: const Key('world-live-note'),
                  style: text.bodySmall?.copyWith(color: palette.text3),
                ),
                if (!model.onboarded) ...[
                  const SizedBox(height: JySpace.lg),
                  FilledButton.icon(
                    key: const Key('world-open-setup'),
                    onPressed: model.authenticated && !model.busy
                        ? onOpenSetup
                        : null,
                    icon: const Icon(Icons.tune),
                    label: const Text('设置形象与房间（可选）'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: JySpace.md),
          JySlab(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '形象模型（各端本地）',
                  style: text.titleMedium?.copyWith(color: palette.text1),
                ),
                const SizedBox(height: JySpace.sm),
                const Text('以各终端本地上传的模型为准：手机端与电脑端可以使用不同模型；上传即用，不校验授权（个人使用）。'),
              ],
            ),
          ),
          const SizedBox(height: JySpace.md),
          Street3DEntry(onOpen: onOpenStreet, enabled: model.authenticated),
          const SizedBox(height: JySpace.lg),
          OutlinedButton.icon(
            key: const Key('world-open-perf'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('模块测试与性能探针')),
                  body: const ModuleTestPanel(),
                ),
              ),
            ),
            icon: const Icon(Icons.monitor_heart_outlined),
            label: const Text('打开模块测试与性能探针'),
          ),
        ],
      ),
    );
  }
}
