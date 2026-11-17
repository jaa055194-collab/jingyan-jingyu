import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../diagnostics/module_test_panel.dart';

/// Independent 3D world / avatar module surface (FR-12: not embedded in chat).
///
/// This is the shell entry: it surfaces room/avatar setup status and entry
/// points, and is honest that the actual Three.js/WebView 3D renderer is not
/// wired yet (needs the feiyu-room-template assets + a Windows WebView2 host).
/// Per product direction each terminal uses its own locally uploaded avatar
/// model; there is no cross-device avatar consistency requirement.
class WorldScreen extends StatelessWidget {
  const WorldScreen({super.key, required this.model, required this.onOpenSetup});
  final ShellViewModel model;
  final VoidCallback onOpenSetup;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('世界与形象', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          model.onboarded ? '形象与房间已设置。' : '形象和房间属于可选世界设置，可稍后在这里完成；聊天不受影响。',
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
        Text('3D 渲染', style: Theme.of(context).textTheme.titleMedium),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '三维街区/房间渲染尚未接入：将按 M10 设计用 WebView + feiyu-room-template（Three.js）承载独立 3D 页面，保留“按提示词生成房间”。'
              '当前外壳提供独立模块入口与性能探针；Windows 端 WebView2 依赖需联网获取或自研插件，真实 3D 与真机（骁龙888，目标稳定30–60fps）测试在接入后单独验收。',
            ),
          ),
        ),
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
