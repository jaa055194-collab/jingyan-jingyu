import 'package:material_ui/material_ui.dart';

import '../../app/status_panel.dart';
import '../../net/lifecycle_api.dart';
import '../../ui/ui.dart';
import 'backup_file_preview_panel.dart';
import 'backup_files.dart';

/// Read-only quota/disk + lifecycle view with EXPLICIT export/import actions.
///
/// Reads are non-destructive. Export is non-destructive (returns the account
/// bundle in memory; only summary metadata is rendered). Import is a mutation:
/// it requires an explicit mode choice and a confirmation dialog, and is never
/// auto-run. Cleanup is a **read-only preview** (host retention-preview route):
/// it shows what a cleanup WOULD remove and honestly states that execution is
/// not provided — nothing on this screen deletes data. It opens no ticket,
/// prints no secret or file contents, and does not change consent or model
/// configuration.
class BackupQuotaScreen extends StatefulWidget {
  const BackupQuotaScreen({
    super.key,
    this.loadQuota,
    this.loadSurvey,
    this.api,
    this.backupFiles,
    this.filePreview,
    this.canWritePlaintext = true,
  });

  final Future<LifecycleQuotaStatus> Function()? loadQuota;
  final Future<LifecycleDepartureSurvey> Function()? loadSurvey;

  /// When provided, reads and explicit export/import actions use it. The current
  /// Settings entry passes only the read loaders; without this the write actions
  /// are honestly disabled rather than invented.
  final LifecycleApi? api;

  /// Optional platform file destination. Save stays unavailable unless injected.
  final BackupFileStore? backupFiles;

  /// Local preview is separate from the host-exported bundle used by import.
  final BackupFilePreviewAccess? filePreview;

  /// Whether the surrounding session is currently unlocked and still bound to
  /// the account whose bundle is in memory. A pushed route survives a lock, so
  /// this is re-evaluated by the caller on every build; when false, no local
  /// plaintext write or host write is offered.
  final bool canWritePlaintext;

  @override
  State<BackupQuotaScreen> createState() => _BackupQuotaScreenState();
}

class _BackupQuotaScreenState extends State<BackupQuotaScreen> {
  LifecycleQuotaStatus? _quota;
  LifecycleDepartureSurvey? _survey;
  LifecycleCleanupPreview? _cleanupPreview;
  bool _cleanupLoading = false;
  bool _cleanupUnknown = false;
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
    _loadCleanupPreview();
  }

  @override
  void didUpdateWidget(BackupQuotaScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A lock/account change must not leave the previous account's exported
    // bundle in memory or writable from this already-pushed route.
    if (!widget.canWritePlaintext && _exported != null) {
      _exported = null;
      _actionNotice = '账号已锁定或变化，已清除内存中的导出内容。';
    }
  }

  /// Read-only cleanup preview. Never executes anything; the host has no
  /// user-triggered cleanup execution route, so the button stays non-destructive
  /// and the section honestly notes that execution is not yet provided.
  Future<void> _loadCleanupPreview() async {
    final api = widget.api;
    if (api == null) return;
    setState(() => _cleanupLoading = true);
    try {
      final preview = await api.readCleanupPreview();
      if (!mounted) return;
      setState(() {
        _cleanupPreview = preview;
        _cleanupLoading = false;
        _cleanupUnknown = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cleanupPreview = null;
        _cleanupLoading = false;
        _cleanupUnknown = true;
      });
    }
  }

  static String _cleanupKindLabel(String kind) => switch (kind) {
    'video' => '视频',
    'voice' => '语音',
    _ => kind,
  };

  Widget _cleanupRows(Map<String, int> counts) {
    final lines = <Widget>[
      for (final kind in counts.keys)
        Text('${_cleanupKindLabel(kind)}：${counts[kind]}'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines,
    );
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
        final coverage = bundle.manifest['coverage'];
        final chatOnly =
            coverage is Map &&
            coverage['scope'] == 'chatHistory' &&
            coverage['completeAccountExport'] == false;
        _actionNotice =
            '已导出到内存：文件 ${bundle.fileCount} 个，计数 ${bundle.counts}，'
            '校验和${bundle.hasChecksums ? '存在' : '缺失'}。仅显示摘要，不显示文件内容或密钥。'
            '${chatOnly ? '\n当前仅导出有权读取的聊天记录；不包含人格、记忆和附件内容，不是完整账号备份。' : ''}';
      });
    } catch (_) {
      if (mounted) {
        setState(() => _actionNotice = '导出失败或结果未确认；不会自动重试。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveToFile() async {
    final store = widget.backupFiles;
    final bundle = _exported;
    if (store == null || bundle == null || _busy || !widget.canWritePlaintext) {
      return;
    }
    setState(() {
      _busy = true;
      _actionNotice = null;
    });
    try {
      final saved = await store.save(bundle);
      if (!mounted) return;
      setState(() {
        _actionNotice = saved == null
            ? '已取消保存。'
            : '已保存导出文件：${saved.name}（${_bytes(saved.bytes)}）。'
                  '文件含聊天明文，不受应用锁保护，请妥善保管。';
      });
    } catch (_) {
      if (mounted) {
        setState(() => _actionNotice = '导出文件保存失败或结果未确认；不会自动重试。');
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
                  const Text(
                    '导入会写入当前账号数据；与现有数据冲突时生成新 id、不覆盖。'
                    '当前宿主导入仍为内存参考实现，重启后不会保留。请选择范围并确认。',
                  ),
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
            '校验和${report.checksumVerified ? '通过' : '未通过'}。'
            '当前宿主导入仍为内存参考实现，重启后不会保留。';
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

  static JyBannerKind _noticeKind(String notice) {
    if (notice.contains('失败') || notice.contains('未确认')) {
      return JyBannerKind.error;
    }
    if (notice.contains('已导出') ||
        notice.contains('已保存') ||
        notice.contains('导入完成') ||
        notice.contains('已清除')) {
      return JyBannerKind.success;
    }
    return JyBannerKind.info;
  }

  @override
  Widget build(BuildContext context) {
    final api = widget.api;
    final actionsAvailable = api != null;
    final palette = JyPalette.of(context);
    final text = Theme.of(context).textTheme;
    final secondaryButtonStyle = FilledButton.styleFrom(
      backgroundColor: palette.raised,
      foregroundColor: palette.text1,
      side: BorderSide(color: palette.outline),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('配额与生命周期状态')),
      body: ListView(
        padding: const EdgeInsets.all(JySpace.lg),
        children: [
          Text(
            '只读配额/清点；导出为非破坏性，导入为显式写操作（需确认），清理仅只读预览、不执行删除。不代表可用、已授权或已清理。',
            style: text.bodySmall?.copyWith(color: palette.text2),
          ),
          const SizedBox(height: JySpace.md),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(JySpace.xl),
              child: Center(child: JyBusyIndicator(label: '正在读取用量')),
            ),
          if (_unknown)
            StatusPanel(
              key: const Key('lifecycle-unknown'),
              tone: StatusTone.error,
              icon: Icons.help_outline_rounded,
              title: '状态未知：宿主暂不可用，或响应无法验证。不会自动重试或推测配置。',
            ),
          if (!_loading && !_unknown && _quota != null)
            JySlab(
              padding: EdgeInsets.zero,
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
            JySlab(
              padding: EdgeInsets.zero,
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
                onPressed:
                    actionsAvailable && widget.canWritePlaintext && !_busy
                    ? _export
                    : null,
                child: const Text('导出'),
              ),
              FilledButton(
                key: const Key('save-lifecycle'),
                style: secondaryButtonStyle,
                onPressed:
                    actionsAvailable &&
                        widget.canWritePlaintext &&
                        widget.backupFiles != null &&
                        !_busy &&
                        _exported != null
                    ? _saveToFile
                    : null,
                child: const Text('保存到文件'),
              ),
              FilledButton(
                key: const Key('import-lifecycle'),
                style: secondaryButtonStyle,
                onPressed:
                    actionsAvailable &&
                        widget.canWritePlaintext &&
                        !_busy &&
                        _exported != null
                    ? _import
                    : null,
                child: const Text('导入'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (!actionsAvailable)
            const Text('当前入口未接线宿主连接：导出/导入不可用（需装配 LifecycleApi）。'),
          if (actionsAvailable && _exported == null) const Text('导入需先成功导出到内存。'),
          if (actionsAvailable && widget.backupFiles == null)
            const Text('未接线本机文件保存：导出仍可查看，保存到文件不可用。'),
          if (actionsAvailable)
            const Text('保存的文件为聊天明文，不受应用锁保护；宿主导入当前仍为内存参考实现，重启后不会保留。'),
          if (actionsAvailable && !widget.canWritePlaintext)
            JyBanner(
              key: const Key('lifecycle-write-locked'),
              kind: JyBannerKind.info,
              message: '当前已锁定或账号状态已变化：保存和导入已停用。',
            ),
          if (widget.filePreview case final access?)
            BackupFilePreviewPanel(
              access: access,
              enabled: !_busy && widget.canWritePlaintext,
            ),
          if (actionsAvailable) ...[
            Text(
              '清理预览（只读，不执行）',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (_cleanupLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: JySpace.sm),
                child: Center(child: JyBusyIndicator(label: '正在读取清理预览')),
              )
            else if (_cleanupUnknown)
              JyBanner(
                key: const Key('cleanup-preview-unknown'),
                kind: JyBannerKind.error,
                message: '清理预览读取失败或结果未知；不会自动重试。',
              )
            else if (_cleanupPreview != null) ...[
              Text('运行日：${_cleanupPreview!.dayKey}'),
              const Text('将提醒（即将到期）：'),
              _cleanupRows(_cleanupPreview!.remindSoon),
              const Text('将过期删除（blob 将被清理，保留消息占位）：'),
              _cleanupRows(_cleanupPreview!.expiring),
              const Text('当前持有的可过期媒体：'),
              _cleanupRows(_cleanupPreview!.totalHeld),
            ],
            OutlinedButton(
              key: const Key('cleanup-preview-refresh'),
              onPressed: _cleanupLoading ? null : _loadCleanupPreview,
              child: const Text('刷新清理预览'),
            ),
            JyBanner(
              key: const Key('cleanup-execution-gap'),
              kind: JyBannerKind.info,
              message: '执行尚未提供：宿主仅有每日系统清理任务，本页只做只读预览，不会删除任何数据。',
            ),
          ] else
            JyBanner(
              key: const Key('cleanup-execution-gap'),
              kind: JyBannerKind.info,
              message: '清理：宿主未提供清理 HTTP 接口（缺口），本页不执行清理。',
            ),
          if (_actionNotice != null)
            Padding(
              padding: const EdgeInsets.only(top: JySpace.sm),
              child: JyBanner(
                key: const Key('lifecycle-action-notice'),
                kind: _noticeKind(_actionNotice!),
                message: _actionNotice!,
              ),
            ),
        ],
      ),
    );
  }
}
