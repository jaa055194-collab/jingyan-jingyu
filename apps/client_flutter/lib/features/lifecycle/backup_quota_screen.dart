import 'package:material_ui/material_ui.dart';

import '../../net/lifecycle_api.dart';

/// Read-only quota/disk + lifecycle view with EXPLICIT export/import actions.
///
/// Reads are non-destructive. Export is non-destructive (returns the account
/// bundle in memory; only summary metadata is rendered). Import is a mutation:
/// it requires an explicit mode choice and a confirmation dialog, and is never
/// auto-run. Cleanup has no merged host HTTP route, so it is shown as an honest
/// unavailable gap and never fabricated. This screen opens no ticket, prints no
/// secret or file contents, and does not change consent or model configuration.
class BackupQuotaScreen extends StatefulWidget {
  const BackupQuotaScreen({
    super.key,
    this.loadQuota,
    this.loadSurvey,
    this.api,
  });

  final Future<LifecycleQuotaStatus> Function()? loadQuota;
  final Future<LifecycleDepartureSurvey> Function()? loadSurvey;

  /// When provided, reads and explicit export/import actions use it. The current
  /// Settings entry passes only the read loaders; without this the write actions
  /// are honestly disabled rather than invented.
  final LifecycleApi? api;

  @override
  State<BackupQuotaScreen> createState() => _BackupQuotaScreenState();
}

class _BackupQuotaScreenState extends State<BackupQuotaScreen> {
  LifecycleQuotaStatus? _quota;
  LifecycleDepartureSurvey? _survey;
  bool _loading = true;
  bool _unknown = false;

  LifecycleExportBundle? _exported;
  LifecycleImportMode _mode = LifecycleImportMode.personaOnly;
  String? _actionNotice;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = widget.api;
    final quota = api != null ? api.readQuota : widget.loadQuota;
    final survey = api != null ? api.readDepartureSurvey : widget.loadSurvey;
    if (quota == null || survey == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _unknown = true;
        });
      }
      return;
    }
    try {
      final q = await quota();
      final s = await survey();
      if (!mounted) return;
      setState(() {
        _quota = q;
        _survey = s;
        _loading = false;
        _unknown = false;
      });
    } catch (_) {
      // Malformed/HTTP/transport failures are not configuration; stay unknown.
      if (!mounted) return;
      setState(() {
        _quota = null;
        _survey = null;
        _loading = false;
        _unknown = true;
      });
    }
  }

  Future<void> _export() async {
    final api = widget.api;
    if (api == null || _busy) return;
    setState(() {
      _busy = true;
      _actionNotice = null;
    });
    try {
      final bundle = await api.exportBundle();
      if (!mounted) return;
      setState(() {
        _exported = bundle;
        _actionNotice =
            '已导出到内存：文件 ${bundle.fileCount} 个，计数 ${bundle.counts}，'
            '校验和${bundle.hasChecksums ? '存在' : '缺失'}。仅显示摘要，不显示文件内容或密钥。';
      });
    } catch (_) {
      if (mounted) {
        setState(() => _actionNotice = '导出失败或结果未确认；不会自动重试。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final api = widget.api;
    final bundle = _exported;
    if (api == null || bundle == null || _busy) return;
    final selected = await showDialog<LifecycleImportMode>(
      context: context,
      builder: (dialogContext) {
        var mode = _mode;
        return StatefulBuilder(
          builder: (context, setLocal) => AlertDialog(
            title: const Text('确认导入'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('导入会写入当前账号数据；与现有数据冲突时生成新 id、不覆盖。请选择范围并确认。'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        key: const Key('import-mode-personaOnly'),
                        label: const Text('仅人格'),
                        selected: mode == LifecycleImportMode.personaOnly,
                        onSelected: (_) => setLocal(
                          () => mode = LifecycleImportMode.personaOnly,
                        ),
                      ),
                      ChoiceChip(
                        key: const Key('import-mode-personaAndConversations'),
                        label: const Text('人格 + 聊天记录'),
                        selected:
                            mode == LifecycleImportMode.personaAndConversations,
                        onSelected: (_) => setLocal(
                          () => mode =
                              LifecycleImportMode.personaAndConversations,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('import-confirm'),
                onPressed: () => Navigator.of(dialogContext).pop(mode),
                child: const Text('确认导入'),
              ),
            ],
          ),
        );
      },
    );
    if (selected == null || !mounted) return;
    setState(() {
      _mode = selected;
      _busy = true;
      _actionNotice = null;
    });
    try {
      final report = await api.importBundle(bundle, mode: selected);
      if (!mounted) return;
      setState(() {
        _actionNotice =
            '导入完成（${selected == LifecycleImportMode.personaOnly ? '仅人格' : '人格 + 聊天'}）：'
            '人格 ${report.importedPersona}，会话 ${report.importedConversations}，'
            '消息 ${report.importedMessages}，记忆 ${report.importedMemories}，'
            '附件 ${report.importedAttachments}，冲突 ${report.conflicts.length}，'
            '校验和${report.checksumVerified ? '通过' : '未通过'}。';
      });
    } catch (_) {
      if (mounted) {
        setState(() => _actionNotice = '导入失败或结果未确认；不会自动重试。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _bytes(int value) {
    const kib = 1024, mib = 1024 * 1024, gib = 1024 * 1024 * 1024;
    if (value >= gib) {
      return '${(value / gib).toStringAsFixed(1)} GiB';
    }
    if (value >= mib) {
      return '${(value / mib).toStringAsFixed(1)} MiB';
    }
    if (value >= kib) {
      return '${(value / kib).toStringAsFixed(1)} KiB';
    }
    return '$value B';
  }

  @override
  Widget build(BuildContext context) {
    final api = widget.api;
    final actionsAvailable = api != null;
    return Scaffold(
      appBar: AppBar(title: const Text('配额与生命周期状态')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('只读配额/清点；导出为非破坏性，导入为显式写操作（需确认），清理无宿主接口。不代表可用、已授权或已清理。'),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_unknown)
            Card(
              key: const Key('lifecycle-unknown'),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Text('状态未知：宿主暂不可用，或响应无法验证。不会自动重试或推测配置。'),
              ),
            ),
          if (!_loading && !_unknown && _quota != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '配额与磁盘',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text('已用：${_bytes(_quota!.usedBytes)}'),
                    Text('配额：${_bytes(_quota!.quotaBytes)}'),
                    Text(
                      '磁盘可用：${_bytes(_quota!.diskFreeBytes)} / ${_bytes(_quota!.diskTotalBytes)}',
                    ),
                  ],
                ),
              ),
            ),
          if (!_loading && !_unknown && _survey != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '生命周期对象清点',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final entry in _survey!.objectCounts.entries)
                      Text('${entry.key}：${entry.value}'),
                    Text('待匿名化动态：${_survey!.momentsToAnonymize}'),
                    Text('对象合计：${_survey!.totalObjects}'),
                    const SizedBox(height: 4),
                    const Text('此处为离开/清理前的对象清点，不等于已清理。'),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            '操作（显式点击，不会自动执行）',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const Key('export-lifecycle'),
                onPressed: actionsAvailable && !_busy ? _export : null,
                child: const Text('导出'),
              ),
              FilledButton(
                key: const Key('import-lifecycle'),
                onPressed: actionsAvailable && !_busy && _exported != null
                    ? _import
                    : null,
                child: const Text('导入'),
              ),
              FilledButton(
                key: const Key('cleanup-lifecycle'),
                // No merged host cleanup route exists.
                onPressed: null,
                child: const Text('清理（不可用）'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (!actionsAvailable)
            const Text('当前入口未接线宿主连接：导出/导入不可用（需装配 LifecycleApi）。'),
          if (actionsAvailable && _exported == null) const Text('导入需先成功导出到内存。'),
          const Text('清理：宿主未提供清理 HTTP 接口（缺口），本页不执行清理。'),
          if (_actionNotice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _actionNotice!,
                key: const Key('lifecycle-action-notice'),
              ),
            ),
        ],
      ),
    );
  }
}
