import 'package:material_ui/material_ui.dart';

import '../../ui/ui.dart';
import 'backup_file_preview.dart';

/// Capabilities captured when Settings opens the lifecycle route. The picker
/// may handle private paths internally; the panel receives only a safe summary.
typedef BackupFilePreviewAccess = ({
  Listenable session,
  bool Function() isCurrent,
  Future<BackupFilePreviewSummary?> Function(bool Function() isCurrent) pick,
});

class BackupFilePreviewPanel extends StatefulWidget {
  const BackupFilePreviewPanel({
    super.key,
    required this.access,
    required this.enabled,
  });

  final BackupFilePreviewAccess access;
  final bool enabled;

  @override
  State<BackupFilePreviewPanel> createState() => _BackupFilePreviewPanelState();
}

class _BackupFilePreviewPanelState extends State<BackupFilePreviewPanel> {
  late final BackupFilePreviewAccess _access;
  ModalRoute<dynamic>? _route;
  int _generation = 0;
  bool _invalid = false;
  bool _reading = false;
  BackupFilePreviewSummary? _summary;
  String? _notice;
  bool _noticeFailed = false;

  @override
  void initState() {
    super.initState();
    _access = widget.access;
    _invalid = !_access.isCurrent();
    _access.session.addListener(_onSessionChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route) || route?.isCurrent == false) _clear();
    _route = route;
  }

  @override
  void didUpdateWidget(covariant BackupFilePreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _onSessionChanged();
  }

  @override
  void dispose() {
    _access.session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _clear() {
    _generation++;
    _reading = false;
    _summary = null;
    _notice = null;
    _noticeFailed = false;
  }

  bool get _sessionMatches => widget.access == _access && _access.isCurrent();

  void _onSessionChanged() {
    if (!mounted || _invalid || _sessionMatches) return;
    // A rapid lock/unlock must not make an old picker callback usable again.
    setState(() {
      _invalid = true;
      _clear();
    });
  }

  Future<void> _pick(int generation) async {
    _onSessionChanged();
    if (!mounted ||
        _invalid ||
        _reading ||
        !widget.enabled ||
        generation != _generation ||
        _route?.isCurrent == false) {
      return;
    }
    setState(() {
      _clear();
      _reading = true;
    });
    final request = _generation;
    bool isCurrent() =>
        mounted &&
        !_invalid &&
        request == _generation &&
        _sessionMatches &&
        _route?.isCurrent != false;

    BackupFilePreviewSummary? summary;
    String? notice;
    // Refusals and read failures take the error tone; a cancelled pick or an
    // interrupted check is only information.
    bool failed = false;
    try {
      summary = await _access.pick(isCurrent);
      if (summary == null) notice = '已取消选择。';
    } on BackupFilePreviewException catch (error) {
      failed = error.problem != BackupFilePreviewProblem.interrupted;
      notice = switch (error.problem) {
        BackupFilePreviewProblem.unreadable => '无法读取所选文件。请选择本机的导出文件。',
        BackupFilePreviewProblem.tooLarge => '文件超过 4 MiB，无法预检。',
        BackupFilePreviewProblem.invalid => '包格式或校验和无效，未显示摘要。',
        BackupFilePreviewProblem.wrongOwner => '导出包不属于当前账号，无法预检。',
        BackupFilePreviewProblem.interrupted => '本次预检已中止。',
      };
    } catch (_) {
      failed = true;
      notice = '无法预检所选文件。';
    }
    _onSessionChanged();
    if (!isCurrent()) return;
    setState(() {
      _reading = false;
      _summary = summary;
      _notice = notice;
      _noticeFailed = failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final BackupFilePreviewSummary? summary = _summary;
    final String? notice = _notice;
    final int generation = _generation;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: JySpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text('本机导出包预检', style: text.titleSmall),
          ),
          const SizedBox(height: JySpace.xs),
          Text(
            'Windows · 仅当前账号的 v1 JSON 导出包（最多 4 MiB）。只读，不上传、不导入，也不是加密恢复。',
            style: text.bodySmall?.copyWith(color: palette.text2),
          ),
          const SizedBox(height: JySpace.md),
          OutlinedButton.icon(
            key: const Key('preview-backup-file'),
            onPressed: _invalid || !widget.enabled || _reading
                ? null
                : () => _pick(generation),
            icon: const Icon(Icons.fact_check_outlined),
            // The label changes within the frame: callers wait for the
            // pending label to go away.
            label: Text(_reading ? '正在选择或预检…' : '选择导出文件并预检'),
          ),
          JyExpand(
            expanded: _invalid || notice != null || summary != null,
            child: _invalid
                ? const Padding(
                    padding: EdgeInsets.only(top: JySpace.md),
                    child: JyBanner(
                      kind: JyBannerKind.info,
                      message: '本次预检会话已结束。请返回后重新打开。',
                    ),
                  )
                : notice != null
                ? Padding(
                    padding: const EdgeInsets.only(top: JySpace.md),
                    child: JyBanner(
                      key: const Key('backup-file-preview-notice'),
                      kind: _noticeFailed
                          ? JyBannerKind.error
                          : JyBannerKind.info,
                      message: notice,
                    ),
                  )
                : summary != null
                ? Padding(
                    padding: const EdgeInsets.only(top: JySpace.md),
                    child: _SummaryBlock(summary),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// The checked package in a raised block. Each line is still its own Text,
/// and no path, file name or owner is shown.
class _SummaryBlock extends StatelessWidget {
  const _SummaryBlock(this.summary);

  final BackupFilePreviewSummary summary;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final TextStyle? line = text.bodySmall?.copyWith(
      color: palette.text2,
      fontFeatures: JyTypography.tabularFigures,
    );
    return DecoratedBox(
      key: const Key('backup-file-preview-summary'),
      decoration: ShapeDecoration(
        color: palette.raised,
        shape: JyShapes.rounded(
          JyRadius.md,
          side: BorderSide(color: palette.hairline),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(JySpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.task_alt, size: 20, color: palette.success),
                const SizedBox(width: JySpace.sm),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      '预检通过：文件与校验和清单一致，仅供本机查看。',
                      style: text.titleSmall?.copyWith(color: palette.text1),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: JySpace.sm),
            Text(
              '导出时间（UTC）：${summary.generatedAt.toIso8601String()}',
              style: line,
            ),
            Text(
              '包内文件 ${summary.fileCount} 个 · ${summary.bytes} 字节',
              style: line,
            ),
            Text(
              '清单计数：会话 ${summary.counts['conversations']}，'
              '消息 ${summary.counts['messages']}，'
              '人格 ${summary.counts['persona']}，'
              '记忆 ${summary.counts['memories']}，'
              '附件 ${summary.counts['attachments']}。',
              style: line,
            ),
            if (summary.chatHistoryOnly)
              Text('清单标明仅导出聊天记录，不是完整账号备份。', style: line),
            const SizedBox(height: JySpace.sm),
            Text(
              '校验和不证明来源，也不代表已导入或可恢复。',
              style: text.bodySmall?.copyWith(color: palette.text3),
            ),
          ],
        ),
      ),
    );
  }
}
