import 'package:material_ui/material_ui.dart';

import '../../app/runtime.dart';
import '../../app/shell_view_model.dart';
import '../../net/lifecycle_api.dart';
import '../../net/ai_config_write_api.dart';
import '../../net/owner_ai_direct_api.dart';
import '../../net/owner_ai_readiness_api.dart';
import '../../net/voice_api.dart';
import '../../net/world_api.dart';
import '../ai_config/ai_config_editor.dart';
import '../ai_config/ai_config_panel.dart';
import '../diagnostics/module_test_panel.dart';
import '../lifecycle/backup_quota_screen.dart';
import '../voice/voice_screen.dart';
import '../world/world_status_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.model, required this.onBack});
  final ShellViewModel model;
  final VoidCallback onBack;

  /// Builds the lifecycle/backup screen, wiring the real [LifecycleApi] when a
  /// host connection exists so export/import are usable. Cleanup stays disabled
  /// (no merged host cleanup route). Exposed for focused wiring tests.
  static BackupQuotaScreen lifecycleScreenFor(ShellViewModel model) {
    final connection = model is ClientRuntime ? model.connection : null;
    return BackupQuotaScreen(
      api: connection == null ? null : LifecycleApi(connection),
    );
  }

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
            Text('开发者', style: Theme.of(context).textTheme.titleMedium),
            ListTile(
              key: const Key('open-module-test'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.monitor_heart_outlined),
              title: const Text('模块测试与性能探针'),
              subtitle: const Text('列出已接入模块，并测量本机帧率/帧耗时与内存（显存需真机原生工具）'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('模块测试与性能探针')),
                    body: const ModuleTestPanel(),
                  ),
                ),
              ),
            ),
            ListTile(
              key: const Key('open-lifecycle-status'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.storage_outlined),
              title: const Text('配额与生命周期状态'),
              subtitle: const Text('只读查看当前账号配额与生命周期对象清点；不代表可用或已授权'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => lifecycleScreenFor(model),
                  ),
                );
              },
            ),
            ListTile(
              key: const Key('open-ai-config'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.fact_check_outlined),
              title: const Text('AI 运行配置体检'),
              subtitle: const Text(
                '只读查看人格/绑定/预算/provider 配置元数据；不等于模型可用、预算获批或已授权回复',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final runtime = model;
                final connection = runtime is ClientRuntime
                    ? runtime.connection
                    : null;
                final owner = model.connectedAccountId;
                final owned = <String>[
                  for (final ai in model.ownAiAccounts)
                    if (!ai.disabled) ai.accountId,
                ];
                final canLoad = connection != null && owner != null;
                final loadForAccount = canLoad
                    ? (String aiAccountId) => AiConfigPanel.resolveAndLoad(
                        OwnerAiDirectApi(connection),
                        OwnerAiReadinessApi(connection),
                        aiAccountId: aiAccountId,
                        expectedOwnerAccountId: owner,
                      )
                    : null;
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AiConfigPanel(
                      loadForAccount: loadForAccount,
                      ownedAiAccountIds: canLoad ? owned : const <String>[],
                    ),
                  ),
                );
              },
            ),
            ListTile(
              key: const Key('open-ai-config-write'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('AI 运行配置'),
              subtitle: const Text(
                '编辑人格/Provider/聊天绑定/预算；api_key 遮蔽输入、只显示掩码，绝不回显或记录密钥',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final runtime = model;
                final connection = runtime is ClientRuntime
                    ? runtime.connection
                    : null;
                final owner = model.connectedAccountId;
                final owned = <String>[
                  for (final ai in model.ownAiAccounts)
                    if (!ai.disabled) ai.accountId,
                ];
                final writer = connection == null
                    ? null
                    : AiConfigWriteApi(connection);
                final resolve = (connection != null && owner != null)
                    ? (String accountId) => OwnerAiDirectApi(connection)
                          .registerOrResolve(
                            accountId,
                            expectedOwnerAccountId: owner,
                          )
                          .then((identity) => identity.profileId)
                    : null;
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AiConfigEditor(
                      writer: writer,
                      resolveProfileId: resolve,
                      ownedAiAccountIds: owned,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              key: const Key('open-voice-profile'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.graphic_eq_outlined),
              title: const Text('语音音色'),
              subtitle: const Text('只读查看某 AI 的音色档案；需显式输入 AI 档案 id，不代表可用或已授权'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final runtime = model;
                final connection = runtime is ClientRuntime
                    ? runtime.connection
                    : null;
                Future<VoiceProfileView> Function(String aiId)? loadProfile;
                if (connection != null) {
                  final api = VoiceApi(connection);
                  loadProfile = (aiId) => api.readProfile(aiId);
                }
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => VoiceScreen(loadProfile: loadProfile),
                  ),
                );
              },
            ),
            ListTile(
              key: const Key('open-world-status'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.public_outlined),
              title: const Text('世界状态'),
              subtitle: const Text(
                '只读查看世界布局/在场/形象的安全元数据；不做 3D 渲染、不含模型字节或密钥，未知如实标注',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final runtime = model;
                final connection = runtime is ClientRuntime
                    ? runtime.connection
                    : null;
                final load = connection == null
                    ? null
                    : (String spaceId) => WorldStatusScreen.loadFrom(
                        WorldApi(connection),
                        spaceId,
                      );
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => WorldStatusScreen(load: load),
                  ),
                );
              },
            ),
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
                      _OwnAiDirectControls(model: model, ai: ai),
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

class _OwnAiDirectControls extends StatelessWidget {
  const _OwnAiDirectControls({required this.model, required this.ai});
  final ShellViewModel model;
  final ShellOwnedAi ai;

  @override
  Widget build(BuildContext context) {
    final state = model.ownAiDirectState(ai.accountId);
    final available =
        model.authenticated &&
        model.online &&
        !model.locked &&
        !model.busy &&
        !ai.disabled;
    final ready =
        state.phase == ShellOwnAiDirectPhase.ready &&
        state.profileId != null &&
        state.profileId!.isNotEmpty &&
        state.revision != null &&
        state.enabled != null &&
        model.ownAiDirectContext != null;
    final status = switch (state.phase) {
      ShellOwnAiDirectPhase.unknown => '私聊授权：尚未确认，请刷新状态。',
      ShellOwnAiDirectPhase.loading => '私聊授权：正在读取状态…',
      ShellOwnAiDirectPhase.uncertain => '私聊授权：结果未确认，请刷新状态，不会自动重试。',
      ShellOwnAiDirectPhase.ready =>
        ready ? (state.enabled! ? '私聊授权：已开启' : '私聊授权：已关闭') : '私聊授权：尚未确认，请刷新状态。',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(status),
        if (state.notice != null) Text(state.notice!),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              key: Key('own-ai-direct-refresh-${ai.accountId}'),
              onPressed:
                  available && state.phase != ShellOwnAiDirectPhase.loading
                  ? () => model.loadOwnAiDirectConsent(ai.accountId)
                  : null,
              child: const Text('刷新授权状态'),
            ),
            if (ready)
              TextButton(
                key: Key('own-ai-direct-toggle-${ai.accountId}'),
                onPressed: available
                    ? () => showDialog<void>(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) => _OwnAiDirectDialog(
                          model: model,
                          ai: ai,
                          state: state,
                        ),
                      )
                    : null,
                child: Text(state.enabled! ? '撤销私聊授权' : '授权主人私聊'),
              ),
          ],
        ),
      ],
    );
  }
}

class _OwnAiDirectDialog extends StatefulWidget {
  const _OwnAiDirectDialog({
    required this.model,
    required this.ai,
    required this.state,
  });
  final ShellViewModel model;
  final ShellOwnedAi ai;
  final ShellOwnAiDirectState state;
  @override
  State<_OwnAiDirectDialog> createState() => _OwnAiDirectDialogState();
}

class _OwnAiDirectDialogState extends State<_OwnAiDirectDialog> {
  late final String? owner;
  late final Object? interaction;
  late final Object? session;
  late final String profile;
  late final int revision;
  late final bool enable;
  bool invalidated = false, saving = false, submitted = false;
  bool confirmed = false;

  @override
  void initState() {
    super.initState();
    owner = widget.model.connectedAccountId;
    interaction = widget.model.ownAiDirectContext;
    session = widget.model.ownAiSessionContext;
    profile = widget.state.profileId!;
    revision = widget.state.revision!;
    enable = !widget.state.enabled!;
    widget.model.addListener(changed);
  }

  @override
  void dispose() {
    widget.model.removeListener(changed);
    super.dispose();
  }

  bool identityValid() {
    final model = widget.model;
    final matching = model.ownAiAccounts.where(
      (row) =>
          row.accountId == widget.ai.accountId &&
          row.displayName == widget.ai.displayName &&
          row.disabled == widget.ai.disabled &&
          !row.disabled,
    );
    return model.authenticated &&
        !model.locked &&
        owner != null &&
        model.connectedAccountId == owner &&
        interaction != null &&
        model.ownAiSessionContext == session &&
        (submitted || model.ownAiDirectContext == interaction) &&
        matching.length == 1;
  }

  void changed() {
    // Listener latches even a lock/unlock cycle that happens before next frame.
    if (!identityValid()) invalidated = true;
    final state = widget.model.ownAiDirectState(widget.ai.accountId);
    if (!submitted &&
        (state.phase != ShellOwnAiDirectPhase.ready ||
            state.profileId != profile ||
            state.revision != revision ||
            state.enabled != !enable)) {
      invalidated = true;
    }
    if (mounted) setState(() {});
  }

  Future<void> submit() async {
    final model = widget.model;
    if (invalidated ||
        submitted ||
        saving ||
        !identityValid() ||
        !model.online ||
        model.busy) {
      return;
    }
    final current = model.ownAiDirectState(widget.ai.accountId);
    if (current.phase != ShellOwnAiDirectPhase.ready ||
        current.profileId != profile ||
        current.revision != revision ||
        current.enabled != !enable) {
      setState(() => invalidated = true);
      return;
    }
    setState(() {
      submitted = true;
      saving = true;
    });
    try {
      await model.setOwnAiDirectConsent(
        widget.ai.accountId,
        profileId: profile,
        expectedRevision: revision,
        enabled: enable,
        interactionContext: interaction!,
      );
    } catch (_) {
      // Result is uncertain; never resubmit this confirmation or expose details.
    }
    if (!mounted) return;
    if (!identityValid()) invalidated = true;
    final result = model.ownAiDirectState(widget.ai.accountId);
    confirmed =
        !invalidated &&
        model.error == null &&
        result.phase == ShellOwnAiDirectPhase.ready &&
        result.profileId == profile &&
        result.enabled == enable &&
        result.revision != null &&
        result.revision == revision + 1;
    if (confirmed) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    if (!identityValid()) invalidated = true;
    if (invalidated) {
      return AlertDialog(
        title: const Text('授权操作已失效'),
        content: const Text('登录、授权上下文已变化或应用已锁定。已隐藏详情，请关闭后重新操作。'),
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
        title: Text(enable ? '确认授权主人私聊' : '确认撤销私聊授权'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.ai.displayName),
              Text('AI账户：${widget.ai.accountId}'),
              Text('档案：$profile · 版本：$revision'),
              const SizedBox(height: 8),
              Text(
                enable
                    ? '仅在你主动发送时，把当前单条文本与已保存的人格发送给宿主已配置的模型。'
                          '不包含群聊、历史、记忆。开启后可刷新会话列表查看私聊；回复仍需宿主模型配置。授权不会自动发送消息、配置模型或跳转会话。'
                    : '撤销后不再允许本授权的后续回复；保留已有历史。不会自动发送消息。',
              ),
              if (submitted && !saving && !confirmed)
                const Text('结果未确认或授权版本已变化，请关闭后刷新状态；不会自动重试。'),
              if (saving)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.of(context).pop(),
            child: Text(submitted ? '关闭' : '取消'),
          ),
          if (!submitted || saving)
            TextButton(
              key: const Key('own-ai-direct-confirm'),
              onPressed: !submitted && !saving && !model.busy && model.online
                  ? submit
                  : null,
              child: Text(enable ? '确认授权' : '确认撤销'),
            ),
        ],
      ),
    );
  }
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
