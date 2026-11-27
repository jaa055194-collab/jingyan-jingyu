import 'package:material_ui/material_ui.dart';

/// The 3D street section of the world page: what the street shows, where it
/// runs so far, and the button that opens it.
///
/// WorldScreen mounts it once and keeps the page layout; the street content
/// stays in this widget.
class Street3DEntry extends StatelessWidget {
  const Street3DEntry({super.key, this.onOpen, this.enabled = true});

  /// Opens the 3D street page; without it the section shows no button.
  final VoidCallback? onOpen;

  /// Whether the button can be pressed: the street reads the signed-in
  /// account's data from the host.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final open = onOpen;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        if (open != null) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('world-open-street3d'),
            onPressed: enabled ? open : null,
            icon: const Icon(Icons.location_city_outlined),
            label: const Text('打开 3D 街区'),
          ),
        ],
      ],
    );
  }
}
