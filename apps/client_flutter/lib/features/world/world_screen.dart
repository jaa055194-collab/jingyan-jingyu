import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../diagnostics/module_test_panel.dart';

/// Independent 3D world / avatar module surface (FR-12: not embedded in chat).
///
/// This is the shell entry: it surfaces room/avatar setup status and entry
/// points. The 3D street opens as its own page (Street3DScreen): on Android a
/// WebView with the three.js page built on the feiyu-room-template; the
/// Windows WebView2 host is not wired yet.
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
    final openStreet = onOpenStreet;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('世界与形象', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(model.onboarded ? '形象与房间已设置。' : '形象和房间属于可选世界设置，可稍后在这里完成；聊天不受影响。'),
        const SizedBox(height: 4),
        const Text(
          '数据来自宿主实时读取；状态在本页只读展示，不修改世界配置。',
          key: Key('world-live-note'),
        ),
        const SizedBox(height: 16),
        if (!model.onboarded)
          FilledButton.icon(
            key: const Key('world-open-setup'),
            onPressed: model.authenticated && !model.busy ? onOpenSetup : null,
            icon: const Icon(Icons.tune),
            label: const Text('设置形象与房间（可选）'),
          ),
        const Divider(height: 32),
        Text('形象模型（各端本地）', style: Theme.of(context).textTheme.titleMedium),
        const Text('以各终端本地上传的模型为准：手机端与电脑端可以使用不同模型；上传即用，不校验授权（个人使用）。'),
        const Divider(height: 32),
        Text('3D 街区', style: Theme.of(context).textTheme.titleMedium),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '在独立页面里查看自己、自己的 AI 和好友的别墅，居民按宿主读到的位置走动。'
              '目前只有 Android 端接入（WebView + feiyu-room-template 的 Three.js），Windows 端的 WebView2 宿主尚未接入；真机（骁龙888，目标稳定30–60fps）测试单独验收。',
            ),
          ),
        ),
        if (openStreet != null) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('world-open-street3d'),
            onPressed: model.authenticated ? openStreet : null,
            icon: const Icon(Icons.location_city_outlined),
            label: const Text('打开 3D 街区'),
          ),
        ],
        const SizedBox(height: 16),
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
    );
  }
}
