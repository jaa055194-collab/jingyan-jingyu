import 'package:flutter/foundation.dart' show mapEquals;
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../net/ai_config_write_api.dart';
import '../../net/host_connection.dart';
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
import '../../ui/ui.dart';
import 'ai_config_problem_line.dart';
import 'owner_auto_memory_section.dart';
import 'owner_memory_notes_section.dart';
import 'owner_model_proactive_card.dart';
import 'owner_reply_preferences_section.dart';
import 'owner_rule_greeting_card.dart';
import 'owner_social_level_section.dart';
import 'persona_card_import.dart';
import 'persona_file_picker.dart';
import 'persona_history_screen.dart';

part 'android_ai_config_details.dart';

/// Editor group whose write produced the current status; `null` keeps the
/// status at page level (top of the page).
enum _WriteGroup { persona, provider, binding, budget }

/// Read-write "AI 运行配置" hub for one owned AI.
///
/// Existing persona, provider, binding and budget writes use [AiConfigWriter].
/// Owner reply preferences use their own explicit, scoped authorization route.
/// The API key
/// is entered through an obscured field and is never echoed; provider responses
/// only show the host-masked `key_mask`. No secrets are logged or rendered.
class AiConfigEditor extends StatefulWidget {
  const AiConfigEditor({
    super.key,
    this.writer,
    this.resolveProfileId,
    this.readCatalog,
    this.readPersonaHistory,
    this.replyPreferences,
    this.ruleGreeting,
    this.memoryNotes,
    this.autoMemory,
    this.modelProactive,
    this.socialLevel,
    this.personaFilePicker,
    this.androidDetails,
    this.session,
    this.ownedAiAccountIds = const <String>[],
  });

  final AiConfigWriter? writer;
  final Future<String> Function(String aiAccountId)? resolveProfileId;
  final Future<DiagnosticsRead<ModelCatalog>> Function(String)? readCatalog;

  /// Read-only persona history for a profile already resolved by this editor.
  final PersonaHistoryLoader? readPersonaHistory;

  final OwnerReplyPreferencesApi? replyPreferences;
  final OwnerRuleGreetingApi? ruleGreeting;
  final OwnerMemoryNotesApi? memoryNotes;

  /// Default-off auto chat-history memory for the owner's own private chat.
  final OwnerAutoMemoryApi? autoMemory;

  /// Default-off model-driven proactive contact to the owner's own private chat.
  final OwnerModelProactiveApi? modelProactive;

  /// Android-only owner social level. It never grants proactive contact itself.
  final OwnerSocialLevelApi? socialLevel;

  /// Explicit local persona-card file read. Null disables the file entry only;
  /// pasted JSON remains available. Import always fills the form and never
  /// writes to the host.
  final PersonaFilePicker? personaFilePicker;

  /// Android Settings pins one owned AI. Registration is deferred until the
  /// user explicitly requests its saved configuration.
  final ({
    String aiLabel,
    Future<OwnedAiProfileIdentity> Function(String) resolveIdentity,
    OwnerAiReadinessApi readiness,
  })?
  androidDetails;

  /// The Settings route captures the original account, epoch and connection.
  final ({ShellViewModel model, bool Function() isCurrent})? session;
  final List<String> ownedAiAccountIds;

  @override
  State<AiConfigEditor> createState() => _AiConfigEditorState();
}

class _AiConfigEditorState extends _AiConfigEditorBase
    with _AndroidAiConfigDetails {}

abstract class _AiConfigEditorBase extends State<AiConfigEditor> {
  Widget _buildAndroid(BuildContext context);
  void _clearAndroidDetails();
  void _invalidateAndroidModels();

  late final _pinnedAndroidDetails = widget.androidDetails;
  bool get _isAndroidDetails => _pinnedAndroidDetails != null;
  bool get _androidCanContactHost => _session?.model.online ?? true;

  String? _selected;
  String? _profileId;
  bool _resolving = false;
  bool _busy = false;
  String? _status;
  bool _statusError = false;

  /// 写入状态显示在哪一组；null 表示页级状态，显示在页顶。
  _WriteGroup? _statusGroup;
  late final ({ShellViewModel model, bool Function() isCurrent})? _session;
  bool _sessionLost = false;
  int _profileGeneration = 0;
  int _proactiveGeneration = 0;
  int _catalogGeneration = 0;
  bool _catalogLoading = false;
  String? _catalogNotice;
  List<String> _catalogModels = const [];
  String? _copiedModel;
  String? _importNotice;
  String? _importError;
  bool _importing = false;
  int _importGeneration = 0;

  final _p0 = TextEditingController();
  final _p1 = TextEditingController();
  final _p2 = TextEditingController();
  final _personaVersion = TextEditingController();
  final _personaReason = TextEditingController();
  final _provName = TextEditingController();
  final _provBaseUrl = TextEditingController();
  final _provApiKey = TextEditingController();
  final _provCaps = TextEditingController();
  final _provId = TextEditingController();
  final _bindProvider = TextEditingController();
  final _bindModel = TextEditingController();
  final _budgetDaily = TextEditingController();
  final _budgetOffset = TextEditingController();
  final _budgetLayers = TextEditingController();
  final _budgetCaps = TextEditingController();

  Iterable<TextEditingController> get _controllers => [
    _p0,
    _p1,
    _p2,
    _personaVersion,
    _personaReason,
    _provName,
    _provBaseUrl,
    _provApiKey,
    _provCaps,
    _provId,
    _bindProvider,
    _bindModel,
    _budgetDaily,
    _budgetOffset,
    _budgetLayers,
    _budgetCaps,
  ];

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _session?.model.addListener(_onSessionChanged);
    if (widget.ownedAiAccountIds.isNotEmpty &&
        (!_isAndroidDetails || widget.ownedAiAccountIds.length == 1)) {
      _selected = widget.ownedAiAccountIds.first;
    }
    if (!_sessionMatches) {
      _invalidateSession();
    } else if (!_isAndroidDetails && _selected != null) {
      _resolve();
    }
  }

  @override
  void didUpdateWidget(covariant AiConfigEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sessionLost && !_sessionMatches) _invalidateSession();
  }

  @override
  void dispose() {
    _session?.model.removeListener(_onSessionChanged);
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _sessionMatches {
    final session = _session;
    final ai = _selected;
    return widget.session == session &&
        widget.androidDetails == _pinnedAndroidDetails &&
        (!_isAndroidDetails ||
            (widget.ownedAiAccountIds.length == 1 &&
                widget.ownedAiAccountIds.single == ai)) &&
        (session == null ||
            session.isCurrent() &&
                (ai == null ||
                    session.model.ownAiAccounts.any(
                      (row) => row.accountId == ai && !row.disabled,
                    )));
  }

  void _invalidateSession() {
    _sessionLost = true;
    _selected = null;
    _profileId = null;
    _status = null;
    _copiedModel = null;
    _importNotice = null;
    _importError = null;
    _importing = false;
    _importGeneration++;
    _resetCatalog();
    if (_isAndroidDetails) _clearAndroidDetails();
    for (final controller in _controllers) {
      controller.clear();
    }
  }

  void _onSessionChanged() {
    // Stop the old route even if the app unlocks again before the next frame.
    if (mounted && !_sessionLost && !_sessionMatches) {
      setState(_invalidateSession);
    }
  }

  Widget? _ownerReplyPreferences(int generation) {
    final api = widget.replyPreferences;
    final selected = _selected;
    final profile = _profileId;
    final session = _session;
    if (api == null || selected == null || profile == null || session == null) {
      return null;
    }
    return ListenableBuilder(
      listenable: session.model,
      builder: (_, _) => OwnerReplyPreferencesSection(
        key: ValueKey((api, generation, selected, profile)),
        api: api,
        profile: profile,
        isCurrent: () =>
            mounted &&
            !_sessionLost &&
            _sessionMatches &&
            identical(api, widget.replyPreferences) &&
            _selected == selected &&
            _profileId == profile &&
            _profileGeneration == generation,
        canContactHost: () => session.model.online && !_busy,
      ),
    );
  }

  Widget? _ownerRuleGreeting(int generation) {
    final proactive = _proactiveGeneration;
    final api = widget.ruleGreeting;
    final selected = _selected;
    final profile = _profileId;
    final session = _session;
    if (api == null || selected == null || profile == null || session == null) {
      return null;
    }
    return ListenableBuilder(
      listenable: session.model,
      builder: (_, _) => OwnerRuleGreetingCard(
        key: ValueKey((api, generation, selected, profile, proactive)),
        api: api,
        profileId: profile,
        aiLabel:
            session.model.ownAiAccounts
                .where((ai) => ai.accountId == selected)
                .firstOrNull
                ?.displayName ??
            selected,
        isCurrent: () =>
            mounted &&
            !_sessionLost &&
            _sessionMatches &&
            identical(api, widget.ruleGreeting) &&
            _selected == selected &&
            _profileId == profile &&
            _profileGeneration == generation &&
            _proactiveGeneration == proactive,
        canContactHost: () => session.model.online && !_busy,
      ),
    );
  }

  Widget? _ownerMemoryNotes(int generation) {
    final api = widget.memoryNotes;
    final selected = _selected;
    final profile = _profileId;
    final session = _session;
    if (api == null || selected == null || profile == null || session == null) {
      return null;
    }
    return ListenableBuilder(
      listenable: session.model,
      builder: (_, _) => OwnerMemoryNotesSection(
        key: ValueKey((api, generation, selected, profile)),
        api: api,
        profile: profile,
        aiLabel:
            session.model.ownAiAccounts
                .where((ai) => ai.accountId == selected)
                .firstOrNull
                ?.displayName ??
            selected,
        isCurrent: () =>
            mounted &&
            !_sessionLost &&
            _sessionMatches &&
            identical(api, widget.memoryNotes) &&
            _selected == selected &&
            _profileId == profile &&
            _profileGeneration == generation,
        canContactHost: () => session.model.online && !_busy,
      ),
    );
  }

  Widget? _ownerAutoMemory(int generation) {
    final api = widget.autoMemory;
    final selected = _selected;
    final profile = _profileId;
    final session = _session;
    if (api == null || selected == null || profile == null || session == null) {
      return null;
    }
    return ListenableBuilder(
      listenable: session.model,
      builder: (_, _) => OwnerAutoMemorySection(
        key: ValueKey((api, generation, selected, profile)),
        api: api,
        profile: profile,
        aiLabel:
            session.model.ownAiAccounts
                .where((ai) => ai.accountId == selected)
                .firstOrNull
                ?.displayName ??
            selected,
        isCurrent: () =>
            mounted &&
            !_sessionLost &&
            _sessionMatches &&
            identical(api, widget.autoMemory) &&
            _selected == selected &&
            _profileId == profile &&
            _profileGeneration == generation,
        canContactHost: () => session.model.online && !_busy,
      ),
    );
  }

  Widget? _ownerModelProactive(int generation) {
    final proactive = _proactiveGeneration;
    final api = widget.modelProactive;
    final selected = _selected;
    final profile = _profileId;
    final session = _session;
    if (api == null || selected == null || profile == null || session == null) {
      return null;
    }
    return ListenableBuilder(
      listenable: session.model,
      builder: (_, _) => OwnerModelProactiveCard(
        key: ValueKey((api, generation, selected, profile, proactive)),
        api: api,
        profileId: profile,
        aiLabel:
            session.model.ownAiAccounts
                .where((ai) => ai.accountId == selected)
                .firstOrNull
                ?.displayName ??
            selected,
        isCurrent: () =>
            mounted &&
            !_sessionLost &&
            _sessionMatches &&
            identical(api, widget.modelProactive) &&
            _selected == selected &&
            _profileId == profile &&
            _profileGeneration == generation &&
            _proactiveGeneration == proactive,
        canContactHost: () => session.model.online && !_busy,
      ),
    );
  }

  bool _checkSession() {
    _onSessionChanged();
    return mounted && !_sessionLost;
  }

  bool get _ready =>
      !_sessionLost &&
      _sessionMatches &&
      widget.writer != null &&
      _selected != null &&
      _profileId != null &&
      (!_isAndroidDetails || _androidCanContactHost) &&
      !_resolving &&
      !_busy;

  Future<void> _resolve() async {
    if (!_checkSession()) return;
    final generation = ++_profileGeneration;
    final account = _selected;
    final resolve = widget.resolveProfileId;
    if (account == null || resolve == null) {
      setState(() {
        _profileId = null;
        _resolving = false;
      });
      return;
    }
    setState(() {
      _resolving = true;
      _profileId = null;
    });
    try {
      final profile = await resolve(account);
      if (!_checkSession() || generation != _profileGeneration) return;
      setState(() {
        _profileId = profile;
        _resolving = false;
      });
    } catch (_) {
      if (!_checkSession() || generation != _profileGeneration) return;
      setState(() {
        _profileId = null;
        _resolving = false;
        _status = '无法解析该 AI 档案；请稍后重试或重新选择；不会自动重试';
        _statusError = true;
        _statusGroup = null;
      });
    }
  }

  void _select(String? account) {
    if (!_checkSession() || _busy || account == null || account == _selected) {
      return;
    }
    setState(() {
      _selected = account;
      _status = null;
      _profileId = null;
      _resetCatalog();
      _clearCopiedModel();
      // Imported or typed persona text belongs to one AI only; never carry it
      // into another AI where it could be written by the next explicit click.
      _p0.clear();
      _p1.clear();
      _p2.clear();
      _importNotice = null;
      _importError = null;
      _importGeneration++;
    });
    _resolve();
  }

  void _resetCatalog() {
    _catalogGeneration++;
    _catalogLoading = false;
    _catalogNotice = null;
    _catalogModels = const [];
  }

  void _clearCopiedModel() {
    if (_copiedModel == _bindModel.text) _bindModel.clear();
    _copiedModel = null;
  }

  void _changeBindingProvider(String _) {
    if (!_checkSession()) return;
    setState(() {
      _resetCatalog();
      _clearCopiedModel();
    });
  }

  void _changeBindingModel(String _) {
    if (!_checkSession()) return;
    setState(() => _copiedModel = null);
  }

  Future<void> _loadCatalog(int generation) async {
    final read = widget.readCatalog;
    final provider = _bindProvider.text.trim();
    if (!_checkSession() ||
        !_ready ||
        read == null ||
        provider.isEmpty ||
        _catalogLoading ||
        generation != _catalogGeneration) {
      return;
    }
    final request = ++_catalogGeneration;
    setState(() {
      _catalogLoading = true;
      _catalogNotice = null;
      _catalogModels = const [];
    });
    DiagnosticsRead<ModelCatalog> result;
    try {
      result = await read(provider);
    } catch (_) {
      result = const DiagnosticsRead.unknown();
    }
    if (!_checkSession() ||
        request != _catalogGeneration ||
        provider != _bindProvider.text.trim()) {
      return;
    }
    setState(() {
      _catalogLoading = false;
      _catalogModels = result.value?.models ?? const [];
      _catalogNotice = switch (result.status) {
        DiagnosticsReadStatus.loaded =>
          _catalogModels.isEmpty ? '目录为空' : '目录 · ${_catalogModels.length} 个模型',
        DiagnosticsReadStatus.notFound => '未找到已保存的 Provider',
        DiagnosticsReadStatus.denied => '无权限读取目录',
        DiagnosticsReadStatus.unavailable => '目录暂不可读',
        DiagnosticsReadStatus.unconfigured => '目录未配置',
        DiagnosticsReadStatus.unknown => '无法验证目录',
      };
    });
  }

  void _copyCatalogModel(String model, int generation) {
    if (!_checkSession() ||
        !_ready ||
        generation != _catalogGeneration ||
        !_catalogModels.contains(model)) {
      return;
    }
    setState(() {
      _copiedModel = model;
      _bindModel.text = model;
    });
  }

  String _failureText(HostRequestException error) =>
      switch (error.failure.code) {
        FailureCode.unauthenticated || FailureCode.forbidden => '未认证或无权限',
        FailureCode.invalidArgument => '请求被拒绝（参数或地址无效）',
        FailureCode.rateLimited => '请求过于频繁，请稍后再试',
        FailureCode.conflict => '状态冲突，请刷新后重试',
        FailureCode.modelUnavailable => '能力不可用',
        _ => '操作失败或结果未知；不会自动重试',
      };

  /// 写入结果：「成功」或「失败/未知」，下面一行是说明。
  Widget? _groupStatus(_WriteGroup group) =>
      _status != null && _statusGroup == group ? _writeStatusBlock() : null;

  Widget _writeStatusBlock() {
    final palette = JyPalette.of(context);
    final color = _statusError ? palette.danger : palette.success;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Padding(
        key: const Key('ai-config-write-status'),
        padding: const EdgeInsets.symmetric(vertical: JySpace.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _statusError ? Icons.error_outline : Icons.check_circle_outline,
              key: const Key('ai-config-write-icon'),
              color: color,
            ),
            const SizedBox(width: JySpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _statusError ? '失败/未知' : '成功',
                    key: const Key('ai-config-write-state'),
                    style: TextStyle(color: color),
                  ),
                  Text(
                    _status!,
                    style: TextStyle(color: _statusError ? color : null),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _run<T>(
    Future<T> Function(AiConfigWriter writer) action,
    String success, {
    required _WriteGroup group,
    required int profileGeneration,
    void Function(T result)? onSuccess,
    bool modelMetadataMayChange = false,
  }) async {
    bool isCurrent() =>
        _checkSession() && profileGeneration == _profileGeneration;
    if (!isCurrent() || !_ready) return;
    setState(() {
      _busy = true;
      _status = null;
      _statusGroup = group;
      if (_isAndroidDetails && modelMetadataMayChange) {
        _invalidateAndroidModels();
      }
    });
    try {
      final result = await action(widget.writer!);
      if (!isCurrent()) return;
      setState(() {
        _status = success;
        _statusError = false;
        onSuccess?.call(result);
      });
    } catch (error) {
      if (!isCurrent()) return;
      setState(() {
        _status = switch (error) {
          HostRequestException() => _failureText(error),
          FormatException() => error.message,
          _ => '操作失败或结果未知；不会自动重试',
        };
        _statusError = true;
      });
    } finally {
      if (mounted && !_sessionLost) setState(() => _busy = false);
    }
  }

  Future<void> _importPersonaFile() async {
    final picker = widget.personaFilePicker;
    if (picker == null || !_checkSession() || !_ready || _importing) return;
    final generation = ++_importGeneration;
    setState(() {
      _importing = true;
      _importError = null;
    });
    PersonaFileImport? result;
    PersonaFileProblem? problem;
    try {
      result = await picker.pick();
    } on PersonaFileImportException catch (error) {
      problem = error.problem;
    } catch (_) {
      problem = PersonaFileProblem.unreadable;
    }
    if (!mounted || _sessionLost || generation != _importGeneration) return;
    if (problem != null) {
      setState(() {
        _importing = false;
        _importNotice = null;
        _importError = _fileProblemText(problem!);
      });
      return;
    }
    setState(() => _importing = false);
    if (result == null) return; // User cancelled: no change, no error.
    _applyPersonaImport(result.card, '文件「${result.name}」');
  }

  Future<void> _openPastePersona() async {
    if (!_checkSession() || !_ready || _importing) return;
    final card = await showDialog<PersonaCard>(
      context: context,
      builder: (_) => const _PersonaPasteDialog(),
    );
    if (card == null || !mounted || !_checkSession()) return;
    _applyPersonaImport(card, '粘贴内容');
  }

  /// Fills the existing persona text fields only. No writer is called here.
  void _applyPersonaImport(PersonaCard card, String source) {
    final String p0;
    final String p1;
    final String p2;
    try {
      p0 = card.formP0;
      p1 = card.formP1;
      p2 = card.formP2;
    } on FormatException catch (error) {
      setState(() {
        _importNotice = null;
        _importError = error.message;
      });
      return;
    }
    setState(() {
      _importError = null;
      _status = null;
      _p0.text = p0;
      _p1.text = p1;
      _p2.text = p2;
      _importNotice =
          '已导入：$source · ${card.summary} · '
          '仅填充表单，尚未写入宿主；请确认后点击“初始化人格”或“保存人格修改”。';
    });
  }

  String _fileProblemText(PersonaFileProblem problem) => switch (problem) {
    PersonaFileProblem.tooLarge => '所选文件超过 64 KiB；未读取、未改动表单。',
    PersonaFileProblem.invalid => '所选文件不是有效的人格卡 JSON；未改动表单。',
    PersonaFileProblem.unreadable => '无法读取所选文件；未改动表单。',
  };

  Map<String, String> _pairs(String raw) {
    final result = <String, String>{};
    for (final line in raw.split('\n')) {
      final text = line.trim();
      if (text.isEmpty) continue;
      final index = text.indexOf('=');
      if (index <= 0 || index == text.length - 1) {
        throw const FormatException('每行需为 key=value');
      }
      final key = text.substring(0, index).trim();
      final value = text.substring(index + 1).trim();
      if (key.isEmpty || value.isEmpty) {
        throw const FormatException('每行需为 key=value');
      }
      result[key] = value;
    }
    return result;
  }

  Map<String, int> _intPairs(String raw) {
    final result = <String, int>{};
    for (final line in raw.split('\n')) {
      final text = line.trim();
      if (text.isEmpty) continue;
      final index = text.indexOf('=');
      if (index <= 0 || index == text.length - 1) {
        throw const FormatException('每行需为 name=整数');
      }
      final name = text.substring(0, index).trim();
      final value = int.tryParse(text.substring(index + 1).trim());
      if (value == null || value < 0) {
        throw const FormatException('每行需为 name=非负整数');
      }
      result[name] = value;
    }
    return result;
  }

  Set<String> _caps(String raw) => {
    for (final part in raw.split(','))
      if (part.trim().isNotEmpty) part.trim(),
  };

  int _requireInt(TextEditingController controller, String label) {
    final value = int.tryParse(controller.text.trim());
    if (value == null) throw FormatException('$label 必须是整数');
    return value;
  }

  @override
  Widget build(BuildContext context) {
    if (_sessionLost) {
      return Scaffold(
        appBar: AppBar(title: const Text('AI 运行配置')),
        body: const Padding(
          key: Key('ai-config-session-invalid'),
          padding: EdgeInsets.all(16),
          child: Text('登录状态或 AI 账户已变更。请返回设置后重新打开编辑。'),
        ),
      );
    }
    if (_isAndroidDetails) {
      final model = _session?.model;
      return model == null
          ? _buildAndroid(context)
          : ListenableBuilder(
              listenable: model,
              builder: (_, _) => _buildAndroid(context),
            );
    }
    final canUse = widget.writer != null;
    final profileGeneration = _profileGeneration;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 运行配置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '编辑入口会写入宿主配置：人格、Provider、聊天绑定与预算。'
            'api_key 使用遮蔽输入，绝不回显或记录；Provider 结果只显示宿主掩码 key_mask。'
            '未知/失败不会自动重试。',
          ),
          const SizedBox(height: 12),
          if (widget.ownedAiAccountIds.isEmpty)
            const Text('没有可配置的自有 AI；请先在“我的 AI”刷新。')
          else
            InputDecorator(
              decoration: const InputDecoration(labelText: '选择自有 AI'),
              child: DropdownButton<String>(
                key: const Key('ai-config-write-select'),
                value: _selected,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final id in widget.ownedAiAccountIds)
                    DropdownMenuItem<String>(value: id, child: Text(id)),
                ],
                onChanged: _busy ? null : _select,
              ),
            ),
          const SizedBox(height: 8),
          Text(
            _resolving
                ? '正在解析 AI 档案…'
                : _profileId == null
                ? '尚未解析到 AI 档案；无法写入配置'
                : '档案：$_profileId',
          ),
          if (!canUse)
            const Padding(
              padding: EdgeInsets.only(top: JySpace.sm),
              child: AiConfigProblemLine.warning(
                '未连接宿主；无法编辑配置。',
                key: Key('ai-config-no-writer'),
              ),
            ),
          if (_status != null && _statusGroup == null) _writeStatusBlock(),
          const Divider(height: 32),
          ?_ownerReplyPreferences(profileGeneration),
          ?_ownerRuleGreeting(profileGeneration),
          ?_ownerMemoryNotes(profileGeneration),
          ?_ownerAutoMemory(profileGeneration),
          ?_ownerModelProactive(profileGeneration),
          _section(
            '人格',
            [
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const Key('persona-import-file'),
                    onPressed:
                        !_ready ||
                            _importing ||
                            widget.personaFilePicker == null
                        ? null
                        : _importPersonaFile,
                    icon: const Icon(Icons.upload_file_outlined),
                    label: Text(_importing ? '正在读取文件…' : '导入人格文件'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('persona-import-paste'),
                    onPressed: !_ready || _importing ? null : _openPastePersona,
                    icon: const Icon(Icons.content_paste_outlined),
                    label: const Text('粘贴人格 JSON'),
                  ),
                ],
              ),
              if (_importNotice != null)
                Padding(
                  key: const Key('persona-import-status'),
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_importNotice!),
                ),
              if (_importError != null)
                Padding(
                  key: const Key('persona-import-error'),
                  padding: const EdgeInsets.only(top: JySpace.sm),
                  child: AiConfigProblemLine(_importError!),
                ),
              const SizedBox(height: 8),
              _field('persona-p0', _p0, 'P0（key=value，每行一条）', lines: 3),
              _field('persona-p1', _p1, 'P1（key=value，每行一条）', lines: 3),
              _field('persona-p2', _p2, 'P2（key=value，每行一条）', lines: 3),
              Row(
                children: [
                  Expanded(
                    child: _field(
                      'persona-version',
                      _personaVersion,
                      '当前版本（修改时必填）',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _field('persona-reason', _personaReason, '修改原因'),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    key: const Key('persona-initialize'),
                    onPressed: !_ready
                        ? null
                        : () => _run(
                            group: _WriteGroup.persona,
                            (writer) {
                              final p0 = _pairs(_p0.text);
                              final p1 = _pairs(_p1.text);
                              final p2 = _pairs(_p2.text);
                              if (p0.isEmpty || p1.isEmpty || p2.isEmpty) {
                                throw const FormatException(
                                  '人格三层 p0/p1/p2 都必须非空',
                                );
                              }
                              return writer.initializePersona(
                                _profileId!,
                                p0: p0,
                                p1: p1,
                                p2: p2,
                              );
                            },
                            '人格已初始化',
                            profileGeneration: profileGeneration,
                          ),
                    child: const Text('初始化人格'),
                  ),
                  OutlinedButton(
                    key: const Key('persona-edit'),
                    onPressed: !_ready
                        ? null
                        : () => _run(
                            group: _WriteGroup.persona,
                            (writer) => writer.editPersona(
                              _profileId!,
                              expectedVersion: _requireInt(
                                _personaVersion,
                                '当前版本',
                              ),
                              reason: _personaReason.text.trim(),
                              p0: {..._pairs(_p0.text)},
                              p1: {..._pairs(_p1.text)},
                              p2: {..._pairs(_p2.text)},
                            ),
                            '人格已保存为新版本',
                            profileGeneration: profileGeneration,
                          ),
                    child: const Text('保存人格修改'),
                  ),
                ],
              ),
              ?_groupStatus(_WriteGroup.persona),
              _personaHistory(profileGeneration),
            ],
            helpKey: 'help-persona',
            group: _WriteGroup.persona,
            help:
                '人格三层：P0 核心（不可自改）、P1 风格（可自主迭代）、P2 情绪；'
                '初始化需三层全部非空，保存修改需当前版本与原因，历史可回滚。',
          ),
          ..._advancedSections(profileGeneration),
        ],
      ),
    );
  }

  List<Widget> _advancedSections(int profileGeneration) {
    final catalogGeneration = _catalogGeneration;
    final catalogModels = _catalogModels;
    return [
      _section(
        'Provider',
        [
          _field('provider-name', _provName, '名称'),
          _field('provider-base-url', _provBaseUrl, 'Base URL'),
          _field(
            'provider-api-key',
            _provApiKey,
            'API Key（遮蔽输入，仅提交给宿主）',
            obscure: true,
          ),
          _field('provider-capabilities', _provCaps, '能力（逗号分隔，如 chat）'),
          _field('provider-id', _provId, '已有 Provider ID（更新时填）'),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: const Key('provider-create'),
                onPressed: !_ready
                    ? null
                    : () => _createProvider(profileGeneration),
                child: const Text('新建 Provider'),
              ),
              OutlinedButton(
                key: const Key('provider-update'),
                onPressed: !_ready
                    ? null
                    : () => _updateProvider(profileGeneration),
                child: const Text('更新 Provider'),
              ),
            ],
          ),
          ?_groupStatus(_WriteGroup.provider),
        ],
        helpKey: 'help-provider',
        group: _WriteGroup.provider,
        help:
            'api_key 只经遮蔽字段提交给宿主，绝不回显、不记录；'
            '保存后宿主只返回掩码 key_mask（不是密钥），客户端不持有明文。',
      ),
      _section(
        '聊天绑定',
        [
          _field(
            'binding-provider',
            _bindProvider,
            'Provider ID',
            onChanged: _changeBindingProvider,
          ),
          _field(
            'binding-model',
            _bindModel,
            '模型 ID',
            onChanged: _changeBindingModel,
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const Key('binding-catalog-read'),
              onPressed:
                  !_ready ||
                      widget.readCatalog == null ||
                      _bindProvider.text.trim().isEmpty ||
                      _catalogLoading
                  ? null
                  : () => _loadCatalog(catalogGeneration),
              icon: const Icon(Icons.list_alt_outlined),
              label: Text(_catalogLoading ? '读取模型目录中…' : '读取已保存 Provider 模型'),
            ),
          ),
          if (_catalogNotice != null)
            Text(
              _catalogNotice!,
              key: const Key('binding-catalog-status'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (_catalogModels.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 176),
              child: ListView.builder(
                primary: false,
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: catalogModels.length,
                itemBuilder: (context, index) {
                  final model = catalogModels[index];
                  return ListTile(
                    key: Key('binding-catalog-model-$model'),
                    title: Text(
                      model,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: _copiedModel == model,
                    onTap: !_ready
                        ? null
                        : () => _copyCatalogModel(model, catalogGeneration),
                  );
                },
              ),
            ),
          if (_copiedModel != null)
            Text(
              '已填入模型 ID',
              key: const Key('binding-catalog-selection-status'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          FilledButton(
            key: const Key('binding-save'),
            onPressed: !_ready
                ? null
                : () {
                    if (catalogGeneration != _catalogGeneration) return;
                    _run(
                      group: _WriteGroup.binding,
                      (writer) => writer.setChatBinding(
                        _profileId!,
                        providerId: _bindProvider.text.trim(),
                        model: _bindModel.text.trim(),
                      ),
                      '聊天绑定已保存',
                      profileGeneration: profileGeneration,
                      modelMetadataMayChange: true,
                    );
                  },
            child: const Text('保存聊天绑定'),
          ),
          ?_groupStatus(_WriteGroup.binding),
        ],
        helpKey: 'help-binding',
        group: _WriteGroup.binding,
        help:
            '聊天绑定需要 Provider ID 与模型 ID同时提供；'
            '绑定到 chat 能力后该 AI 才能用于对话，未绑定不代表可用。',
      ),
      _section(
        '预算',
        [
          Row(
            children: [
              Expanded(
                child: _field('budget-daily', _budgetDaily, '每日 token 上限'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _field('budget-offset', _budgetOffset, '时区偏移（分钟）'),
              ),
            ],
          ),
          _field(
            'budget-layers',
            _budgetLayers,
            '分层上限（b0Life=0 等，五行）',
            lines: 5,
          ),
          _field('budget-caps', _budgetCaps, '能力上限（chat=0 等，七行）', lines: 7),
          FilledButton(
            key: const Key('budget-save'),
            onPressed: !_ready ? null : () => _saveBudget(profileGeneration),
            child: const Text('保存预算'),
          ),
          ?_groupStatus(_WriteGroup.budget),
        ],
        helpKey: 'help-budget',
        group: _WriteGroup.budget,
        help:
            '预算四字段：每日 token 上限、时区偏移（分钟）、分层限额（name=整数每行）、'
            '能力限额（name=整数每行）；保存后按本地时区切日，不代表已获批或已启用。',
      ),
    ];
  }

  Widget _personaHistory(int profileGeneration) {
    final profile = _profileId;
    final read = widget.readPersonaHistory;
    bool isCurrent() =>
        !_sessionLost &&
        _sessionMatches &&
        profile != null &&
        _profileId == profile &&
        _profileGeneration == profileGeneration;
    return PersonaHistorySection(
      key: ValueKey('persona-history-$profileGeneration-$profile'),
      isCurrent: isCurrent,
      readPage: profile == null || read == null
          ? null
          : (afterVersion, cancellation) => read(
              profile,
              afterVersion: afterVersion,
              cancellation: cancellation,
            ),
    );
  }

  Widget _section(
    String title,
    List<Widget> children, {
    String? helpKey,
    _WriteGroup? group,
    String? help,
  }) => Padding(
    key: group == null ? null : Key('ai-config-group-${group.name}'),
    padding: const EdgeInsets.only(bottom: JySpace.lg),
    child: JySlab(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(JySpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (help != null)
              Padding(
                key: helpKey == null ? null : Key(helpKey),
                padding: const EdgeInsets.only(top: 4),
                child: Text(help, style: Theme.of(context).textTheme.bodySmall),
              ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    ),
  );

  Widget _field(
    String key,
    TextEditingController controller,
    String label, {
    bool obscure = false,
    int lines = 1,
    ValueChanged<String>? onChanged,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      key: Key(key),
      controller: controller,
      obscureText: obscure,
      minLines: 1,
      maxLines: obscure ? 1 : lines,
      decoration: InputDecoration(labelText: label),
      onChanged: onChanged,
    ),
  );

  Future<void> _createProvider(int profileGeneration) => _run(
    group: _WriteGroup.provider,
    (writer) => writer.createProvider(
      name: _provName.text.trim(),
      baseUrl: _provBaseUrl.text.trim(),
      apiKey: _provApiKey.text,
      capabilities: _caps(_provCaps.text),
    ),
    'Provider 已保存',
    profileGeneration: profileGeneration,
    onSuccess: (result) {
      _status = 'Provider 已保存：${result.name} · 掩码 ${result.keyMask}（不是密钥）';
      _provApiKey.clear();
    },
  );

  Future<void> _updateProvider(int profileGeneration) => _run(
    group: _WriteGroup.provider,
    (writer) => writer.updateProvider(
      _provId.text.trim(),
      name: _provName.text.trim().isEmpty ? null : _provName.text.trim(),
      baseUrl: _provBaseUrl.text.trim().isEmpty
          ? null
          : _provBaseUrl.text.trim(),
      apiKey: _provApiKey.text.isEmpty ? null : _provApiKey.text,
      capabilities: _provCaps.text.trim().isEmpty
          ? null
          : _caps(_provCaps.text),
    ),
    'Provider 已更新（只显示掩码，不回显密钥）',
    profileGeneration: profileGeneration,
    modelMetadataMayChange: true,
    onSuccess: (_) => _provApiKey.clear(),
  );

  Future<void> _saveBudget(int profileGeneration) => _run(
    group: _WriteGroup.budget,
    (writer) {
      final layers = _intPairs(_budgetLayers.text);
      final caps = _intPairs(_budgetCaps.text);
      return writer.configureBudget(
        _profileId!,
        dailyTokens: _requireInt(_budgetDaily, '每日 token 上限'),
        layerLimits: layers,
        capabilityLimits: caps,
        offsetMinutes: _requireInt(_budgetOffset, '时区偏移'),
      );
    },
    '预算已保存',
    profileGeneration: profileGeneration,
  );
}

/// Local validation only: the dialog returns a parsed card; the editor fills
/// the existing form. Nothing here calls the writer or the host.
class _PersonaPasteDialog extends StatefulWidget {
  const _PersonaPasteDialog();

  @override
  State<_PersonaPasteDialog> createState() => _PersonaPasteDialogState();
}

class _PersonaPasteDialogState extends State<_PersonaPasteDialog> {
  final _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _apply() {
    final PersonaCard card;
    try {
      card = PersonaCard.parseText(_input.text);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    Navigator.of(context).pop(card);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Dialog(
      key: const Key('persona-import-paste-dialog'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('粘贴人格卡 JSON', style: text.titleMedium),
              const SizedBox(height: 4),
              Text(
                '格式固定为 PRIVATE_AI_PERSONA_1，顶层仅 format/p0/p1/p2；'
                'UTF-8 且不超过 64 KiB。导入只填充表单，不写入宿主。',
                style: text.bodySmall,
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('persona-import-paste-input'),
                controller: _input,
                minLines: 6,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: '人格卡 JSON',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Padding(
                  key: const Key('persona-import-paste-error'),
                  padding: const EdgeInsets.only(top: JySpace.sm),
                  child: AiConfigProblemLine(_error!),
                ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('persona-import-paste-cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    key: const Key('persona-import-paste-apply'),
                    onPressed: _apply,
                    child: const Text('校验并填入'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
