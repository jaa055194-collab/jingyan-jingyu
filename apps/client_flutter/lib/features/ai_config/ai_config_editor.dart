import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/ai_config_write_api.dart';
import '../../net/host_connection.dart';

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
    this.ownedAiAccountIds = const <String>[],
  });

  final AiConfigWriter? writer;
  final Future<String> Function(String aiAccountId)? resolveProfileId;
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

  @override
  void initState() {
    super.initState();
    if (widget.ownedAiAccountIds.isNotEmpty) {
      _selected = widget.ownedAiAccountIds.first;
      _resolve();
    }
  }

  @override
  void dispose() {
    for (final controller in [
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
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _ready => widget.writer != null && _profileId != null && !_busy;

  Future<void> _resolve() async {
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
      if (!mounted) return;
      setState(() {
        _profileId = profile;
        _resolving = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _profileId = null;
        _resolving = false;
        _status = '无法解析该 AI 档案；请稍后重试或重新选择；不会自动重试';
        _statusError = true;
      });
    }
  }

  void _select(String? account) {
    if (account == null || account == _selected) return;
    setState(() {
      _selected = account;
      _status = null;
      _profileId = null;
    });
    _resolve();
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

  Future<void> _run(
    Future<void> Function(AiConfigWriter writer) action,
    String success,
  ) async {
    final writer = widget.writer;
    if (writer == null || _profileId == null) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await action(writer);
      if (!mounted) return;
      setState(() {
        _status = success;
        _statusError = false;
      });
    } on HostRequestException catch (error) {
      if (!mounted) return;
      setState(() {
        _status = _failureText(error);
        _statusError = true;
      });
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _status = error.message;
        _statusError = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status = '操作失败或结果未知；不会自动重试';
        _statusError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
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
    final canUse = widget.writer != null;
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
              child: Text(
                _status!,
                style: TextStyle(
                  color: _statusError
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ),
            ),
          const Divider(height: 32),
          _section('人格', [
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
                      : () => _run((writer) {
                          final p0 = _pairs(_p0.text);
                          final p1 = _pairs(_p1.text);
                          final p2 = _pairs(_p2.text);
                          if (p0.isEmpty || p1.isEmpty || p2.isEmpty) {
                            throw const FormatException('人格三层 p0/p1/p2 都必须非空');
                          }
                          return writer.initializePersona(
                            _profileId!,
                            p0: p0,
                            p1: p1,
                            p2: p2,
                          );
                        }, '人格已初始化'),
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
                        ),
                  child: const Text('保存人格修改'),
                ),
              ],
            ),
          ]),
          _section('Provider', [
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
                  onPressed: !_ready ? null : _createProvider,
                  child: const Text('新建 Provider'),
                ),
                OutlinedButton(
                  key: const Key('provider-update'),
                  onPressed: !_ready ? null : _updateProvider,
                  child: const Text('更新 Provider'),
                ),
              ],
            ),
          ]),
          _section('聊天绑定', [
            _field('binding-provider', _bindProvider, 'Provider ID'),
            _field('binding-model', _bindModel, '模型 ID'),
            FilledButton(
              key: const Key('binding-save'),
              onPressed: !_ready
                  ? null
                  : () => _run(
                      (writer) => writer.setChatBinding(
                        _profileId!,
                        providerId: _bindProvider.text.trim(),
                        model: _bindModel.text.trim(),
                      ),
                      '聊天绑定已保存',
                    ),
              child: const Text('保存聊天绑定'),
            ),
          ]),
          _section('预算', [
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
              onPressed: !_ready ? null : _saveBudget,
              child: const Text('保存预算'),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
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
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      key: Key(key),
      controller: controller,
      obscureText: obscure,
      minLines: 1,
      maxLines: obscure ? 1 : lines,
      decoration: InputDecoration(labelText: label),
    ),
  );

  Future<void> _createProvider() async {
    try {
      final writer = widget.writer!;
      final result = await writer.createProvider(
        name: _provName.text.trim(),
        baseUrl: _provBaseUrl.text.trim(),
        apiKey: _provApiKey.text,
        capabilities: _caps(_provCaps.text),
      );
      if (!mounted) return;
      setState(() {
        _status = 'Provider 已保存：${result.name} · 掩码 ${result.keyMask}（不是密钥）';
        _statusError = false;
        _provApiKey.clear();
      });
    } on HostRequestException catch (error) {
      if (mounted) {
        setState(() {
          _status = _failureText(error);
          _statusError = true;
        });
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _status = error.message;
          _statusError = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = '操作失败或结果未知；不会自动重试';
          _statusError = true;
        });
      }
    }
  }

  Future<void> _updateProvider() async {
    final providerId = _provId.text.trim();
    await _run(
      (writer) => writer.updateProvider(
        providerId,
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
    );
    if (!_statusError && mounted) _provApiKey.clear();
  }

  Future<void> _saveBudget() async {
    await _run((writer) {
      final layers = _intPairs(_budgetLayers.text);
      final caps = _intPairs(_budgetCaps.text);
      return writer.configureBudget(
        _profileId!,
        dailyTokens: _requireInt(_budgetDaily, '每日 token 上限'),
        layerLimits: layers,
        capabilityLimits: caps,
        offsetMinutes: _requireInt(_budgetOffset, '时区偏移'),
      );
    }, '预算已保存');
  }
}
