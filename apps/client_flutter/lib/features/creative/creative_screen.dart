import 'package:material_ui/material_ui.dart';

import '../../net/creative_api.dart';

/// Read-only creative surface for the merged host creative endpoints:
/// relationship weekly/annual reports (CR-03) and late-night radio (CR-07).
///
/// The screen never writes consent, never starts generation, never plays audio
/// and never infers availability. When no host loader is wired (offline or an
/// unbound shell) it reports an honest unknown state instead of inventing
/// content. Empty host lists are reported as honest empty states, distinct from
/// an unbound or failed load.
class CreativeScreen extends StatefulWidget {
  const CreativeScreen({super.key, this.loadReports, this.loadRadio});

  /// Host-backed readers. [CreativeApi.listReports] / [CreativeApi.listRadio]
  /// satisfy these once a connection is available; tests inject them directly.
  final Future<List<CreativeReportSummary>> Function()? loadReports;
  final Future<List<CreativeRadioEpisode>> Function()? loadRadio;

  @override
  State<CreativeScreen> createState() => _CreativeScreenState();
}

class _CreativeScreenState extends State<CreativeScreen> {
  List<CreativeReportSummary>? _reports;
  List<CreativeRadioEpisode>? _radio;
  bool _loading = true;
  bool _unbound = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final reports = widget.loadReports;
    final radio = widget.loadRadio;
    if (reports == null || radio == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _unbound = true;
          _reports = null;
          _radio = null;
          _failed = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _unbound = false;
        _failed = false;
      });
    }
    try {
      final loadedReports = await reports();
      final loadedRadio = await radio();
      if (!mounted) return;
      setState(() {
        _reports = List.unmodifiable(loadedReports);
        _radio = List.unmodifiable(loadedRadio);
        _loading = false;
      });
    } catch (_) {
      // Never surface upstream response bodies, ids or provider prose.
      if (!mounted) return;
      setState(() {
        _reports = null;
        _radio = null;
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

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final bound = widget.loadReports != null && widget.loadRadio != null;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _loading ? '正在读取宿主创作数据…' : '只读展示；可下拉或点右侧刷新重新读取（无自动重试）。',
                      style: text.bodySmall,
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('creative-refresh'),
                    onPressed: _loading || !bound ? null : _load,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('刷新'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _unbound
                  ? _message(
                      key: const Key('creative-unbound'),
                      icon: Icons.photo_library_outlined,
                      title: '动态',
                      detail: '创作内容需要接入宿主连接后显示；宿主读取接口已就绪。',
                      text: text,
                    )
                  : _failed
                  ? _failedView(text)
                  : _content(text),
            ),
          ],
        ),
      ),
    );
  }

  Widget _failedView(TextTheme text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 40),
          const SizedBox(height: 16),
          Text('动态', style: text.titleMedium),
          const SizedBox(height: 8),
          const Text('读取失败，请稍后重试；不会自动重试。', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.tonal(
            key: const Key('creative-retry'),
            onPressed: _load,
            child: const Text('手动重试'),
          ),
        ],
      ),
    ),
  );

  Widget _content(TextTheme text) {
    final reports = _reports ?? const <CreativeReportSummary>[];
    final radio = _radio ?? const <CreativeRadioEpisode>[];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          const Padding(
            key: Key('creative-live-note'),
            padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text('数据来自宿主实时读取；以下为只读展示，本页不触发生成或播放。'),
          ),
          _sectionTitle('关系周报 / 年报', text),
          if (reports.isEmpty)
            _emptyRow('暂无周报或年报。', const Key('creative-empty-reports'))
          else
            for (final summary in reports)
              ListTile(
                key: ValueKey('report-${summary.kind}-${summary.periodKey}'),
                leading: Icon(
                  summary.kind == 'annual'
                      ? Icons.auto_awesome_outlined
                      : Icons.article_outlined,
                ),
                title: Text(
                  '${_kindLabel(summary.kind)} · ${summary.periodKey}',
                ),
                subtitle: Text(_reportSubtitle(summary)),
              ),
          const Divider(),
          _sectionTitle('深夜电台', text),
          if (radio.isEmpty)
            _emptyRow('暂无电台期次。', const Key('creative-empty-radio'))
          else
            for (final episode in radio)
              ListTile(
                key: ValueKey('radio-${episode.dateKey}'),
                leading: Icon(
                  episode.playableOffline
                      ? Icons.offline_pin_outlined
                      : Icons.play_circle_outline,
                ),
                title: Text(episode.dateKey),
                subtitle: Text(
                  '音色 ${_clip(episode.voiceId)} · '
                  '${episode.playableOffline ? '可离线播放' : '在线播放'}',
                ),
                trailing: Text(_clip(episode.script.text)),
              ),
        ],
      ),
    );
  }

  String _reportSubtitle(CreativeReportSummary summary) {
    final status = _statusLabel(summary.status);
    final report = summary.report;
    if (report == null) return status;
    final topics = _topics(report);
    return topics.isEmpty ? status : '$status · $topics';
  }

  Widget _sectionTitle(String title, TextTheme text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Text(title, style: text.titleSmall),
  );

  Widget _emptyRow(String message, Key key) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    child: Text(message),
  );

  Widget _message({
    Key? key,
    required IconData icon,
    required String title,
    required String detail,
    required TextTheme text,
  }) => Center(
    key: key,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40),
          const SizedBox(height: 16),
          Text(title, style: text.titleMedium),
          const SizedBox(height: 8),
          Text(detail, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
