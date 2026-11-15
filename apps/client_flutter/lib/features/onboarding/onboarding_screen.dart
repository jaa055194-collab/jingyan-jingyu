import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.model,
    this.initialStep = 0,
    this.onClose,
  });
  final ShellViewModel model;

  /// Character/room setup can be reopened later at step 1 while keeping the
  /// same screens; zero retains the initial connect step.
  final int initialStep;

  /// Set when this screen is pushed as optional world setup; enables back.
  final VoidCallback? onClose;
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final address = TextEditingController();
  final invite = TextEditingController();
  final displayName = TextEditingController();
  final accountId = TextEditingController();
  final deviceName = TextEditingController();
  final password = TextEditingController();
  bool existingAccount = false;
  late int step = widget.initialStep.clamp(0, 2);
  String? sessionAccount;

  @override
  void initState() {
    super.initState();
    sessionAccount = widget.model.connectedAccountId;
  }

  @override
  void didUpdateWidget(covariant OnboardingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final current = widget.model.connectedAccountId;
    if (sessionAccount != null && current != sessionAccount) {
      step = current == null ? 0 : widget.initialStep.clamp(0, 2);
      previewPreset = null;
      validation = null;
    }
    sessionAccount = current;
  }

  String character = 'whale';
  String preset = 'quiet';
  String? previewPreset;
  String? validation;
  @override
  void dispose() {
    address.dispose();
    invite.dispose();
    displayName.dispose();
    accountId.dispose();
    deviceName.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> connect() async {
    if (widget.model.busy) return;
    final uri = Uri.tryParse(address.text.trim());
    String? problem;
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !['http', 'https'].contains(uri.scheme)) {
      problem = '请输入完整的 http(s) 宿主地址';
    } else if (existingAccount && accountId.text.trim().isEmpty) {
      problem = '请输入已有账户 ID';
    } else if (!existingAccount &&
        (invite.text.trim().isEmpty || displayName.text.trim().isEmpty)) {
      problem = '创建新账户需要邀请码和显示名称';
    } else if (!existingAccount && displayName.text.trim().length > 100) {
      problem = '显示名称不能超过 100 个字符';
    } else if (deviceName.text.trim().isEmpty) {
      problem = '请输入设备名称';
    } else if (deviceName.text.trim().length > 100) {
      problem = '设备名称不能超过 100 个字符';
    } else if (password.text.isEmpty) {
      problem = '请输入账户密码';
    } else if (password.text.length > 1024 ||
        (!existingAccount && password.text.length < 12)) {
      problem = existingAccount ? '账户密码不能超过 1024 个字符' : '新账户密码需要 12–1024 个字符';
    }
    setState(() => validation = problem);
    if (problem != null) return;
    widget.model.clearError();
    await widget.model.connectHost(
      address.text.trim(),
      existingAccount ? '' : invite.text.trim(),
      displayName: existingAccount ? '' : displayName.text.trim(),
      password: password.text,
      deviceName: deviceName.text.trim(),
      accountId: existingAccount ? accountId.text.trim() : '',
    );
    if (!mounted) return;
    if (widget.model.error == null) {
      password.clear();
      setState(() => step = 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return Scaffold(
      appBar: AppBar(
        title: const Text('鲸言鲸语'),
        leading: widget.onClose == null
            ? null
            : IconButton(
                tooltip: '返回',
                onPressed: widget.onClose,
                icon: const Icon(Icons.arrow_back),
              ),
      ),
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
              if (step >= 1 && model.connectedAccountId != null) ...[
                SelectableText('账号 ID：${model.connectedAccountId}'),
                const SizedBox(height: 8),
                const Text('保存账号ID可用于已有账号登录'),
                const SizedBox(height: 24),
              ],
              if (step == 0) ...[
                const Text('填写宿主地址，创建新账户或登录已有账户。接入结果以宿主实际响应为准。'),
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
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('新建账户'),
                      selected: !existingAccount,
                      onSelected: model.busy
                          ? null
                          : (_) => setState(() {
                              existingAccount = false;
                              validation = null;
                            }),
                    ),
                    ChoiceChip(
                      label: const Text('已有账户'),
                      selected: existingAccount,
                      onSelected: model.busy
                          ? null
                          : (_) => setState(() {
                              existingAccount = true;
                              validation = null;
                            }),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (existingAccount)
                  TextField(
                    key: const Key('host-account-id'),
                    controller: accountId,
                    enabled: !model.busy,
                    decoration: const InputDecoration(
                      labelText: '账户 ID',
                      border: OutlineInputBorder(),
                    ),
                  )
                else ...[
                  TextField(
                    key: const Key('host-invite'),
                    controller: invite,
                    enabled: !model.busy,
                    decoration: const InputDecoration(
                      labelText: '邀请码',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('host-display-name'),
                    controller: displayName,
                    enabled: !model.busy,
                    decoration: const InputDecoration(
                      labelText: '显示名称',
                      helperText: '最多 100 个字符',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  key: const Key('host-device-name'),
                  controller: deviceName,
                  enabled: !model.busy,
                  decoration: const InputDecoration(
                    labelText: '设备名称',
                    helperText: '最多 100 个字符',
                    hintText: '例如：我的电脑',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('host-password'),
                  controller: password,
                  enabled: !model.busy,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: '账户密码',
                    helperText: existingAccount
                        ? '输入已有密码，最多 1024 个字符'
                        : '新账户密码需要 12–1024 个字符',
                    helperMaxLines: 2,
                    border: const OutlineInputBorder(),
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
                const SizedBox(height: 12),
                if (model.authenticated) ...[
                  OutlinedButton.icon(
                    key: const Key('defer-world-setup'),
                    onPressed: model.busy
                        ? null
                        : () async {
                            model.clearError();
                            await model.enterChat();
                            if (mounted &&
                                model.error == null &&
                                widget.onClose != null) {
                              widget.onClose!();
                            }
                          },
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('稍后设置，先进入聊天'),
                  ),
                  const SizedBox(height: 8),
                  const Text('形象和房间属于可选世界设置，之后可在“世界”里继续。'),
                ],
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
                const SizedBox(height: 12),
                if (model.authenticated)
                  OutlinedButton.icon(
                    key: const Key('defer-world-setup-room'),
                    onPressed: model.busy
                        ? null
                        : () async {
                            model.clearError();
                            await model.enterChat();
                            if (mounted &&
                                model.error == null &&
                                widget.onClose != null) {
                              widget.onClose!();
                            }
                          },
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('稍后设置，先进入聊天'),
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
