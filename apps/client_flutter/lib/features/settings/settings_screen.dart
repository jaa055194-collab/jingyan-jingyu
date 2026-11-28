import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';

import '../../app/android_private_ai_route.dart';
import '../../app/runtime.dart';
import '../../app/shell_view_model.dart';
import '../../net/attachment_api.dart';
import '../../net/device_sessions_api.dart';
import '../../net/lifecycle_api.dart';
import '../../platform/native_platform.dart';
import '../../net/ai_config_write_api.dart';
import '../../net/model_diagnostics_api.dart';
import '../../net/owner_ai_direct_api.dart';
import '../../net/owner_ai_readiness_api.dart';
import '../../net/owner_auto_memory_api.dart';
import '../../net/owner_memory_notes_api.dart';
import '../../net/owner_model_proactive_api.dart';
import '../../net/owner_reply_preferences_api.dart';
import '../../net/owner_rule_greeting_api.dart';
import '../../net/owner_social_level_api.dart';
import '../../net/persona_history_api.dart';
import '../../net/search_api.dart';
import '../../net/voice_api.dart';
import '../../net/voice_call_api.dart';
import '../../net/world_api.dart';
import '../../ui/ui.dart';
import '../ai_config/ai_config_editor.dart';
import '../ai_config/ai_config_panel.dart';
import '../ai_config/model_diagnostics_screen.dart';
import '../ai_config/persona_file_picker.dart';
import '../attachments/attachments_list_screen.dart';
import '../attachments/attachments_screen.dart';
import '../diagnostics/module_test_panel.dart';
import '../lifecycle/backup_file_preview.dart';
import '../lifecycle/backup_file_preview_panel.dart';
import '../lifecycle/backup_files.dart';
import '../lifecycle/backup_quota_screen.dart';
import '../search/search_screen.dart';
import '../voice/voice_call_list_screen.dart';
import '../voice/voice_screen.dart';
import '../world/world_status_screen.dart';
import 'android_ai_directory_screen.dart';
import 'device_sessions_screen.dart';
import 'owner_rule_greeting_settings_panel.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.model,
    required this.onBack,
    this.onOpenOwnAiChat,
    this.checkingOwnAiAccount,
  });
  final ShellViewModel model;
  final VoidCallback onBack;
  final Future<void> Function(BuildContext, String)? onOpenOwnAiChat;
  final String? checkingOwnAiAccount;

  /// Builds the existing lifecycle screen; Settings pins optional local preview
  /// access when the route opens, not when the shell later rebuilds.
  static BackupQuotaScreen lifecycleScreenFor(
    ShellViewModel model, {
    BackupFilePreviewAccess? filePreview,
  }) {
    final connection = model is ClientRuntime ? model.connection : null;
    return BackupQuotaScreen(
      api: connection == null ? null : LifecycleApi(connection),
      backupFiles: connection == null
          ? null
          : NativeBackupFileStore(NativePlatform()),
      filePreview: filePreview,
      canWritePlaintext: model.authenticated && !model.locked,
    );
  }

  static BackupFilePreviewAccess? _captureFilePreview(ShellViewModel model) {
    if (!Platform.isWindows ||
        model is! ClientRuntime ||
        !model.authenticated ||
        model.locked) {
      return null;
    }
    final runtime = model;
    final owner = runtime.connectedAccountId;
    final connection = runtime.connection;
    final epoch = runtime.ownAiSessionContext;
    final lockEnabled = runtime.appLockEnabled;
    final lockEpoch = runtime.ownAiDirectContext;
    if (owner == null ||
        connection == null ||
        epoch == null ||
        lockEpoch == null) {
      return null;
    }
    final platform = NativePlatform();
    return (
      session: runtime,
      isCurrent: () {
        final interaction = runtime.ownAiDirectContext;
        // Inactive can advance this epoch even with the PIN disabled. A real
        // lock still invalidates the route, including before its first frame.
        return runtime.authenticated &&
            !runtime.locked &&
            runtime.appLockEnabled == lockEnabled &&
            runtime.connectedAccountId == owner &&
            runtime.ownAiSessionContext == epoch &&
            interaction != null &&
            (!lockEnabled || identical(interaction, lockEpoch)) &&
            identical(runtime.connection, connection);
      },
      pick: (isCurrent) => pickBackupFilePreview(
        platform: platform,
        expectedOwnerAccountId: owner,
        isCurrent: isCurrent,
      ),
    );
  }

  void _openGreetingStop(BuildContext context) {
    final shell = model;
    final runtime = shell is ClientRuntime ? shell : null;
    final connection = runtime?.connection;
    final owner = shell.connectedAccountId;
    final session = shell.ownAiSessionContext;
    final lock = shell.ownAiDirectContext;
    if (connection == null ||
        owner == null ||
        session == null ||
        lock == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('解锁并连接宿主后才能管理账户级停止。')));
      return;
    }
    bool isCurrent() =>
        shell.authenticated &&
        !shell.locked &&
        shell.connectedAccountId == owner &&
        shell.ownAiSessionContext == session &&
        identical(shell.ownAiDirectContext, lock) &&
        identical(runtime?.connection, connection);
    if (!isCurrent()) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OwnerRuleGreetingStopScreen(
          api: OwnerRuleGreetingApi(connection),
          session: shell,
          isCurrent: isCurrent,
        ),
      ),
    );
  }

  // On the native Flutter targets this follows the device platform, not the
  // theme or screen width: a narrow Windows window keeps the desktop settings.
  bool get _android => defaultTargetPlatform == TargetPlatform.android;

  void _openAiConfig(
    BuildContext context, {
    ShellOwnedAi? androidAi,
    Object? renderedInteraction,
  }) {
    final shell = model;
    final runtime = shell is ClientRuntime ? shell : null;
    final owner = shell.connectedAccountId;
    final epoch = shell.ownAiSessionContext;
    // Also catch a lock between the tap and the editor's first frame.
    final lockEpoch = shell.ownAiDirectContext;
    final connection =
        shell.authenticated &&
            !shell.locked &&
            owner != null &&
            epoch != null &&
            lockEpoch != null
        ? runtime?.connection
        : null;
    bool sessionCurrent() =>
        shell.authenticated &&
        !shell.locked &&
        shell.connectedAccountId == owner &&
        shell.ownAiSessionContext == epoch &&
        identical(shell.ownAiDirectContext, lockEpoch) &&
        identical(runtime?.connection, connection);
    if (androidAi != null &&
        (connection == null ||
            !shell.online ||
            shell.busy ||
            !identical(lockEpoch, renderedInteraction) ||
            !shell.ownAiAccounts.any(
              (ai) =>
                  ai.accountId == androidAi.accountId &&
                  ai.displayName == androidAi.displayName &&
                  !ai.disabled,
            ))) {
      return;
    }
    final owned = connection == null
        ? const <String>[]
        : androidAi != null
        ? [androidAi.accountId]
        : [
            for (final ai in shell.ownAiAccounts)
              if (!ai.disabled) ai.accountId,
          ];
    final writer = connection == null
        ? null
        : AiConfigWriteApi(
            connection,
            retryAuthentication: false,
            allowMultilinePersona: androidAi != null,
          );
    final direct = connection == null ? null : OwnerAiDirectApi(connection);
    final catalog = connection == null ? null : ModelDiagnosticsApi(connection);
    final history = connection == null ? null : PersonaHistoryApi(connection);
    final androidDetails =
        androidAi == null ||
            connection == null ||
            direct == null ||
            owner == null
        ? null
        : (
            aiLabel: androidAi.displayName,
            resolveIdentity: (String accountId) => direct.registerOrResolve(
              accountId,
              expectedOwnerAccountId: owner,
              retryAuthentication: false,
            ),
            readiness: OwnerAiReadinessApi(connection),
          );
    AiConfigEditor buildEditor() => AiConfigEditor(
      writer: writer,
      androidDetails: androidDetails,
      resolveProfileId: direct == null || owner == null || androidAi != null
          ? null
          : (accountId) => direct
                .registerOrResolve(accountId, expectedOwnerAccountId: owner)
                .then((identity) => identity.profileId),
      readCatalog: catalog == null
          ? null
          : (providerId) => catalog.readModelCatalog(
              providerId,
              retryAuthentication: false,
            ),
      readPersonaHistory: history?.read,
      replyPreferences: connection == null
          ? null
          : OwnerReplyPreferencesApi(connection),
      socialLevel: androidDetails == null || connection == null
          ? null
          : OwnerSocialLevelApi(connection),
      ruleGreeting: connection == null
          ? null
          : OwnerRuleGreetingApi(connection),
      memoryNotes: connection == null ? null : OwnerMemoryNotesApi(connection),
      autoMemory: connection == null ? null : OwnerAutoMemoryApi(connection),
      modelProactive: connection == null
          ? null
          : OwnerModelProactiveApi(connection),
      personaFilePicker: connection == null ? null : NativePersonaFilePicker(),
      session: connection == null
          ? null
          : (model: shell, isCurrent: sessionCurrent),
      ownedAiAccountIds: owned,
    );

    // Navigator can rebuild the page on ordinary shell updates. Keep the
    // Android editor's inputs (including API identities used as child keys)
    // stable for this route; the editor still listens to the pinned session.
    final androidEditor = androidDetails == null ? null : buildEditor();
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => androidEditor ?? buildEditor()),
    );
  }

  void _openPrivateChat(
    BuildContext context,
    ShellOwnedAi ai,
    Object interaction,
  ) {
    final shell = model;
    if (shell is! ClientRuntime ||
        !shell.authenticated ||
        shell.locked ||
        !identical(shell.ownAiDirectContext, interaction) ||
        !shell.ownAiAccounts.any(
          (row) => row.accountId == ai.accountId && !row.disabled,
        )) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AndroidPrivateAiRoute(
          runtime: shell,
          ai: ai,
          interaction: interaction,
        ),
      ),
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

  List<Widget> _ownAiSection(BuildContext context) {
    final canManage = model.authenticated && !model.locked;
    final canContactHost = canManage && model.online && !model.busy;
    return [
      Text('我的 AI', style: Theme.of(context).textTheme.titleMedium),
      const Text('仅管理你拥有的 AI 账户。回复仍需宿主配置；创建不会自动配置模型、社交等级或授权。'),
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            key: const Key('own-ai-refresh'),
            onPressed: canContactHost ? model.loadOwnAi : null,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新我的 AI'),
          ),
          FilledButton.icon(
            key: const Key('own-ai-create'),
            onPressed: canContactHost
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
      if (canManage) ...[
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
                Text('${ai.displayName} · ${ai.disabled ? "已停用" : "未停用"}'),
                SelectableText(ai.accountId),
                _OwnAiDirectControls(
                  model: model,
                  ai: ai,
                  onOpenChat: onOpenOwnAiChat,
                  checkingAccount: checkingOwnAiAccount,
                ),
              ],
            ),
          ),
      ],
    ];
  }

  Widget _accountCard(BuildContext context) {
    final palette = JyPalette.of(context);
    final text = Theme.of(context).textTheme;
    final account = model.connectedAccountId;
    return Padding(
      padding: const EdgeInsets.only(bottom: JySpace.md),
      child: JySlab(
        padding: const EdgeInsets.all(JySpace.lg),
        child: Row(
          children: [
            JyAvatar(label: account ?? '?'),
            const SizedBox(width: JySpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    account ?? '未登录',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium?.copyWith(color: palette.text1),
                  ),
                  Text(
                    model.online ? '已连接宿主' : '未连接到宿主',
                    style: text.bodySmall?.copyWith(color: palette.text3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
            _accountCard(context),
            const JySectionHeader(title: '隐私与安全'),
            JyGroup(
              children: [
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
                ListTile(
                  key: const Key('open-device-sessions'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.devices_outlined),
                  title: const Text('设备会话'),
                  subtitle: const Text('查看已登录设备，或远程下线'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) {
                        final runtime = model;
                        final connection =
                            runtime is ClientRuntime &&
                                runtime.authenticated &&
                                !runtime.locked
                            ? runtime.connection
                            : null;
                        final api = connection == null
                            ? null
                            : DeviceSessionsApi(connection);
                        return DeviceSessionsScreen(
                          listDevices: api?.listDevices,
                          revokeDevice: api?.revokeDevice,
                          session: api == null ? null : model,
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: JySpace.sm),
            if (model is ClientRuntime)
              OwnerRuleGreetingSettingsPanel(
                onOpen: model.authenticated && !model.locked
                    ? () => _openGreetingStop(context)
                    : null,
              ),
            if (_android &&
                model is ClientRuntime &&
                model.authenticated &&
                !model.locked) ...[
              const Divider(height: 32),
              const JySectionHeader(title: '我的 AI 配置'),
              const Text('查看每个 AI 使用的模型与 API、人格和活人感设置，或打开本机私聊。'),
              ListTile(
                key: const Key('open-android-ai-directory'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.smart_toy_outlined),
                title: const Text('选择 AI'),
                subtitle: const Text('模型与 API · 人格 · 活人感 · 私聊'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AndroidAiDirectoryScreen(
                      model: model,
                      onOpenAi: (ai, interaction) => _openAiConfig(
                        context,
                        androidAi: ai,
                        renderedInteraction: interaction,
                      ),
                      onOpenPrivateChat: (ai, interaction) =>
                          _openPrivateChat(context, ai, interaction),
                    ),
                  ),
                ),
              ),
            ],
            const Divider(height: 32),
            const JySectionHeader(title: '通用'),
            SwitchListTile(
              title: const Text('开机自启动'),
              subtitle: const Text('由当前设备的平台能力决定是否可用'),
              value: model.autoStart,
              onChanged: model.busy ? null : model.setAutoStart,
            ),
            const SizedBox(height: 16),
            const JySectionHeader(title: '外观'),
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
            _FontScaleControl(model: model),
            const Text('此设置同时应用于导航、消息和输入区域。'),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('reduce-motion'),
              contentPadding: EdgeInsets.zero,
              title: const Text('减少动效'),
              subtitle: const Text('关闭位移、缩放和弹簧动画，只保留不超过 120ms 的淡入淡出'),
              value: model.reduceMotion,
              onChanged: model.busy ? null : model.setReduceMotion,
            ),
            const Divider(height: 32),
            const JySectionHeader(title: '开发者'),
            Text('只读检查', style: Theme.of(context).textTheme.labelLarge),
            const Text('以下入口只读展示宿主安全元数据，不代表可用、已授权或已清理。'),
            const SizedBox(height: 4),
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
            ListTile(
              key: const Key('open-attachments-list'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.attach_file_outlined),
              title: const Text('附件列表'),
              subtitle: const Text(
                '只读列出当前账号附件元数据（类型/大小/状态/会话）；'
                '不显示、不存储提取正文或文件字节，不执行清理或删除',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final runtime = model;
                final connection = runtime is ClientRuntime
                    ? runtime.connection
                    : null;
                AttachmentLister? listAttachments;
                if (connection != null) {
                  final api = AttachmentApi(connection);
                  listAttachments =
                      ({
                        String? conversationId,
                        required int limit,
                        DateTime? before,
                      }) => api.listAttachments(
                        conversationId: conversationId,
                        limit: limit,
                        before: before,
                      );
                }
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AttachmentsListScreen(listAttachments: listAttachments),
                  ),
                );
              },
            ),
            ListTile(
              key: const Key('open-attachment-viewer'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.description_outlined),
              title: const Text('附件元数据'),
              subtitle: const Text(
                '按附件标识只读查看单条元数据（需显式输入 attachmentId）；'
                '不显示、不存储提取正文或文件字节',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final runtime = model;
                final connection = runtime is ClientRuntime
                    ? runtime.connection
                    : null;
                Future<AttachmentMetadata> Function(String attachmentId)?
                readAttachment;
                if (connection != null) {
                  final api = AttachmentApi(connection);
                  readAttachment = api.readAttachment;
                }
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AttachmentsScreen(readAttachment: readAttachment),
                  ),
                );
              },
            ),
            ListTile(
              key: const Key('open-voice-profile'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.graphic_eq_outlined),
              title: const Text('语音音色'),
              subtitle: const Text(
                '只读查看某 AI 的音色档案（provider/model/voiceId/revision）。'
                '需显式输入 AI 档案 id：宿主按档案而非账户寻址，客户端不做推断；'
                '仅元数据，不代表可用、已授权或可发起语音。',
              ),
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
              key: const Key('open-voice-call-list'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.call_outlined),
              title: const Text('语音通话列表'),
              subtitle: const Text(
                '只读列出当前账号发起的通话元数据（状态/AI/对端/时间戳）。'
                '不接听、不结束、不播放音频，也不显示转写正文',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final runtime = model;
                final connection = runtime is ClientRuntime
                    ? runtime.connection
                    : null;
                VoiceCallLister? listCalls;
                if (connection != null) {
                  final api = VoiceCallApi(connection);
                  listCalls =
                      ({
                        String? status,
                        required int limit,
                        DateTime? before,
                      }) => api.listCalls(
                        status: status,
                        limit: limit,
                        before: before,
                      );
                }
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => VoiceCallListScreen(listCalls: listCalls),
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
              key: const Key('open-model-diagnostics'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.insights_outlined),
              title: const Text('模型能力与预算诊断'),
              subtitle: const Text(
                '只读查看已保存 provider 的模型目录、今日已记录用量（pending 标为未知）、'
                '滚动 7 个记录日趋势与已配置上限；需主动请求，不自动重试，'
                '不写绑定/预算、不代表模型可用或预算获批',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) {
                    final runtime = model;
                    final connection =
                        runtime is ClientRuntime &&
                            runtime.authenticated &&
                            !runtime.locked
                        ? runtime.connection
                        : null;
                    final api = connection == null
                        ? null
                        : ModelDiagnosticsApi(connection);
                    // Profile ids are not account ids; the page does not infer one.
                    return ModelDiagnosticsScreen(
                      session: api == null ? null : model,
                      readCatalog: api?.readModelCatalog,
                      readTodayUsage: api?.readTodayUsage,
                      readRolling7Trend: api?.readRolling7Trend,
                      readBudget: api?.readBudget,
                    );
                  },
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
                final filePreview = _captureFilePreview(model);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    // Keep the existing export/import gates live. Local preview
                    // callbacks stay on the original session for this route.
                    builder: (_) => ListenableBuilder(
                      listenable: model,
                      builder: (_, _) =>
                          lifecycleScreenFor(model, filePreview: filePreview),
                    ),
                  ),
                );
              },
            ),
            ListTile(
              key: const Key('open-message-search'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.manage_search_outlined),
              title: const Text('消息搜索'),
              subtitle: const Text(
                '按关键词显式搜索宿主已存消息（会话/发送者/类型/序号/摘要）；'
                '不建立客户端索引、不排序不评分，也不保证覆盖全部历史',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) {
                    final runtime = model;
                    final connection =
                        runtime is ClientRuntime &&
                            runtime.authenticated &&
                            !runtime.locked
                        ? runtime.connection
                        : null;
                    return SearchScreen(
                      search: connection == null
                          ? null
                          : SearchApi(connection).searchMessages,
                      session: connection == null ? null : model,
                    );
                  },
                ),
              ),
            ),
            const Divider(height: 24),
            Text('AI 运行配置编辑', style: Theme.of(context).textTheme.labelLarge),
            const Text('以下入口会修改配置；api_key 遮蔽输入，绝不明文回显或记录。'),
            const SizedBox(height: 4),
            ListTile(
              key: const Key('open-ai-config-write'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('AI 运行配置'),
              subtitle: const Text(
                '编辑人格/Provider/聊天绑定/预算；api_key 遮蔽输入、只显示掩码，绝不回显或记录密钥',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openAiConfig(context),
            ),
            const Divider(height: 32),
            ..._ownAiSection(context),
          ],
        ),
      ),
    ],
  );
}

/// Completes the next time [listenable] notifies its listeners.
Future<void> _nextNotification(Listenable listenable) {
  final completer = Completer<void>();
  void listener() {
    listenable.removeListener(listener);
    completer.complete();
  }

  listenable.addListener(listener);
  return completer.future;
}

/// Font size slider with a live sample. Dragging only previews the size; the
/// value is saved once, when the drag (or a key press) ends.
class _FontScaleControl extends StatefulWidget {
  const _FontScaleControl({required this.model});

  final ShellViewModel model;

  @override
  State<_FontScaleControl> createState() => _FontScaleControlState();
}

class _FontScaleControlState extends State<_FontScaleControl> {
  static const _min = 0.85;
  static const _max = 1.5;

  /// The dragged or released value, until the model has saved it.
  double? _pending;

  /// Bumped by every drag and save, so a superseded save neither runs late nor
  /// clears [_pending].
  int _generation = 0;

  Future<void> _save(double value) async {
    final model = widget.model;
    final generation = ++_generation;
    // The runtime drops a call made while another operation holds the model
    // busy, so wait until it is idle rather than lose the user's choice. The
    // wait outlives this screen, so leaving settings straight away still saves.
    while (model.busy) {
      await _nextNotification(model);
      if (generation != _generation) {
        return;
      }
    }
    try {
      await model.setFontScale(value);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _pending = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final model = widget.model;
    final value = _pending ?? model.fontScale;
    final percent = '${(value * 100).round()}%';
    final sample = theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16);
    // The shell already scales all text by model.fontScale, so scale the sample
    // by the ratio to show `value` without applying the scale twice.
    final ratio = model.fontScale > 0 ? value / model.fontScale : 1.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('字体大小 · $percent'),
        MergeSemantics(
          child: Semantics(
            label: '字体大小',
            child: Slider(
              value: value.clamp(_min, _max),
              min: _min,
              max: _max,
              divisions: 13,
              label: percent,
              // Announce the size itself, not the thumb position (100% read
              // as 23%).
              semanticFormatterCallback: (v) => '${(v * 100).round()}%',
              // Stays enabled while the model is busy; _save waits instead.
              onChangeStart: (_) => _generation++,
              onChanged: (v) => setState(() => _pending = v),
              onChangeEnd: (v) {
                setState(() => _pending = v);
                _save(v);
              },
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Text(
              '预览：消息和输入框中的文字会显示成这样。',
              key: const Key('font-scale-preview'),
              style: sample.copyWith(fontSize: (sample.fontSize ?? 16) * ratio),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _OwnAiDirectControls extends StatelessWidget {
  const _OwnAiDirectControls({
    required this.model,
    required this.ai,
    required this.onOpenChat,
    required this.checkingAccount,
  });
  final ShellViewModel model;
  final ShellOwnedAi ai;
  final Future<void> Function(BuildContext, String)? onOpenChat;
  final String? checkingAccount;

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
            if (ready &&
                state.enabled == true &&
                state.conversationId?.isNotEmpty == true &&
                onOpenChat != null)
              TextButton(
                key: Key('own-ai-direct-chat-${ai.accountId}'),
                onPressed: available && checkingAccount == null
                    ? () => onOpenChat!(context, ai.accountId)
                    : null,
                child: Text(
                  checkingAccount == ai.accountId ? '正在核对私聊…' : '打开私聊',
                ),
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
