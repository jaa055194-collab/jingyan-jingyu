import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../net/model_diagnostics_api.dart';
import '../../ui/ui.dart';

/// Read-only "模型能力与预算诊断" screen.
///
/// It answers two questions the operator could previously only guess at: what
/// models the saved provider actually advertises, and what token usage the host
/// has actually recorded. Every section is an independent explicit read with
/// its own honest state; nothing loads, retries or polls on its own.
///
/// This is a diagnostics surface only. It does not write a binding or a budget,
/// does not test a provider connection at save time, and does not prove a real
/// provider/model is reachable. Reading a limit is not budget admission.
class ModelDiagnosticsScreen extends StatefulWidget {
  const ModelDiagnosticsScreen({
    super.key,
    this.session,
    this.readCatalog,
    this.readTodayUsage,
    this.readRolling7Trend,
    this.readBudget,
    this.knownProviderIds = const <String>[],
    this.knownProfileIds = const <String>[],
    this.title = '模型能力与预算诊断',
  });

  /// Pins this route to the account and session epoch present when it opens.
  /// A lock or identity change permanently invalidates its captured read loaders.
  final ShellViewModel? session;

  /// Loaders are GET-only adapters. A null loader means the section is unbound
  /// (no host connection) and must stay honestly unknown rather than guess.
  final Future<DiagnosticsRead<ModelCatalog>> Function(String providerId)?
  readCatalog;
  final Future<DiagnosticsRead<TodayUsage>> Function(String profileId)?
  readTodayUsage;
  final Future<DiagnosticsRead<Rolling7Trend>> Function(String profileId)?
  readRolling7Trend;
  final Future<DiagnosticsRead<BudgetLimits>> Function(String profileId)?
  readBudget;

  /// Saved provider ids the caller already knows. When empty the operator must
  /// type one: the screen never invents or infers a provider identity.
  final List<String> knownProviderIds;

  /// Owned AI profile ids the caller already knows. AI profile id is not the AI
  /// account id, so when this is empty the operator types it explicitly.
  final List<String> knownProfileIds;

  final String title;

  @override
  State<ModelDiagnosticsScreen> createState() => _ModelDiagnosticsScreenState();
}

/// Per-section read state. [idle] is "not requested yet", which is distinct
/// from every failure and from a loaded-but-empty answer.
enum _Phase { idle, loading, done }

class _Section<T> {
  _Phase phase = _Phase.idle;
  DiagnosticsRead<T>? read;
  int generation = 0;

  /// Set only when a loader threw instead of returning an honest state.
  bool threw = false;

  void reset() {
    generation++;
    phase = _Phase.idle;
    read = null;
    threw = false;
  }
}

class _ModelDiagnosticsScreenState extends State<ModelDiagnosticsScreen> {
  final _catalog = _Section<ModelCatalog>();
  final _usage = _Section<TodayUsage>();
  final _trend = _Section<Rolling7Trend>();
  final _budget = _Section<BudgetLimits>();

  final _providerInput = TextEditingController();
  final _profileInput = TextEditingController();
  String? _provider;
  String? _profile;
  late final ShellViewModel? _session;
  late final String? _accountId;
  late final Object? _sessionContext;
  bool _sessionInvalid = false;

  bool get _sessionMatches {
    final session = _session;
    if (!identical(widget.session, session)) return false;
    if (session == null) return true;
    return session.authenticated &&
        !session.locked &&
        _accountId != null &&
        _sessionContext != null &&
        session.connectedAccountId == _accountId &&
        session.ownAiSessionContext == _sessionContext;
  }

  void _invalidateSession() {
    _sessionInvalid = true;
    _catalog.reset();
    _usage.reset();
    _trend.reset();
    _budget.reset();
    _provider = null;
    _profile = null;
    _providerInput.clear();
    _profileInput.clear();
    _needsProvider.clear();
    _needsProfile.clear();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _onSessionChanged() {
    if (!mounted || _sessionInvalid || _sessionMatches) return;
    // Latch the first invalidation, even if the shell unlocks before a frame.
    setState(_invalidateSession);
  }

  bool _canRead() {
    if (!mounted || _sessionInvalid) return false;
    if (_sessionMatches) return true;
    _onSessionChanged();
    return false;
  }

  /// True after an explicit request that had no usable identity: report the gap
  /// instead of quietly reading something else. Tracked per section so one
  /// section's missing identity never masks another section's real state.
  final _needsProvider = <Object>{};
  final _needsProfile = <Object>{};

  void _setNeedsProvider(Object section, bool value) {
    setState(() {
      if (value) {
        _needsProvider.add(section);
      } else {
        _needsProvider.remove(section);
      }
    });
  }

  void _setNeedsProfile(Object section, bool value) {
    setState(() {
      if (value) {
        _needsProfile.add(section);
      } else {
        _needsProfile.remove(section);
      }
    });
  }

  bool get _bound =>
      widget.readCatalog != null ||
      widget.readTodayUsage != null ||
      widget.readRolling7Trend != null ||
      widget.readBudget != null;

  @override
  void initState() {
    super.initState();
    // Preselect only when exactly one option exists: a single known id is
    // unambiguous, several are not, and the screen never guesses between them.
    _provider = widget.knownProviderIds.length == 1
        ? widget.knownProviderIds.single
        : null;
    _profile = widget.knownProfileIds.length == 1
        ? widget.knownProfileIds.single
        : null;
    _session = widget.session;
    _accountId = _session?.connectedAccountId;
    _sessionContext = _session?.ownAiSessionContext;
    if (!_sessionMatches) _invalidateSession();
    _session?.addListener(_onSessionChanged);
  }

  @override
  void didUpdateWidget(covariant ModelDiagnosticsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sessionInvalid && !_sessionMatches) _invalidateSession();
  }

  @override
  void dispose() {
    _session?.removeListener(_onSessionChanged);
    _providerInput.dispose();
    _profileInput.dispose();
    super.dispose();
  }

  /// The explicitly chosen identity, from the dropdown when a list was supplied
  /// and otherwise from the typed field. Never inferred from other state.
  String? get _providerId => widget.knownProviderIds.isNotEmpty
      ? _provider
      : _trimmed(_providerInput.text);

  String? get _profileId => widget.knownProfileIds.isNotEmpty
      ? _profile
      : _trimmed(_profileInput.text);

  static String? _trimmed(String raw) {
    final value = raw.trim();
    return value.isEmpty ? null : value;
  }

  Future<void> _load<T>(
    _Section<T> section,
    Future<DiagnosticsRead<T>> Function() read,
  ) async {
    if (!_canRead() || section.phase == _Phase.loading) return;
    final generation = ++section.generation;
    setState(() {
      section.phase = _Phase.loading;
      section.read = null;
      section.threw = false;
    });
    DiagnosticsRead<T>? result;
    var threw = false;
    try {
      result = await read();
    } catch (_) {
      // Transport/parse details are never surfaced; a thrown loader is unknown.
      threw = true;
    }
    if (!_canRead() || section.generation != generation) return;
    setState(() {
      section.threw = threw;
      section.read = result;
      section.phase = _Phase.done;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: _sessionInvalid
        ? const Padding(
            key: Key('model-diagnostics-session-invalid'),
            padding: EdgeInsets.all(16),
            child: Text('会话已变更。请返回设置后重新打开诊断页。'),
          )
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                '只读诊断：模型目录来自宿主已保存的 provider，用量与预算来自宿主已记录的数据。'
                '每一项都需要你主动请求一次，不会自动加载、自动重试或轮询。'
                '「未知」不等于 0，也不等于未配置；本页不写入绑定/预算、不发起模型调用、'
                '不代表模型可用或预算获批。',
                key: Key('model-diagnostics-intro'),
              ),
              const SizedBox(height: 12),
              if (!_bound)
                const Padding(
                  key: Key('model-diagnostics-unbound'),
                  padding: EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('未连接宿主：无法读取模型目录、用量或预算。'),
                      SizedBox(height: 4),
                      Text('不会自动重试；未知不代表未配置，也不代表已配置。'),
                    ],
                  ),
                ),
              if (widget.readCatalog != null) _catalogSection(context),
              if (widget.readTodayUsage != null) _usageSection(context),
              if (widget.readRolling7Trend != null) _trendSection(context),
              if (widget.readBudget != null) _budgetSection(context),
            ],
          ),
  );

  // --- Identity pickers ---------------------------------------------------

  Widget _identityPicker({
    required String label,
    required String helper,
    required Key fieldKey,
    required Key dropdownKey,
    required List<String> known,
    required String? selected,
    required ValueChanged<String?> onSelected,
    required TextEditingController input,
    required VoidCallback onTyped,
  }) {
    if (known.isEmpty) {
      return TextField(
        key: fieldKey,
        controller: input,
        decoration: InputDecoration(labelText: label, helperText: helper),
        onChanged: (_) => onTyped(),
        onSubmitted: (_) => onTyped(),
      );
    }
    if (known.length == 1) {
      // A single known id is unambiguous; show it rather than asking twice.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('$label：${known.single}'),
      );
    }
    return InputDecorator(
      decoration: InputDecoration(labelText: label, helperText: helper),
      child: DropdownButton<String>(
        key: dropdownKey,
        value: selected,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        hint: const Text('需显式选择'),
        items: [
          for (final id in known)
            DropdownMenuItem<String>(value: id, child: Text(id)),
        ],
        onChanged: onSelected,
      ),
    );
  }

  // --- Model catalog ------------------------------------------------------

  Widget _catalogSection(BuildContext context) {
    final loader = widget.readCatalog!;
    return _SectionCard(
      key: const Key('diagnostics-catalog-section'),
      title: '模型目录',
      subtitle: '宿主已保存 provider 的模型 id 列表；只列 id，不含凭据或上游元数据。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _identityPicker(
            label: '已保存 provider id',
            helper: '需显式指定；本页不做默认推断',
            fieldKey: const Key('diagnostics-catalog-provider-input'),
            dropdownKey: const Key('diagnostics-catalog-provider'),
            known: widget.knownProviderIds,
            selected: _provider,
            input: _providerInput,
            onSelected: (value) => setState(() {
              _provider = value;
              _catalog.reset();
            }),
            onTyped: () {
              if (!mounted) return;
              _setNeedsProvider(_catalog, false);
              setState(() => _catalog.reset());
            },
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('diagnostics-catalog-load'),
              onPressed: _catalog.phase == _Phase.loading
                  ? null
                  : () => _requestCatalog(loader),
              child: Text(_catalog.phase == _Phase.loading ? '读取中…' : '读取模型目录'),
            ),
          ),
          _catalogBody(context),
        ],
      ),
    );
  }

  void _requestCatalog(
    Future<DiagnosticsRead<ModelCatalog>> Function(String) loader,
  ) {
    if (!_canRead()) return;
    final provider = _providerId;
    if (provider == null) {
      _setNeedsProvider(_catalog, true);
      return;
    }
    _setNeedsProvider(_catalog, false);
    _load(_catalog, () => loader(provider));
  }

  Widget _catalogBody(BuildContext context) {
    if (_needsProvider.contains(_catalog)) {
      return const _StateLine(
        key: Key('diagnostics-catalog-needs-provider'),
        tone: _StateTone.idle,
        text: '请先显式指定要查询的已保存 provider；本页不做默认推断。',
      );
    }
    if (_catalog.phase == _Phase.idle) {
      return const _StateLine(
        key: Key('diagnostics-catalog-not-requested'),
        tone: _StateTone.idle,
        text: '尚未读取。点击上面的按钮后才会请求宿主。',
      );
    }
    if (_catalog.phase == _Phase.loading) {
      return const _StateLine(
        key: Key('diagnostics-catalog-loading'),
        tone: _StateTone.loading,
        text: '正在读取…',
      );
    }
    final read = _catalog.read;
    if (_catalog.threw || read == null) {
      return const _StateLine(
        key: Key('diagnostics-catalog-unknown'),
        tone: _StateTone.warning,
        text: '状态未知：读取失败或响应无法解析；不会自动重试。',
      );
    }
    switch (read.status) {
      case DiagnosticsReadStatus.loaded:
        final models = read.value!.models;
        return Column(
          key: const Key('diagnostics-catalog-loaded'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StateLine(
              key: const Key('diagnostics-catalog-summary'),
              tone: _StateTone.success,
              text: '宿主返回 ${models.length} 个模型 id：',
            ),
            if (models.isEmpty)
              const Text('目录为空：宿主没有返回任何模型 id（不等于读取失败）。')
            else
              for (final id in models) SelectableText('· $id'),
          ],
        );
      case DiagnosticsReadStatus.unconfigured:
        return const _StateLine(
          key: Key('diagnostics-catalog-unconfigured'),
          tone: _StateTone.warning,
          text: '未配置：宿主没有可查询的 provider 配置。',
        );
      case DiagnosticsReadStatus.notFound:
        return const _StateLine(
          key: Key('diagnostics-catalog-not-found'),
          tone: _StateTone.danger,
          text: '未找到该 provider（可能不存在、不属于当前账号或不可见）。',
        );
      case DiagnosticsReadStatus.denied:
        return const _StateLine(
          key: Key('diagnostics-catalog-denied'),
          tone: _StateTone.danger,
          text: '未认证或无权限读取该 provider。',
        );
      case DiagnosticsReadStatus.unavailable:
        return const _StateLine(
          key: Key('diagnostics-catalog-unavailable'),
          tone: _StateTone.danger,
          text: '宿主暂时无法提供模型目录（例如未配置模型传输或上游不可用）；不会自动重试。',
        );
      case DiagnosticsReadStatus.unknown:
        return const _StateLine(
          key: Key('diagnostics-catalog-unknown'),
          tone: _StateTone.warning,
          text: '状态未知：读取失败或响应无法解析；不会自动重试。',
        );
    }
  }

  // --- Today's recorded usage ---------------------------------------------

  Widget _usageSection(BuildContext context) {
    final loader = widget.readTodayUsage!;
    return _SectionCard(
      key: const Key('diagnostics-usage-section'),
      title: '今日已记录用量',
      subtitle: '宿主今日账本按层/能力汇总的已记录 token；pending 能力标为未知，不当作 0。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _identityPicker(
            label: 'AI 档案 id',
            helper: 'AI 档案 id 与 AI 账户 id 不是同一个概念，需显式指定',
            fieldKey: const Key('diagnostics-usage-profile-input'),
            dropdownKey: const Key('diagnostics-usage-profile'),
            known: widget.knownProfileIds,
            selected: _profile,
            input: _profileInput,
            onSelected: (value) => setState(() {
              _profile = value;
              _resetProfileReads();
            }),
            onTyped: () {
              if (!mounted) return;
              setState(_resetProfileReads);
            },
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('diagnostics-usage-load'),
              onPressed: _usage.phase == _Phase.loading
                  ? null
                  : () => _requestProfile(_usage, loader),
              child: Text(_usage.phase == _Phase.loading ? '读取中…' : '读取今日用量'),
            ),
          ),
          _usageBody(context),
        ],
      ),
    );
  }

  void _resetProfileReads() {
    _usage.reset();
    _trend.reset();
    _budget.reset();
    _needsProfile.clear();
  }

  void _requestProfile<T>(
    _Section<T> section,
    Future<DiagnosticsRead<T>> Function(String) loader,
  ) {
    if (!_canRead()) return;
    final profile = _profileId;
    if (profile == null) {
      _setNeedsProfile(section, true);
      return;
    }
    _setNeedsProfile(section, false);
    _load(section, () => loader(profile));
  }

  Widget _usageBody(BuildContext context) {
    if (_needsProfile.contains(_usage)) {
      return const _StateLine(
        key: Key('diagnostics-usage-needs-profile'),
        tone: _StateTone.idle,
        text: '请先显式指定要查询的 AI 档案；本页不做默认推断。',
      );
    }
    if (_usage.phase == _Phase.idle) {
      return const _StateLine(
        key: Key('diagnostics-usage-not-requested'),
        tone: _StateTone.idle,
        text: '尚未读取。点击上面的按钮后才会请求宿主。',
      );
    }
    if (_usage.phase == _Phase.loading) {
      return const _StateLine(
        key: Key('diagnostics-usage-loading'),
        tone: _StateTone.loading,
        text: '正在读取…',
      );
    }
    final read = _usage.read;
    if (_usage.threw || read == null) {
      return const _StateLine(
        key: Key('diagnostics-usage-unknown'),
        tone: _StateTone.warning,
        text: '状态未知：读取失败或响应无法解析；不会自动重试。',
      );
    }
    switch (read.status) {
      case DiagnosticsReadStatus.loaded:
        final usage = read.value!;
        return Column(
          key: const Key('diagnostics-usage-loaded'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StateLine(
              key: const Key('diagnostics-usage-summary'),
              tone: _StateTone.success,
              text:
                  '预算日 ${usage.budgetDay} · 时区偏移 ${usage.offsetMinutes} 分钟 · '
                  '已记录 ${usage.recordedTokens} tokens',
            ),
            const SizedBox(height: 4),
            const Text('按层：'),
            for (final entry in usage.byLayer.entries)
              _CountLine(
                key: Key('diagnostics-usage-layer-${entry.key}'),
                label: entry.key,
                value: entry.value,
                unknown: false,
              ),
            const SizedBox(height: 4),
            const Text('按能力：'),
            for (final entry in usage.byCapability.entries)
              _CountLine(
                key: Key('diagnostics-usage-capability-${entry.key}'),
                label: entry.key,
                value: entry.value,
                // Pending ledger rows make this count incomplete: say unknown,
                // never print the misleading zero.
                unknown: usage.sourceUsageUnknown[entry.key] == true,
              ),
            if (usage.hasUnknown) ...[
              const SizedBox(height: 4),
              for (final capability in usage.unknownCapabilities)
                _StateLine(
                  key: Key('diagnostics-usage-unknown-$capability'),
                  tone: _StateTone.warning,
                  text: '$capability：有未结算（pending）记录，实际用量未知，不按 0 计算。',
                ),
            ],
          ],
        );
      case DiagnosticsReadStatus.unconfigured:
        return const _StateLine(
          key: Key('diagnostics-usage-unconfigured'),
          tone: _StateTone.warning,
          text: '未配置：宿主尚未配置该档案的预算时区，因此无法确定“今日”，不显示任何用量数字。',
        );
      case DiagnosticsReadStatus.notFound:
        return const _StateLine(
          key: Key('diagnostics-usage-not-found'),
          tone: _StateTone.danger,
          text: '未找到该 AI 档案（可能不存在、不属于当前账号或不可见）。',
        );
      case DiagnosticsReadStatus.denied:
        return const _StateLine(
          key: Key('diagnostics-usage-denied'),
          tone: _StateTone.danger,
          text: '未认证或无权限读取该档案的用量。',
        );
      case DiagnosticsReadStatus.unavailable:
        return const _StateLine(
          key: Key('diagnostics-usage-unavailable'),
          tone: _StateTone.danger,
          text: '宿主暂时无法提供用量（服务或连接不可用）；不会自动重试。',
        );
      case DiagnosticsReadStatus.unknown:
        return const _StateLine(
          key: Key('diagnostics-usage-unknown'),
          tone: _StateTone.warning,
          text: '状态未知：读取失败或响应无法解析；不会自动重试。',
        );
    }
  }

  // --- Rolling seven recorded days ----------------------------------------

  Widget _trendSection(BuildContext context) {
    final loader = widget.readRolling7Trend!;
    return _SectionCard(
      key: const Key('diagnostics-trend-section'),
      title: '滚动 7 个记录日趋势',
      subtitle: '宿主 rolling7 / recordedBudgetDay 口径：今日加前 6 个已记录预算日，不是日历周。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('diagnostics-trend-load'),
              onPressed: _trend.phase == _Phase.loading
                  ? null
                  : () => _requestProfile(_trend, loader),
              child: Text(_trend.phase == _Phase.loading ? '读取中…' : '读取 7 日趋势'),
            ),
          ),
          _trendBody(context),
        ],
      ),
    );
  }

  Widget _trendBody(BuildContext context) {
    if (_needsProfile.contains(_trend)) {
      return const _StateLine(
        key: Key('diagnostics-trend-needs-profile'),
        tone: _StateTone.idle,
        text: '请先显式指定要查询的 AI 档案；本页不做默认推断。',
      );
    }
    if (_trend.phase == _Phase.idle) {
      return const _StateLine(
        key: Key('diagnostics-trend-not-requested'),
        tone: _StateTone.idle,
        text: '尚未读取。点击上面的按钮后才会请求宿主。',
      );
    }
    if (_trend.phase == _Phase.loading) {
      return const _StateLine(
        key: Key('diagnostics-trend-loading'),
        tone: _StateTone.loading,
        text: '正在读取…',
      );
    }
    final read = _trend.read;
    if (_trend.threw || read == null) {
      return const _StateLine(
        key: Key('diagnostics-trend-unknown'),
        tone: _StateTone.warning,
        text: '状态未知：读取失败或响应无法解析；不会自动重试。',
      );
    }
    switch (read.status) {
      case DiagnosticsReadStatus.loaded:
        final trend = read.value!;
        return Column(
          key: const Key('diagnostics-trend-loaded'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StateLine(
              key: const Key('diagnostics-trend-summary'),
              tone: _StateTone.success,
              text:
                  '窗口 ${trend.window} · 口径 ${trend.basis} · '
                  '${trend.startDay} 至 ${trend.endDay} · '
                  '时区偏移 ${trend.offsetMinutes} 分钟',
            ),
            const SizedBox(height: 4),
            for (final day in trend.days)
              Text(
                '${day.day} · 已记录 ${day.recordedTokens} tokens'
                '${day.sourceUsageUnknown ? ' · 含未结算记录，当日用量未知' : ''}',
                key: Key('diagnostics-trend-day-${day.day}'),
              ),
            if (trend.hasUnknown) ...[
              const SizedBox(height: 4),
              const _StateLine(
                key: Key('diagnostics-trend-history-unknown'),
                tone: _StateTone.warning,
                text: '存在历史未结算（pending）记录（可能不在上面 7 天内）：这些用量仍然未知，不按 0 计算。',
              ),
            ],
          ],
        );
      case DiagnosticsReadStatus.unconfigured:
        return const _StateLine(
          key: Key('diagnostics-trend-unconfigured'),
          tone: _StateTone.warning,
          text: '未配置：宿主尚未配置该档案的预算时区，因此无法划分记录日，不显示任何趋势数字。',
        );
      case DiagnosticsReadStatus.notFound:
        return const _StateLine(
          key: Key('diagnostics-trend-not-found'),
          tone: _StateTone.danger,
          text: '未找到该 AI 档案（可能不存在、不属于当前账号或不可见）。',
        );
      case DiagnosticsReadStatus.denied:
        return const _StateLine(
          key: Key('diagnostics-trend-denied'),
          tone: _StateTone.danger,
          text: '未认证或无权限读取该档案的趋势。',
        );
      case DiagnosticsReadStatus.unavailable:
        return const _StateLine(
          key: Key('diagnostics-trend-unavailable'),
          tone: _StateTone.danger,
          text: '宿主暂时无法提供趋势（服务或连接不可用）；不会自动重试。',
        );
      case DiagnosticsReadStatus.unknown:
        return const _StateLine(
          key: Key('diagnostics-trend-unknown'),
          tone: _StateTone.warning,
          text: '状态未知：读取失败或响应无法解析；不会自动重试。',
        );
    }
  }

  // --- Configured budget --------------------------------------------------

  Widget _budgetSection(BuildContext context) {
    final loader = widget.readBudget!;
    return _SectionCard(
      key: const Key('diagnostics-budget-section'),
      title: '已配置预算上限',
      subtitle: '宿主已显式保存的每日/分层/能力上限；读到上限不等于预算获批或仍有余量。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('diagnostics-budget-load'),
              onPressed: _budget.phase == _Phase.loading
                  ? null
                  : () => _requestProfile(_budget, loader),
              child: Text(_budget.phase == _Phase.loading ? '读取中…' : '读取预算上限'),
            ),
          ),
          _budgetBody(context),
        ],
      ),
    );
  }

  Widget _budgetBody(BuildContext context) {
    if (_needsProfile.contains(_budget)) {
      return const _StateLine(
        key: Key('diagnostics-budget-needs-profile'),
        tone: _StateTone.idle,
        text: '请先显式指定要查询的 AI 档案；本页不做默认推断。',
      );
    }
    if (_budget.phase == _Phase.idle) {
      return const _StateLine(
        key: Key('diagnostics-budget-not-requested'),
        tone: _StateTone.idle,
        text: '尚未读取。点击上面的按钮后才会请求宿主。',
      );
    }
    if (_budget.phase == _Phase.loading) {
      return const _StateLine(
        key: Key('diagnostics-budget-loading'),
        tone: _StateTone.loading,
        text: '正在读取…',
      );
    }
    final read = _budget.read;
    if (_budget.threw || read == null) {
      return const _StateLine(
        key: Key('diagnostics-budget-unknown'),
        tone: _StateTone.warning,
        text: '状态未知：读取失败或响应无法解析；不会自动重试。',
      );
    }
    switch (read.status) {
      case DiagnosticsReadStatus.loaded:
        final budget = read.value!;
        return Column(
          key: const Key('diagnostics-budget-loaded'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StateLine(
              key: const Key('diagnostics-budget-summary'),
              tone: _StateTone.success,
              text:
                  '每日 ${budget.dailyTokens} tokens · '
                  '时区偏移 ${budget.offsetMinutes} 分钟',
            ),
            const SizedBox(height: 4),
            const Text('分层上限：'),
            for (final entry in budget.layerLimits.entries)
              Text(
                '· ${entry.key}：${entry.value}',
                key: Key('diagnostics-budget-layer-${entry.key}'),
              ),
            const SizedBox(height: 4),
            const Text('能力上限：'),
            for (final entry in budget.capabilityLimits.entries)
              Text(
                '· ${entry.key}：${entry.value}',
                key: Key('diagnostics-budget-capability-${entry.key}'),
              ),
          ],
        );
      case DiagnosticsReadStatus.unconfigured:
        return const _StateLine(
          key: Key('diagnostics-budget-unconfigured'),
          tone: _StateTone.warning,
          text: '未配置：宿主没有该档案的完整预算配置（含显式时区），不显示任何上限数字。',
        );
      case DiagnosticsReadStatus.notFound:
        return const _StateLine(
          key: Key('diagnostics-budget-not-found'),
          tone: _StateTone.danger,
          text: '未找到该 AI 档案（可能不存在、不属于当前账号或不可见）。',
        );
      case DiagnosticsReadStatus.denied:
        return const _StateLine(
          key: Key('diagnostics-budget-denied'),
          tone: _StateTone.danger,
          text: '未认证或无权限读取该档案的预算。',
        );
      case DiagnosticsReadStatus.unavailable:
        return const _StateLine(
          key: Key('diagnostics-budget-unavailable'),
          tone: _StateTone.danger,
          text: '宿主暂时无法提供预算（服务或连接不可用）；不会自动重试。',
        );
      case DiagnosticsReadStatus.unknown:
        return const _StateLine(
          key: Key('diagnostics-budget-unknown'),
          tone: _StateTone.warning,
          text: '状态未知：读取失败或响应无法解析；不会自动重试。',
        );
    }
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: JySpace.md),
    child: JySlab(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(JySpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(color: JyPalette.of(context).text1),
            ),
            const SizedBox(height: JySpace.xs),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: JyPalette.of(context).text2),
            ),
            const SizedBox(height: JySpace.sm),
            child,
          ],
        ),
      ),
    ),
  );
}

/// How a diagnostics status line reads. Each tone pairs a Material icon
/// with a JyPalette color for the icon and the text.
enum _StateTone { idle, loading, success, warning, danger }

class _StateLine extends StatelessWidget {
  const _StateLine({super.key, required this.tone, required this.text});
  final _StateTone tone;
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = JyPalette.of(context);
    final (icon, color) = switch (tone) {
      _StateTone.idle => (Icons.info_outline, palette.text3),
      _StateTone.loading => (Icons.hourglass_empty, palette.text2),
      _StateTone.success => (Icons.check_circle_outline, palette.success),
      _StateTone.warning => (Icons.warning_amber_outlined, palette.warning),
      _StateTone.danger => (Icons.error_outline, palette.danger),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: JySpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: JySpace.sm),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountLine extends StatelessWidget {
  const _CountLine({
    super.key,
    required this.label,
    required this.value,
    required this.unknown,
  });

  final String label;
  final BigInt value;
  final bool unknown;

  @override
  Widget build(BuildContext context) => Text(
    // Pending rows mean the recorded counter is not the truth for this
    // capability, so the honest display is "unknown", never "0".
    '· $label：${unknown ? '未知（存在未结算记录）' : '$value tokens'}',
  );
}
