import 'package:material_ui/material_ui.dart';

import '../../app/status_panel.dart';
import '../../net/creative_api.dart';
import '../../ui/ui.dart';
import 'creative_report_detail.dart';

/// Read-only creative surface for the merged host creative endpoints:
/// relationship weekly/annual reports (CR-03) and late-night radio (CR-07).
///
/// The screen never writes consent, never starts generation, never plays audio
/// and never infers availability. When no host loader is wired (offline or an
/// unbound shell) it reports an honest unknown state instead of inventing
/// content. Empty host lists are reported as honest empty states, distinct from
/// an unbound or failed load.
class CreativeScreen extends StatefulWidget {
  const CreativeScreen({
    super.key,
    this.loadReports,
    this.loadRadio,
    this.sessionContext,
    this.sessionChanges,
  });

  /// Host-backed readers. [CreativeApi.listReports] / [CreativeApi.listRadio]
  /// satisfy these once a connection is available; tests inject them directly.
  final Future<List<CreativeReportSummary>> Function()? loadReports;
  final Future<List<CreativeRadioEpisode>> Function()? loadRadio;

  /// A non-null runtime identity for this authenticated, unlocked session.
  /// The shell notifies on changes so even transient interruptions invalidate
  /// the previously loaded data.
  final Object? Function()? sessionContext;
  final Listenable? sessionChanges;

  @override
  State<CreativeScreen> createState() => _CreativeScreenState();
}

class _CreativeScreenState extends State<CreativeScreen> {
  List<CreativeReportSummary>? _reports;
  List<CreativeRadioEpisode>? _radio;
  bool _loading = false;
  bool _failed = false;
  final _expanded = <String>{};

  // Like device sessions, this view stays invalidated after leaving the
  // opening session. Reopening the tab must be an explicit user action.
  late final Object? _openingContext;
  late final Listenable? _sessionChanges;
  bool _sessionInvalid = false;

  @override
  void initState() {
    super.initState();
    _openingContext = widget.sessionContext?.call();
    _sessionChanges = widget.sessionChanges;
    _sessionChanges?.addListener(_onSessionChanged);
    _load();
  }

  @override
  void didUpdateWidget(CreativeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(_sessionChanges, widget.sessionChanges) ||
        !_sessionMatches) {
      _invalidateSession();
    }
  }

  @override
  void dispose() {
    _sessionChanges?.removeListener(_onSessionChanged);
    super.dispose();
  }

  bool get _sessionMatches =>
      !_sessionInvalid &&
      (widget.sessionContext == null
          ? _sessionChanges == null
          : _openingContext != null &&
                widget.sessionContext!() == _openingContext);

  void _invalidateSession() {
    if (_sessionInvalid) return;
    setState(() {
      _sessionInvalid = true;
      _reports = null;
      _radio = null;
      _loading = false;
      _failed = false;
      _expanded.clear();
    });
  }

  void _onSessionChanged() {
    // Even if the session changes back before the next frame, discard the old
    // list and expanded subtree now instead of letting it become visible again.
    if (mounted && !_sessionMatches) _invalidateSession();
  }

  Future<void> _load() async {
    if (!mounted || !_sessionMatches || _loading) return;
    final reports = widget.loadReports;
    final radio = widget.loadRadio;
    if (reports == null || radio == null) return;
    setState(() {
      _loading = true;
      _failed = false;
      _reports = null;
      _radio = null;
      _expanded.clear();
    });
    try {
      final loadedReports = await reports();
      if (!mounted || !_sessionMatches) return;
      final loadedRadio = await radio();
      if (!mounted || !_sessionMatches) return;
      setState(() {
        _reports = List.unmodifiable(loadedReports);
        _radio = List.unmodifiable(loadedRadio);
        _loading = false;
      });
    } catch (_) {
      // Never surface upstream response bodies, ids or provider prose.
      if (!mounted || !_sessionMatches) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  static String _kindLabel(String kind) => kind == 'annual' ? '年报' : '周报';

  static String _statusLabel(String status) => switch (status) {
    'generated' => '已生成',
    'missed' => '已错过',
    'deferred' => '待重试',
    _ => '状态未知',
  };

  static String _clip(String text) {
    final trimmed = text.trim();
    if (trimmed.length <= 24) return trimmed;
    return '${trimmed.substring(0, 24)}…';
  }

  static String _topics(CreativeReport report) {
    final labels = report.commonTopics
        .take(3)
        .map((topic) => topic.label)
        .where((label) => label.isNotEmpty)
        .toList();
    return labels.isEmpty ? '' : '共同话题：${labels.join('、')}';
  }

  double get _pagePad => MediaQuery.sizeOf(context).width < 720
      ? JySpace.pageNarrow
      : JySpace.pageWide;

  @override
  Widget build(BuildContext context) {
    final palette = JyPalette.of(context);
    final text = Theme.of(context).textTheme;
    final bound = widget.loadReports != null && widget.loadRadio != null;
    if (!_sessionMatches) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(_pagePad),
              child: StatusPanel(
                key: const Key('creative-session-invalid'),
                icon: Icons.lock_outline_rounded,
                title: '动态已清除',
                detail: '登录、锁定或账号已变化；报告信息已清除，请重新打开动态。',
              ),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: _pagePad),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: JySpace.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _loading ? '正在读取宿主创作数据…' : '只读展示；可下拉或点右侧刷新重新读取（无自动重试）。',
                        style: text.bodySmall?.copyWith(color: palette.text3),
                      ),
                    ),
                    JyPressable(
                      borderRadius: BorderRadius.circular(JyRadius.md),
                      child: TextButton.icon(
                        key: const Key('creative-refresh'),
                        onPressed: _loading || !bound ? null : _load,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('刷新'),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _body(context, bound, text)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, bool bound, TextTheme text) {
    final palette = JyPalette.of(context);
    final Widget child;
    if (_loading) {
      child = Center(
        key: const ValueKey('creative-loading'),
        child: const Padding(
          padding: EdgeInsets.all(JySpace.xl),
          child: JyBusyIndicator(label: '正在读取动态'),
        ),
      );
    } else if (!bound) {
      child = Center(
        key: const ValueKey('creative-unbound-state'),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(JySpace.xl),
          child: StatusPanel(
            key: const Key('creative-unbound'),
            tone: StatusTone.offline,
            icon: Icons.link_off_rounded,
            title: '还没有连接宿主',
            detail: '创作内容需要接入宿主连接后显示；宿主读取接口已就绪。',
          ),
        ),
      );
    } else if (_failed) {
      child = Center(
        key: const ValueKey('creative-failed'),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(JySpace.xl),
          child: StatusPanel(
            tone: StatusTone.error,
            icon: Icons.cloud_off_rounded,
            title: '没能读取动态',
            detail: '读取失败，请稍后重试；不会自动重试。',
            action: FilledButton.tonal(
              key: const Key('creative-retry'),
              style: FilledButton.styleFrom(
                backgroundColor: palette.signalSoft,
                foregroundColor: palette.onSignalSoft,
              ),
              onPressed: _load,
              child: const Text('手动重试'),
            ),
          ),
        ),
      );
    } else {
      child = KeyedSubtree(
        key: const ValueKey('creative-content'),
        child: _content(context, text),
      );
    }
    return JySwitcher(child: child);
  }

  Widget _content(BuildContext context, TextTheme text) {
    final palette = JyPalette.of(context);
    final reports = _reports ?? const <CreativeReportSummary>[];
    final radio = _radio ?? const <CreativeRadioEpisode>[];
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: JySpace.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: ExcludeSemantics(
                child: Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: palette.text3,
                ),
              ),
            ),
            const SizedBox(width: JySpace.sm),
            Expanded(
              child: Text(
                '数据来自宿主实时读取；以下为只读展示，本页不触发生成或播放。',
                key: const Key('creative-live-note'),
                style: text.bodySmall?.copyWith(color: palette.text3),
              ),
            ),
          ],
        ),
      ),
      const JySectionHeader(title: '关系周报 / 年报'),
      if (reports.isEmpty)
        _emptyCard(context, '暂无周报或年报。', const Key('creative-empty-reports'))
      else
        for (var i = 0; i < reports.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: JySpace.md),
            child: JyEntrance(
              index: i,
              child: _reportCard(context, reports[i]),
            ),
          ),
      const SizedBox(height: JySpace.lg),
      const JySectionHeader(title: '深夜电台'),
      if (radio.isEmpty)
        _emptyCard(context, '暂无电台期次。', const Key('creative-empty-radio'))
      else
        JyGroup(
          children: [for (final episode in radio) _radioRow(context, episode)],
        ),
      const SizedBox(height: JySpace.xl),
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [for (final child in children) _bounded(child)],
      ),
    );
  }

  /// Keeps the single column readable on wide layouts.
  Widget _bounded(Widget child) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: child,
    ),
  );

  Widget _emptyCard(BuildContext context, String message, Key key) {
    final palette = JyPalette.of(context);
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: JySpace.md),
      child: JySlab(
        tone: JyTone.raised,
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: palette.text3,
              ),
            ),
            const SizedBox(width: JySpace.sm),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: palette.text2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reportCard(BuildContext context, CreativeReportSummary summary) {
    final palette = JyPalette.of(context);
    final text = Theme.of(context).textTheme;
    final key = ValueKey((summary.aiId, summary.kind, summary.periodKey));
    final icon = summary.kind == 'annual'
        ? Icons.auto_awesome_outlined
        : Icons.article_outlined;
    final title = Text(
      '${_kindLabel(summary.kind)} · ${summary.periodKey}',
      style: text.titleMedium?.copyWith(color: palette.text1),
    );
    final leading = JyIconTile(icon: icon, color: palette.onEmberSoft);
    final report = summary.report;
    final usable =
        summary.status == 'generated' &&
        report != null &&
        report.kind == summary.kind &&
        report.periodKey == summary.periodKey;
    final status = _statusLabel(summary.status);
    final topics = usable ? _topics(report) : '';
    final subtitle = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'AI：${summary.aiId}',
          style: text.bodySmall?.copyWith(color: palette.text2),
        ),
        Text(switch ((summary.status, usable, topics.isEmpty)) {
          ('generated', false, _) => '$status · 缺少报告内容',
          ('generated', true, false) => '$status · $topics',
          _ => status,
        }, style: text.bodyMedium?.copyWith(color: palette.text2)),
      ],
    );
    if (!usable) {
      return JySlab(
        padding: EdgeInsets.zero,
        child: ListTile(
          key: key,
          leading: leading,
          title: title,
          subtitle: subtitle,
        ),
      );
    }
    final id = '${summary.aiId}|${summary.kind}|${summary.periodKey}';
    final expanded = _expanded.contains(id);
    return JyPressable(
      borderRadius: BorderRadius.circular(JyRadius.lg),
      child: JySlab(
        padding: EdgeInsets.zero,
        child: ExpansionTile(
          key: key,
          leading: leading,
          title: title,
          subtitle: subtitle,
          trailing: JyChevron(expanded: expanded),
          onExpansionChanged: (open) =>
              setState(() => open ? _expanded.add(id) : _expanded.remove(id)),
          expansionAnimationStyle: AnimationStyle(
            duration: JyMotion.of(context, JyDurations.standard),
            curve: JyCurves.enter,
            reverseCurve: JyCurves.exit,
          ),
          children: [CreativeReportDetail(report: report)],
        ),
      ),
    );
  }

  Widget _radioRow(BuildContext context, CreativeRadioEpisode episode) {
    final palette = JyPalette.of(context);
    final text = Theme.of(context).textTheme;
    return ListTile(
      key: ValueKey('radio-${episode.dateKey}'),
      minTileHeight: JySpace.rowMinHeight,
      leading: JyIconTile(
        icon: episode.playableOffline
            ? Icons.offline_pin_outlined
            : Icons.play_circle_outline,
        color: palette.onEmberSoft,
      ),
      title: Text(
        episode.dateKey,
        style: text.titleMedium?.copyWith(
          color: palette.text1,
          fontFeatures: JyTypography.tabularFigures,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '音色 ${_clip(episode.voiceId)} · '
            '${episode.playableOffline ? '可离线播放' : '在线播放'}',
            style: text.bodyMedium?.copyWith(color: palette.text2),
          ),
          Text(
            _clip(episode.script.text),
            style: text.bodySmall?.copyWith(color: palette.text3),
          ),
        ],
      ),
    );
  }
}
