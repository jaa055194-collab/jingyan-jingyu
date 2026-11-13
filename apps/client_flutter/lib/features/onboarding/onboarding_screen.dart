import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.model});
  final ShellViewModel model;
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final address = TextEditingController();
  final invite = TextEditingController();
  int step = 0;
  String character = 'whale';
  String preset = 'quiet';
  String? previewPreset;
  String? validation;
  @override
  void dispose() {
    address.dispose();
    invite.dispose();
    super.dispose();
  }

  Future<void> connect() async {
    final uri = Uri.tryParse(address.text.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        !['http', 'https'].contains(uri.scheme) ||
        invite.text.trim().isEmpty) {
      setState(() => validation = '请输入完整的 http(s) 宿主地址和邀请码');
      return;
    }
    setState(() => validation = null);
    widget.model.clearError();
    await widget.model.connectHost(address.text.trim(), invite.text.trim());
    if (mounted && widget.model.error == null) setState(() => step = 1);
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return Scaffold(
      appBar: AppBar(title: const Text('鲸言鲸语')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              Text(
                '初次设置 · ${step + 1}/3',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 16),
              Text(
                ['连接你的宿主', '选择你的形象', '创建你的房间'][step],
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 24),
              if (step == 0) ...[
                const Text('填写宿主提供的地址和邀请码。接入结果以宿主实际响应为准。'),
                const SizedBox(height: 24),
                TextField(
                  key: const Key('host-address'),
                  controller: address,
                  enabled: !model.busy,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '宿主地址',
                    hintText: 'https://host.example',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('host-invite'),
                  controller: invite,
                  enabled: !model.busy,
                  decoration: const InputDecoration(
                    labelText: '邀请码',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (validation != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      validation!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: model.busy ? null : connect,
                  child: const Text('连接宿主'),
                ),
              ],
              if (step == 1) ...[
                const Text('选择一个初始形象，之后可以在个人设置中调整。'),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final item in const {
                      'whale': '小鲸',
                      'fox': '小狐',
                      'cat': '小猫',
                    }.entries)
                      ChoiceChip(
                        label: Text(item.value),
                        selected: character == item.key,
                        onSelected: model.busy
                            ? null
                            : (_) => setState(() => character = item.key),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: model.busy
                      ? null
                      : () async {
                          model.clearError();
                          await model.chooseCharacter(character);
                          if (mounted && model.error == null) {
                            setState(() => step = 2);
                          }
                        },
                  child: const Text('下一步'),
                ),
              ],
              if (step == 2) ...[
                const Text('选择 RoomBrief 预设，生成并检查预览后再确认。'),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final item in const {
                      'quiet': '安静书房',
                      'creative': '创作空间',
                      'garden': '花园小屋',
                    }.entries)
                      ChoiceChip(
                        label: Text(item.value),
                        selected: preset == item.key,
                        onSelected: model.busy
                            ? null
                            : (_) => setState(() => preset = item.key),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: model.busy
                      ? null
                      : () async {
                          model.clearError();
                          setState(() => previewPreset = null);
                          await model.generateRoom(preset);
                          if (mounted &&
                              model.error == null &&
                              model.roomPreview != null) {
                            setState(() => previewPreset = preset);
                          }
                        },
                  child: const Text('生成预览'),
                ),
                const SizedBox(height: 16),
                if (model.roomPreview != null && previewPreset == preset)
                  Semantics(
                    liveRegion: true,
                    child: SelectableText(model.roomPreview!),
                  )
                else
                  const Text('尚未生成预览。'),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed:
                      model.busy ||
                          model.roomPreview == null ||
                          previewPreset != preset
                      ? null
                      : model.confirmRoom,
                  child: const Text('确认并进入'),
                ),
              ],
              if (model.busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
              if (model.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      model.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
