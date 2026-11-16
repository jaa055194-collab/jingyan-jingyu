import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.model, required this.onBack});
  final ShellViewModel model;
  final VoidCallback onBack;
  Future<void> editLock(BuildContext context, bool enable) async {
    final controller = TextEditingController();
    String? validation;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(enable ? '设置应用锁 PIN' : '关闭应用锁'),
          content: TextField(
            key: const Key('new-pin'),
            controller: controller,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: enable ? '新 PIN（4–12 位数字）' : '当前 PIN',
              errorText: validation,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (!RegExp(r'^\d{4,12}$').hasMatch(controller.text)) {
                  setState(() => validation = '请输入 4–12 位数字 PIN');
                  return;
                }
                model.clearError();
                await model.setAppLock(enable, controller.text);
                if (dialogContext.mounted && model.error == null) {
                  Navigator.pop(dialogContext);
                } else if (dialogContext.mounted) {
                  setState(() => validation = model.error);
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    // Dialog exit animation may still reference the controller; disposal follows
    // its route removal rather than the button's synchronous callback.
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        leading: IconButton(
          tooltip: '返回',
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('设置'),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('隐私与安全', style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              title: const Text('应用锁'),
              subtitle: const Text('使用 PIN 保护本机聊天内容'),
              value: model.appLockEnabled,
              onChanged: model.busy
                  ? null
                  : (value) => editLock(context, value),
            ),
            SwitchListTile(
              title: const Text('隐藏通知正文'),
              subtitle: const Text('通知仅显示有新消息'),
              value: model.hideNotificationBody,
              onChanged: model.busy ? null : model.setHideNotificationBody,
            ),
            SwitchListTile(
              title: const Text('允许 AI 读取附件'),
              subtitle: Text(
                model.selectedConversationId == null
                    ? '请先选择会话，再管理附件授权'
                    : '仅对当前会话生效，可随时撤销',
              ),
              value: model.aiConsentGranted,
              onChanged: model.busy || model.selectedConversationId == null
                  ? null
                  : model.setAiConsent,
            ),
            const Divider(height: 32),
            Text('通用', style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              title: const Text('开机自启动'),
              subtitle: const Text('由当前设备的平台能力决定是否可用'),
              value: model.autoStart,
              onChanged: model.busy ? null : model.setAutoStart,
            ),
            const SizedBox(height: 16),
            const Text('外观'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final item in const {
                  ThemeMode.system: '跟随系统',
                  ThemeMode.light: '浅色',
                  ThemeMode.dark: '深色',
                }.entries)
                  ChoiceChip(
                    label: Text(item.value),
                    selected: model.themeMode == item.key,
                    onSelected: model.busy
                        ? null
                        : (_) => model.setThemeMode(item.key),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            Text('字体大小 · ${(model.fontScale * 100).round()}%'),
            Slider(
              value: model.fontScale.clamp(0.85, 1.5),
              min: 0.85,
              max: 1.5,
              divisions: 13,
              label: '${(model.fontScale * 100).round()}%',
              onChanged: model.busy ? null : model.setFontScale,
            ),
            const Text('此设置同时应用于导航、消息和输入区域。'),
            const Divider(height: 32),
            Text('我的 AI', style: Theme.of(context).textTheme.titleMedium),
            const Text('仅管理你拥有的 AI 账户。回复仍需宿主配置；创建不会自动配置模型、社交等级或授权。'),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  key: const Key('own-ai-refresh'),
                  onPressed:
                      model.authenticated &&
                          model.online &&
                          !model.locked &&
                          !model.busy
                      ? model.loadOwnAi
                      : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新我的 AI'),
                ),
                FilledButton.icon(
                  key: const Key('own-ai-create'),
                  onPressed:
                      model.authenticated &&
                          model.online &&
                          !model.locked &&
                          !model.busy
                      ? () => showDialog<void>(
                          context: context,
                          builder: (_) => _CreateOwnAiDialog(model: model),
                        )
                      : null,
                  icon: const Icon(Icons.add),
                  label: const Text('创建 AI 账户'),
                ),
              ],
            ),
            if (model.authenticated && !model.locked) ...[
              if (model.ownAiNotice != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: SelectableText(model.ownAiNotice!),
                ),
              if (model.ownAiAccounts.isEmpty)
                Text(model.ownAiLoaded ? '你还没有 AI 账户。' : '尚未加载，请刷新我的 AI。'),
              for (final ai in model.ownAiAccounts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${ai.displayName} · ${ai.disabled ? "已停用" : "未停用"}',
                      ),
                      SelectableText(ai.accountId),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    ],
  );
}

class _CreateOwnAiDialog extends StatefulWidget {
  const _CreateOwnAiDialog({required this.model});
  final ShellViewModel model;
  @override
  State<_CreateOwnAiDialog> createState() => _CreateOwnAiDialogState();
}

class _CreateOwnAiDialogState extends State<_CreateOwnAiDialog> {
  final input = TextEditingController();
  final form = GlobalKey<FormState>();
  late final String? account;
  late final Object? sessionContext;
  bool invalidated = false, saving = false;
  @override
  void initState() {
    super.initState();
    account = widget.model.connectedAccountId;
    sessionContext = widget.model.ownAiSessionContext;
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final model = widget.model;
    if (invalidated ||
        saving ||
        model.busy ||
        model.ownAiSessionContext != sessionContext ||
        !model.authenticated ||
        model.locked ||
        !model.online ||
        form.currentState?.validate() != true) {
      return;
    }
    setState(() => saving = true);
    await model.createOwnAi(input.text);
    if (!mounted || invalidated) return;
    final creationConfirmed = model.ownAiNotice?.contains('AI账户已创建：') == true;
    if (creationConfirmed ||
        (model.error == null && model.authenticated && !model.locked)) {
      Navigator.of(context).pop();
    } else {
      setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final model = widget.model;
      if (!model.authenticated ||
          model.locked ||
          model.connectedAccountId != account ||
          model.ownAiSessionContext != sessionContext) {
        invalidated = true;
      }
      if (invalidated) {
        return AlertDialog(
          title: const Text('登录已变化或应用已锁定'),
          content: const Text('已隐藏输入，请关闭后重新操作。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      }
      return PopScope(
        canPop: !saving,
        child: AlertDialog(
          title: const Text('创建 AI 账户'),
          content: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('仅创建当前账号拥有的独立 AI 账户，不自动开启回复。'),
                  TextFormField(
                    key: const Key('own-ai-name'),
                    controller: input,
                    autofocus: true,
                    enabled: !saving && model.online,
                    decoration: const InputDecoration(labelText: '显示名称'),
                    validator: (value) =>
                        value == null ||
                            value.trim().isEmpty ||
                            value.length > 100
                        ? '请输入1–100个字符'
                        : null,
                    onFieldSubmitted: (_) => submit(),
                  ),
                  if (model.error != null)
                    Text(
                      model.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (saving) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('own-ai-confirm'),
              onPressed: !saving && !model.busy && model.online ? submit : null,
              child: const Text('创建'),
            ),
          ],
        ),
      );
    },
  );
}

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key, required this.model});
  final ShellViewModel model;
  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final pin = TextEditingController();
  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            const Icon(Icons.lock_outline, size: 40),
            const SizedBox(height: 16),
            Text('解锁鲸言鲸语', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 24),
            TextField(
              key: const Key('unlock-pin'),
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'PIN',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => widget.model.unlock(pin.text),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: widget.model.busy
                  ? null
                  : () => widget.model.unlock(pin.text),
              child: const Text('解锁'),
            ),
            if (widget.model.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    widget.model.error!,
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
