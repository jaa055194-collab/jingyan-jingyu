import 'package:material_ui/material_ui.dart';

import '../../net/owner_ai_direct_api.dart';
import '../../net/owner_ai_readiness_api.dart';

/// One read-only configuration row. These values describe saved host metadata
/// only; none of them means a model/worker is available, a budget is admitted,
/// or a reply is authorized.
class AiConfigEntry {
  const AiConfigEntry(this.title, this.status, this.lines);
  final String title;
  final ConfigurationReadStatus status;
  final List<String> lines;
}

/// Immutable view model so widget tests never need a network or host.
class AiConfigSnapshot {
  const AiConfigSnapshot(this.entries);
  final List<AiConfigEntry> entries;
}

/// Read-only "AI 运行配置体检" panel.
///
/// The panel performs GET-only reads through [OwnerAiReadinessApi]: persona,
/// bindings, budget and the provider metadata referenced by those bindings. It
/// never writes configuration, never configures keys, and never shows anything
/// but the server-masked key mask. When no loader is available or a read fails
/// it reports an honest unknown state without leaking transport details.
class AiConfigPanel extends StatefulWidget {
  const AiConfigPanel({super.key, this.title = 'AI 运行配置体检', this.load});
  final String title;
  final Future<AiConfigSnapshot> Function()? load;

  /// Maps read-only API results to the panel view model. Sequential GETs; the
  /// two reads are not an atomic snapshot and this does not claim they are.
  static Future<AiConfigSnapshot> loadFrom(
    OwnerAiReadinessApi api,
    OwnedAiProfileIdentity identity,
  ) async {
    final persona = await api.readPersona(identity);
    final bindings = await api.readBindings(identity);
    final budget = await api.readBudget(identity);
    final providers = <String>{
      if (bindings.status == ConfigurationReadStatus.configurationPresent)
        for (final binding in bindings.value ?? const []) binding.providerId,
    };
    final providerEntries = <AiConfigEntry>[];
    for (final providerId in providers) {
      final read = await api.readProvider(identity, providerId);
      providerEntries.add(_providerEntry(read));
    }
    return AiConfigSnapshot([
      _personaEntry(persona),
      _bindingsEntry(bindings),
      _budgetEntry(budget),
      if (providers.isEmpty)
        const AiConfigEntry('Provider', ConfigurationReadStatus.unconfigured, [
          '没有可读取的绑定 provider',
        ])
      else
        ...providerEntries,
    ]);
  }

  static AiConfigEntry _personaEntry(
    ConfigurationRead<OwnerPersonaCard> read,
  ) {
    final card = read.value;
    if (read.status != ConfigurationReadStatus.configurationPresent ||
        card == null) {
      return AiConfigEntry('人格', read.status, _lines(read));
    }
    final layers = <String>[
      for (final name in ['p0', 'p1', 'p2'])
        '$name 字段：${(card.layers[name] ?? const {}).keys.join('、')}',
    ];
    return AiConfigEntry('人格', read.status, <String>[
      '档案：${card.aiProfileId} · 版本 ${card.version}',
      card.locked ? '人格已锁定' : '人格未锁定',
      ...layers,
    ]);
  }

  static AiConfigEntry _bindingsEntry(
    ConfigurationRead<List<OwnerModelBinding>> read,
  ) {
    final rows = read.value;
    if (read.status != ConfigurationReadStatus.configurationPresent ||
        rows == null) {
      return AiConfigEntry('绑定', read.status, _lines(read));
    }
    return AiConfigEntry('绑定', read.status, <String>[
      for (final row in rows) '${row.capability} → ${row.providerId} · ${row.model}',
    ]);
  }

  static AiConfigEntry _budgetEntry(
    ConfigurationRead<OwnerBudgetConfiguration> read,
  ) {
    final budget = read.value;
    if (read.status != ConfigurationReadStatus.configurationPresent ||
        budget == null) {
      return AiConfigEntry('预算', read.status, _lines(read));
    }
    return AiConfigEntry('预算', read.status, <String>[
      '每日 ${budget.dailyTokens} tokens · 时区偏移 ${budget.offsetMinutes} 分钟',
      '分层上限：${budget.layerLimits.length} 项 · 能力上限：${budget.capabilityLimits.length} 项',
    ]);
  }

  static AiConfigEntry _providerEntry(
    ConfigurationRead<OwnerProviderMetadata> read,
  ) {
    final provider = read.value;
    if (read.status != ConfigurationReadStatus.configurationPresent ||
        provider == null) {
      return AiConfigEntry('Provider', read.status, _lines(read));
    }
    final caps = provider.capabilities.toList()..sort();
    return AiConfigEntry('Provider', read.status, <String>[
      provider.name,
      provider.baseUrl,
      '掩码：${provider.keyMask}（不是密钥）',
      provider.enabled ? '已启用' : '未启用',
      '能力：${caps.join('、')}',
    ]);
  }

  static List<String> _lines<T>(ConfigurationRead<T> read) => switch (read.status) {
    ConfigurationReadStatus.configurationPresent => const ['已配置'],
    ConfigurationReadStatus.unconfigured => const ['未配置'],
    ConfigurationReadStatus.personaMissing => const ['人格尚未初始化'],
    ConfigurationReadStatus.ownershipUnknown => const ['归属未知，请刷新后重试'],
    ConfigurationReadStatus.denied => const ['未认证或无权限'],
    ConfigurationReadStatus.unknown => const ['读取失败或结果未知'],
  };

  @override
  State<AiConfigPanel> createState() => _AiConfigPanelState();
}

class _AiConfigPanelState extends State<AiConfigPanel> {
  AiConfigSnapshot? _snapshot;
  bool _loading = true;
  bool _unknown = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final load = widget.load;
    if (load == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _unknown = true;
        });
      }
      return;
    }
    try {
      final snapshot = await load();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _unknown = false;
      });
    } catch (_) {
      // Malformed/HTTP/transport failures are not configuration; stay unknown
      // and never surface exception details.
      if (!mounted) return;
      setState(() {
        _snapshot = null;
        _loading = false;
        _unknown = true;
      });
    }
  }

  static String _statusLabel(ConfigurationReadStatus status) => switch (status) {
    ConfigurationReadStatus.configurationPresent => '已配置',
    ConfigurationReadStatus.unconfigured => '未配置',
    ConfigurationReadStatus.personaMissing => '人格缺失',
    ConfigurationReadStatus.ownershipUnknown => '归属未知',
    ConfigurationReadStatus.denied => '无权限/未认证',
    ConfigurationReadStatus.unknown => '未知',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '只读体检：以下为宿主返回的已保存配置元数据，不等于模型可用、不等于预算获批、不等于已授权回复；本页不写入配置、不配置密钥、不发起模型调用。',
        ),
        const SizedBox(height: 12),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_unknown)
          Padding(
            key: const Key('ai-config-unknown'),
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('状态未知：未连接宿主或读取失败；不会自动重试。'),
                SizedBox(height: 4),
                Text('未知不代表未配置，也不代表已配置。'),
              ],
            ),
          ),
        if (_snapshot != null)
          for (final entry in _snapshot!.entries)
            Padding(
              key: ValueKey('ai-config-entry-${entry.title}'),
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${entry.title} · ${_statusLabel(entry.status)}'),
                  for (final line in entry.lines)
                    SelectableText(line, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
      ],
    ),
  );
}
