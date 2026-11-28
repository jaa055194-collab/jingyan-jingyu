part of 'ai_config_editor.dart';

const _personaLayers = {'p0': 'P0 · 核心', 'p1': 'P1 · 风格', 'p2': 'P2 · 情绪'};

/// Android-only presentation. Profile selection, the original session guard
/// and the existing settings controls stay in the shared editor.
mixin _AndroidAiConfigDetails on _AiConfigEditorBase {
  final _personaAnchor = GlobalKey();
  final _alivenessAnchor = GlobalKey();
  OwnedAiProfileIdentity? _identity;
  ConfigurationRead<List<OwnerModelBinding>>? _bindings;
  Map<String, ConfigurationRead<OwnerProviderMetadata>> _providers = const {};
  bool _modelsChanged = false;
  String? _readNotice;
  ConfigurationReadStatus? _personaReadStatus;
  OwnerPersonaCard? _savedPersona;
  _AndroidPersonaDraft? _draft;
  String? _personaNotice;
  bool _personaError = false;

  @override
  void _clearAndroidDetails() {
    _identity = null;
    _bindings = null;
    _providers = const {};
    _savedPersona = null;
    _draft = null;
    _personaReadStatus = null;
    _personaNotice = null;
    _readNotice = null;
  }

  @override
  void _invalidateAndroidModels() {
    _bindings = null;
    _providers = const {};
    _modelsChanged = true;
  }

  bool get _onAndroidRoute =>
      mounted && ModalRoute.isCurrentOf(context) != false;

  bool _androidRequestCurrent(int generation) =>
      _checkSession() &&
      _profileGeneration == generation &&
      _onAndroidRoute &&
      _androidCanContactHost;

  bool _profileReadRefused(ConfigurationReadStatus status) {
    final notice = switch (status) {
      ConfigurationReadStatus.ownershipUnknown => '无法确认该 AI 的归属。请检查账号后重新读取。',
      ConfigurationReadStatus.denied => '未认证或无权读取该 AI 的配置。请检查权限后重新读取。',
      _ => null,
    };
    if (notice == null) return false;
    setState(() => _readNotice = notice);
    return true;
  }

  Future<void> _readAndroid() async {
    final details = _pinnedAndroidDetails!;
    final account = _selected;
    if (!_checkSession() ||
        !_onAndroidRoute ||
        !_androidCanContactHost ||
        _resolving ||
        _busy ||
        _draft != null ||
        account == null) {
      return;
    }
    final previousIdentity = _identity;
    final generation = ++_profileGeneration;
    setState(() {
      _clearAndroidDetails();
      _modelsChanged = false;
      _profileId = null;
      _resolving = true;
      _status = null;
      _resetCatalog();
      _clearCopiedModel();
    });
    try {
      // Only an explicit read can register. Refresh within the current pinned
      // route uses the known identity, which each readiness read revalidates.
      final identity =
          previousIdentity ?? await details.resolveIdentity(account);
      if (!_androidRequestCurrent(generation)) return;
      if (identity.accountId != account ||
          (_session != null &&
              identity.ownerAccountId != _session.model.connectedAccountId)) {
        throw const FormatException();
      }
      final persona = await details.readiness.readPersona(
        identity,
        retryAuthentication: false,
      );
      if (!_androidRequestCurrent(generation) ||
          _profileReadRefused(persona.status)) {
        return;
      }
      final bindings = await details.readiness.readBindings(
        identity,
        retryAuthentication: false,
      );
      if (!_androidRequestCurrent(generation) ||
          _profileReadRefused(bindings.status)) {
        return;
      }
      final providers = <String, ConfigurationRead<OwnerProviderMetadata>>{};
      // Resolve only the providers actually attached to chat/fast bindings.
      for (final id in <String>{
        for (final binding in bindings.value ?? const <OwnerModelBinding>[])
          if (binding.capability == 'chat' || binding.capability == 'chatFast')
            binding.providerId,
      }) {
        providers[id] = await details.readiness.readProvider(
          identity,
          id,
          retryAuthentication: false,
        );
        if (!_androidRequestCurrent(generation) ||
            _profileReadRefused(providers[id]!.status)) {
          return;
        }
      }
      setState(() {
        _identity = identity;
        _profileId = identity.profileId;
        _savedPersona = persona.value;
        _personaReadStatus = persona.status;
        _bindings = bindings;
        _providers = providers;
      });
    } catch (error) {
      if (!_androidRequestCurrent(generation)) return;
      setState(
        () => _readNotice =
            error is HostRequestException &&
                (error.failure.code == FailureCode.unauthenticated ||
                    error.failure.code == FailureCode.forbidden)
            ? '未认证或无权读取该 AI 的配置。'
            : '无法读取配置，可手动重试。',
      );
    } finally {
      if (mounted && !_sessionLost && _profileGeneration == generation) {
        setState(() {
          _resolving = false;
          if (_bindings == null && _readNotice == null) {
            _readNotice = '配置读取未完成，可手动重试。';
          }
        });
      }
    }
  }

  void _startAndroidPersona(OwnerPersonaCard? before) {
    if (!_checkSession() ||
        !_ready ||
        !_onAndroidRoute ||
        _draft != null ||
        !identical(before, _savedPersona) ||
        (before == null &&
            _personaReadStatus != ConfigurationReadStatus.personaMissing)) {
      return;
    }
    setState(() {
      _draft = _AndroidPersonaDraft(before);
      _personaNotice = null;
    });
    _showAndroidSection(_personaAnchor);
  }

  Future<void> _saveAndroidPersona(_AndroidPersonaDraft draft) async {
    final generation = _profileGeneration;
    final writer = widget.writer;
    final identity = _identity;
    if (!_androidRequestCurrent(generation) ||
        !_ready ||
        writer == null ||
        identity == null ||
        !identical(_draft, draft) ||
        !identical(_savedPersona, draft.before)) {
      return;
    }
    final Map<String, Map<String, String>> next;
    final reason = draft.reason.trim();
    try {
      next = draft.layers();
      if (draft.before != null && !_AndroidPersonaDraft.validValue(reason)) {
        throw const FormatException('请填写有效的修改原因。');
      }
    } on FormatException catch (error) {
      setState(() {
        _personaNotice = error.message;
        _personaError = true;
      });
      return;
    }
    final before = draft.before;
    final diff = <String, Map<String, String?>>{
      if (before != null)
        for (final layer in _personaLayers.keys)
          layer: _personaDifference(before.layers[layer]!, next[layer]!),
    };
    if (before != null && diff.values.every((layer) => layer.isEmpty)) {
      setState(() {
        _personaNotice = '人格内容没有变化。';
        _personaError = true;
      });
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _personaNotice = null;
    });
    try {
      if (before == null) {
        await writer.initializePersona(
          identity.profileId,
          p0: next['p0']!,
          p1: next['p1']!,
          p2: next['p2']!,
        );
      } else {
        await writer.editPersona(
          identity.profileId,
          expectedVersion: before.version,
          reason: reason,
          p0: diff['p0']!,
          p1: diff['p1']!,
          p2: diff['p2']!,
        );
      }
      if (!_androidRequestCurrent(generation)) return;
      // The shared writer does not return the new card. Never synthesize a
      // revision or continue editing from the old snapshot after a write.
      final result = await _pinnedAndroidDetails!.readiness.readPersona(
        identity,
        retryAuthentication: false,
      );
      if (!_androidRequestCurrent(generation)) return;
      final saved = result.value;
      if (saved == null ||
          saved.version != (before?.version ?? 0) + 1 ||
          !_personaLayers.keys.every(
            (layer) => mapEquals(saved.layers[layer], next[layer]),
          )) {
        _retirePersona('已提交，但未能核对保存后的版本。请重新读取配置。');
        return;
      }
      setState(() {
        _savedPersona = saved;
        _personaReadStatus = result.status;
        _draft = null;
        _personaNotice = before == null ? '人格已初始化。' : '人格已保存。';
        _personaError = false;
      });
    } catch (error) {
      if (!_androidRequestCurrent(generation)) return;
      _retirePersona(switch (error) {
        HostRequestException(failure: Failure(code: FailureCode.conflict)) =>
          '人格版本冲突。请重新读取配置后再编辑；未重试。',
        HostRequestException(
          failure: Failure(
            code: FailureCode.unauthenticated || FailureCode.forbidden,
          ),
        ) =>
          '未认证或无权保存人格。请重新读取配置。',
        HostRequestException(
          failure: Failure(code: FailureCode.invalidArgument),
        ) =>
          '宿主拒绝了人格修改。请重新读取配置。',
        _ => '保存结果未知。请重新读取配置确认；不会自动重试。',
      });
    } finally {
      if (mounted && !_sessionLost && _profileGeneration == generation) {
        if (identical(_draft, draft)) {
          _retirePersona('保存结果未确认。请重新读取配置；不会自动重试。');
        }
        setState(() => _busy = false);
        _showAndroidSection(_personaAnchor);
      }
    }
  }

  void _retirePersona(String notice) => setState(() {
    _savedPersona = null;
    _personaReadStatus = null;
    _draft = null;
    _personaNotice = notice;
    _personaError = true;
  });

  void _showAndroidSection(GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = key.currentContext;
      if (target != null && _onAndroidRoute && !_sessionLost) {
        Scrollable.ensureVisible(target, alignment: 0.02);
      }
    });
  }

  Widget? _ownerSocialLevel(int generation) {
    final api = widget.socialLevel;
    final profile = _profileId;
    if (api == null || profile == null || _session == null) return null;
    bool isCurrent() =>
        mounted &&
        !_sessionLost &&
        _sessionMatches &&
        identical(widget.socialLevel, api) &&
        _profileId == profile &&
        _profileGeneration == generation;
    return OwnerSocialLevelSection(
      key: ValueKey((api, profile, generation)),
      api: api,
      profileId: profile,
      isCurrent: isCurrent,
      canContactHost: () => _androidCanContactHost && !_busy,
      onSaved: () {
        // A level below L3 can revoke existing grants. Discard any cached
        // eligibility or pending review immediately; never renew a grant.
        if (isCurrent()) setState(() => _proactiveGeneration++);
      },
    );
  }

  @override
  Widget _buildAndroid(BuildContext context) {
    final theme = Theme.of(context);
    final generation = _profileGeneration;
    final controls = [
      ?_ownerSocialLevel(generation),
      ?_ownerReplyPreferences(generation),
      ?_ownerRuleGreeting(generation),
      ?_ownerModelProactive(generation),
    ];
    final online = _androidCanContactHost;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 配置')),
      body: SingleChildScrollView(
        key: const Key('android-ai-config-scroll'),
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _pinnedAndroidDetails!.aiLabel,
                  key: const Key('android-ai-config-name'),
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  _identity == null
                      ? '首次读取时，宿主会登记或查找此 AI 的档案。不会开启私聊授权。'
                      : '仅显示已保存配置，不代表模型可用或已获聊天授权。',
                  style: theme.textTheme.bodyMedium,
                ),
                if (!online) const Text('宿主未连接，当前无法读取或保存。'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      key: const Key('android-ai-config-read'),
                      onPressed:
                          online && !_resolving && !_busy && _draft == null
                          ? _readAndroid
                          : null,
                      icon: const Icon(Icons.refresh),
                      label: Text(
                        _resolving
                            ? '正在读取…'
                            : _identity == null
                            ? '读取配置'
                            : '重新读取',
                      ),
                    ),
                    TextButton(
                      key: const Key('android-ai-config-to-persona'),
                      onPressed: () => _showAndroidSection(_personaAnchor),
                      child: const Text('人格'),
                    ),
                    TextButton(
                      key: const Key('android-ai-config-to-aliveness'),
                      onPressed: () => _showAndroidSection(_alivenessAnchor),
                      child: const Text('活人感'),
                    ),
                  ],
                ),
                // Reserved so the page does not shift when a read or a save
                // starts or ends.
                SizedBox(
                  key: const Key('android-ai-config-progress'),
                  height: 4,
                  child: _resolving || _busy
                      ? const JyBusyIndicator(label: '正在读取或保存', linear: true)
                      : null,
                ),
                if (_readNotice case final notice?) AiConfigProblemLine(notice),
                const SizedBox(height: 16),
                _modelSummary(),
                KeyedSubtree(
                  key: _personaAnchor,
                  child: _androidPersona(generation),
                ),
                Text(
                  '活人感',
                  key: _alivenessAnchor,
                  style: theme.textTheme.titleLarge,
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Text(
                    '社交等级、回复偏好、规则问候和模型主动联系。各项分别读取与设置。',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Column(
                  key: const Key('android-ai-config-aliveness'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: controls.isEmpty
                      ? [
                          Text(
                            _identity == null
                                ? '请先读取此 AI 的配置。'
                                : '当前没有可读取的行为设置。',
                          ),
                        ]
                      : controls,
                ),
                const SizedBox(height: 16),
                if (_identity != null) ...[
                  const Divider(),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('高级配置'),
                    subtitle: const Text('Provider、聊天绑定、预算与记忆'),
                    children: [
                      if (_status != null && _statusGroup == null)
                        _writeStatusBlock(),
                      ..._advancedSections(generation),
                      ?_ownerMemoryNotes(generation),
                      ?_ownerAutoMemory(generation),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _modelSummary() {
    final read = _bindings;
    final rows = read?.value ?? const <OwnerModelBinding>[];
    final chat = rows.where((row) => row.capability == 'chat').firstOrNull;
    final fast = rows.where((row) => row.capability == 'chatFast').firstOrNull;
    return KeyedSubtree(
      key: const Key('android-ai-config-models'),
      child: _section('模型与 API', [
        if (_modelsChanged)
          const Text('配置可能已变更。请重新读取模型与 API 地址。')
        else if (read == null)
          Text(_resolving ? '读取模型绑定中…' : '尚未读取模型绑定。')
        else if (read.status != ConfigurationReadStatus.configurationPresent &&
            read.status != ConfigurationReadStatus.unconfigured)
          Text(
            read.status == ConfigurationReadStatus.denied
                ? '无权读取模型绑定。'
                : '模型绑定暂不可读。',
          )
        else ...[
          _modelRow('聊天模型', chat),
          if (fast != null) ...[
            const Divider(height: 24),
            _modelRow('快脑模型', fast),
          ],
        ],
      ]),
    );
  }

  Widget _modelRow(String label, OwnerModelBinding? model) {
    final provider = _providers[model?.providerId];
    final metadata = provider?.value;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: text.labelLarge),
        if (model == null)
          const Text('未绑定')
        else ...[
          SelectableText(model.model),
          const SizedBox(height: 4),
          if (metadata != null)
            SelectableText('API 地址：${metadata.baseUrl}', style: text.bodyMedium)
          else
            Text(
              provider?.status == ConfigurationReadStatus.denied
                  ? '无权读取 API 地址。'
                  : 'API 地址暂不可读。',
            ),
          if (metadata?.enabled == false) const Text('服务商已停用'),
        ],
      ],
    );
  }

  Widget _androidPersona(int generation) {
    final before = _savedPersona;
    final draft = _draft;
    final notice = _personaNotice;
    final editable = _ready && _onAndroidRoute;
    final text = Theme.of(context).textTheme;
    final missing =
        _personaReadStatus == ConfigurationReadStatus.personaMissing;
    return _section('人格', [
      if (before != null)
        Text(
          '版本 ${before.version} · ${before.locked ? '已锁定 P0/P1 自主修改' : '未锁定'}',
          style: text.bodyMedium,
        )
      else if (missing)
        const Text('该 AI 尚未初始化人格。')
      else if (notice == null)
        Text(switch (_personaReadStatus) {
          ConfigurationReadStatus.denied => '无权读取人格。',
          ConfigurationReadStatus.unknown => '人格暂不可读。',
          _ => _resolving ? '正在读取人格…' : '请先读取配置，使用宿主保存的当前版本。',
        }),
      if (draft == null) ...[
        if (before != null) ...[
          const SizedBox(height: 8),
          for (final entry in _personaLayers.entries)
            ExpansionTile(
              key: ValueKey((entry.key, before.version)),
              tilePadding: EdgeInsets.zero,
              title: Text(entry.value),
              subtitle: Text('${before.layers[entry.key]!.length} 项'),
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final field in before.layers[entry.key]!.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(field.key, style: text.labelLarge),
                        SelectableText(field.value),
                      ],
                    ),
                  ),
              ],
            ),
        ],
        if (before != null || missing)
          OutlinedButton.icon(
            key: const Key('android-persona-edit'),
            onPressed: editable ? () => _startAndroidPersona(before) : null,
            icon: Icon(missing ? Icons.add : Icons.edit_outlined),
            label: Text(missing ? '填写人格' : '编辑人格'),
          ),
        if (_profileId != null &&
            widget.readPersonaHistory != null &&
            before != null)
          _personaHistory(generation),
      ] else ...[
        const SizedBox(height: 8),
        Text('每层至少保留一项。删除只会在保存后提交，可取消本次编辑。', style: text.bodySmall),
        for (final entry in _personaLayers.entries)
          _personaLayerEditor(draft, entry.key, entry.value, editable),
        if (before != null)
          TextFormField(
            key: const Key('android-persona-reason'),
            initialValue: draft.reason,
            enabled: editable,
            decoration: const InputDecoration(labelText: '修改原因（必填）'),
            onChanged: (text) => draft.reason = text,
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              key: const Key('android-persona-save'),
              onPressed: editable ? () => _saveAndroidPersona(draft) : null,
              child: _SavingLabel(
                saving: _busy,
                label: _busy
                    ? '正在保存并核对…'
                    : missing
                    ? '初始化人格'
                    : '保存人格修改',
              ),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      setState(() {
                        _draft = null;
                        _personaNotice = null;
                      });
                      _showAndroidSection(_personaAnchor);
                    },
              child: const Text('取消'),
            ),
          ],
        ),
      ],
      if (notice != null)
        Padding(
          padding: const EdgeInsets.only(top: JySpace.sm),
          child: AiConfigNoticeLine(notice, problem: _personaError),
        ),
      if (draft == null && notice != null && _personaError)
        TextButton(
          onPressed: _ready ? _readAndroid : null,
          child: const Text('重新读取配置'),
        ),
    ]);
  }

  Widget _personaLayerEditor(
    _AndroidPersonaDraft draft,
    String layer,
    String title,
    bool editable,
  ) {
    final rows = draft.rows[layer]!;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          for (final row in rows)
            Padding(
              key: ObjectKey(row),
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (row.originalKey == null)
                    TextFormField(
                      initialValue: row.name,
                      enabled: editable,
                      decoration: const InputDecoration(labelText: '字段名'),
                      onChanged: (text) => row.name = text,
                    ),
                  TextFormField(
                    key: row.originalKey == null
                        ? null
                        : Key(
                            'android-persona-value-$layer-${row.originalKey}',
                          ),
                    initialValue: row.value,
                    enabled: editable,
                    minLines: 1,
                    maxLines: 6,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(
                      labelText: row.originalKey ?? '字段内容',
                    ),
                    onChanged: (text) => row.value = text,
                  ),
                  TextButton(
                    key: row.originalKey == null
                        ? null
                        : Key(
                            'android-persona-remove-$layer-${row.originalKey}',
                          ),
                    onPressed: !editable || rows.length == 1
                        ? null
                        : () => setState(() => rows.remove(row)),
                    child: const Text('删除此项'),
                  ),
                ],
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: editable
                  ? () => setState(() => rows.add(_AndroidPersonaRow()))
                  : null,
              icon: const Icon(Icons.add),
              label: const Text('添加字段'),
            ),
          ),
        ],
      ),
    );
  }
}

/// A button label that carries a small spinner while its action runs, so the
/// progress shows where the user pressed rather than off screen.
class _SavingLabel extends StatelessWidget {
  const _SavingLabel({required this.saving, required this.label});

  final bool saving;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (!saving) return Text(label);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: DefaultTextStyle.of(context).style.color,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(child: Text(label)),
      ],
    );
  }
}

Map<String, String?> _personaDifference(
  Map<String, String> before,
  Map<String, String> after,
) => {
  for (final key in {...before.keys, ...after.keys})
    if (before[key] != after[key]) key: after[key],
};

class _AndroidPersonaRow {
  _AndroidPersonaRow({this.originalKey, this.value = ''})
    : name = originalKey ?? '';
  final String? originalKey;
  String name;
  String value;
}

class _AndroidPersonaDraft {
  _AndroidPersonaDraft(this.before)
    : rows = {
        for (final layer in _personaLayers.keys)
          layer: before == null
              ? [_AndroidPersonaRow()]
              : [
                  for (final entry in before.layers[layer]!.entries)
                    _AndroidPersonaRow(
                      originalKey: entry.key,
                      value: entry.value,
                    ),
                ],
      };

  final OwnerPersonaCard? before;
  final Map<String, List<_AndroidPersonaRow>> rows;
  String reason = '';

  static final _keyControl = RegExp(r'[\x00-\x1f\x7f-\x9f]');
  static final _valueControl = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]');
  static bool validValue(String value) =>
      value.trim().isNotEmpty && !_valueControl.hasMatch(value);

  Map<String, Map<String, String>> layers() {
    final result = <String, Map<String, String>>{};
    for (final entry in rows.entries) {
      final values = <String, String>{};
      for (final row in entry.value) {
        if (row.name.trim().isEmpty ||
            row.name != row.name.trim() ||
            _keyControl.hasMatch(row.name) ||
            values.containsKey(row.name) ||
            !validValue(row.value)) {
          throw FormatException(
            '${_personaLayers[entry.key]}：字段名和内容须有效，字段名不可重复。',
          );
        }
        values[row.name] = row.value;
      }
      result[entry.key] = values;
    }
    return result;
  }
}
