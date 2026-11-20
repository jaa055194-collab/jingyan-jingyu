import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../net/ai_config_write_api.dart';
import '../../net/host_connection.dart';
import '../../net/model_diagnostics_api.dart';

/// Read-write "AI 运行配置" hub for one owned AI.
///
/// It only performs the four explicit host writes (persona init/edit, provider
/// save, chat binding, budget) through an injected [AiConfigWriter]. The API key
/// is entered through an obscured field and is never echoed; provider responses
/// only show the host-masked `key_mask`. No secrets are logged or rendered.
class AiConfigEditor extends StatefulWidget {
  const AiConfigEditor({
    super.key,
    this.writer,
    this.resolveProfileId,
    this.readCatalog,
    this.session,
    this.ownedAiAccountIds = const <String>[],
  });

  final AiConfigWriter? writer;
  final Future<String> Function(String aiAccountId)? resolveProfileId;
  final Future<DiagnosticsRead<ModelCatalog>> Function(String)? readCatalog;

  /// The Settings route captures the original account, epoch and connection.
  final ({ShellViewModel model, bool Function() isCurrent})? session;
  final List<String> ownedAiAccountIds;

  @override
  State<AiConfigEditor> createState() => _AiConfigEditorState();
}

class _AiConfigEditorState extends State<AiConfigEditor> {
  String? _selected;
  String? _profileId;
  bool _resolving = false;
  bool _busy = false;
  String? _status;
  bool _statusError = false;
  late final ({ShellViewModel model, bool Function() isCurrent})? _session;
  bool _sessionLost = false;
  int _profileGeneration = 0;
  int _catalogGeneration = 0;
  bool _catalogLoading = false;
  String? _catalogNotice;
  List<String> _catalogModels = const [];
  String? _copiedModel;

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
    if (widget.ownedAiAccountIds.isNotEmpty) {
      _selected = widget.ownedAiAccountIds.first;
    }
    if (!_sessionMatches) {
      _invalidateSession();
    } else if (_selected != null) {
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
    _resetCatalog();
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

  Future<void> _run<T>(
    Future<T> Function(AiConfigWriter writer) action,
    String success, {
    required int profileGeneration,
    void Function(T result)? onSuccess,
  }) async {
    bool isCurrent() =>
        _checkSession() && profileGeneration == _profileGeneration;
    if (!isCurrent() || !_ready) return;
    setState(() {
      _busy = true;
      _status = null;
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
    final canUse = widget.writer != null;
    final profileGeneration = _profileGeneration;
    final catalogGeneration = _catalogGeneration;
    final catalogModels = _catalogModels;
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
              padding: EdgeInsets.only(top: 8),
              child: Text('未连接宿主；无法编辑配置。'),
            ),
          if (_status != null)
            Padding(
              key: const Key('ai-config-write-status'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _statusError ? '失败/未知' : '成功',
                    key: const Key('ai-config-write-state'),
                    style: TextStyle(
                      color: _statusError
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                  ),
                  Text(
                    _status!,
                    style: TextStyle(
                      color: _statusError
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 32),
          _section(
            '人格',
            [
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
            ],
            helpKey: 'help-persona',
            help:
                '人格三层：P0 核心（不可自改）、P1 风格（可自主迭代）、P2 情绪；'
                '初始化需三层全部非空，保存修改需当前版本与原因，历史可回滚。',
          ),
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
            ],
            helpKey: 'help-provider',
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
                  label: Text(
                    _catalogLoading ? '读取模型目录中…' : '读取已保存 Provider 模型',
                  ),
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
                          (writer) => writer.setChatBinding(
                            _profileId!,
                            providerId: _bindProvider.text.trim(),
                            model: _bindModel.text.trim(),
                          ),
                          '聊天绑定已保存',
                          profileGeneration: profileGeneration,
                        );
                      },
                child: const Text('保存聊天绑定'),
              ),
            ],
            helpKey: 'help-binding',
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
                onPressed: !_ready
                    ? null
                    : () => _saveBudget(profileGeneration),
                child: const Text('保存预算'),
              ),
            ],
            helpKey: 'help-budget',
            help:
                '预算四字段：每日 token 上限、时区偏移（分钟）、分层限额（name=整数每行）、'
                '能力限额（name=整数每行）；保存后按本地时区切日，不代表已获批或已启用。',
          ),
        ],
      ),
    );
  }

  Widget _section(
    String title,
    List<Widget> children, {
    String? helpKey,
    String? help,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
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
    onSuccess: (_) => _provApiKey.clear(),
  );

  Future<void> _saveBudget(int profileGeneration) => _run(
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
