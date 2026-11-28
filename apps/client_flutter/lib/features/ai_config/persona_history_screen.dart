import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/host_connection.dart';
import '../../net/persona_history_api.dart';
import '../../ui/ui.dart';

/// Read-only, one-page disclosure within the existing Persona editor card.
class PersonaHistorySection extends StatefulWidget {
  const PersonaHistorySection({
    super.key,
    required this.isCurrent,
    required this.readPage,
  });

  final bool Function() isCurrent;
  final Future<PersonaHistoryPage> Function(
    int afterVersion,
    HostReadCancellation cancellation,
  )?
  readPage;

  @override
  State<PersonaHistorySection> createState() => _PersonaHistorySectionState();
}

class _PersonaHistorySectionState extends State<PersonaHistorySection> {
  ModalRoute<dynamic>? _route;
  HostReadCancellation? _pending;
  PersonaHistoryPage? _page;
  String? _notice;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(_route, route) || route?.isCurrent == false) _clear();
    _route = route;
  }

  @override
  void didUpdateWidget(covariant PersonaHistorySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isCurrent()) _clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  void _clear() {
    _generation++;
    _pending?.cancel();
    _pending = null;
    _page = null;
    _notice = null;
  }

  bool _canPublish(int generation) =>
      mounted &&
      generation == _generation &&
      _route?.isCurrent != false &&
      widget.isCurrent();

  Future<void> _read(int generation, int cursor) async {
    final readPage = widget.readPage;
    if (!_canPublish(generation) || readPage == null || _pending != null) {
      return;
    }
    final token = HostReadCancellation();
    setState(() {
      _clear();
      _pending = token;
    });
    final request = _generation;
    PersonaHistoryPage? page;
    String? notice;
    try {
      page = await readPage(cursor, token);
    } on HostRequestException catch (error) {
      notice = switch (error.failure.code) {
        FailureCode.notFound => '人格未初始化或不可见。',
        FailureCode.unauthenticated || FailureCode.forbidden => '无权读取人格历史。',
        _ => '人格历史暂不可读；可手动重试。',
      };
    } on FormatException {
      notice = '人格历史响应无法验证。';
    } catch (_) {
      notice = '人格历史暂不可读；可手动重试。';
    }
    if (!_canPublish(request)) return;
    setState(() {
      _pending = null;
      _page = page;
      _notice = notice;
    });
  }

  static String _kindLabel(PersonaHistoryKind kind) => switch (kind) {
    PersonaHistoryKind.initialize => '初始化',
    PersonaHistoryKind.selfIterate => '自主迭代',
    PersonaHistoryKind.edit => '编辑',
    PersonaHistoryKind.revert => '历史还原记录',
    PersonaHistoryKind.lock => '锁定状态变更',
  };

  static String _lockLabel(bool locked) => locked ? '锁定' : '未锁定';

  @override
  Widget build(BuildContext context) {
    final generation = _generation;
    final page = _page;
    final next = page?.nextAfterVersion;
    final reading = _pending != null;
    final enabled =
        _route?.isCurrent != false && widget.readPage != null && !reading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('persona-history-read'),
              onPressed: enabled ? () => _read(generation, 0) : null,
              icon: const Icon(Icons.history),
              label: Text(
                reading
                    ? '正在读取人格历史…'
                    : page == null
                    ? '读取人格历史（只读）'
                    : '从头读取人格历史',
              ),
            ),
            if (next != null)
              OutlinedButton(
                key: const Key('persona-history-next'),
                onPressed: enabled ? () => _read(generation, next) : null,
                child: const Text('读取下一页'),
              ),
          ],
        ),
        if (_notice case final notice?)
          Padding(
            padding: const EdgeInsets.only(top: JySpace.sm),
            child: JyBanner(
              key: const Key('persona-history-notice'),
              kind: JyBannerKind.error,
              message: notice,
            ),
          ),
        if (page != null) ...[
          const Text('按版本升序 · 仅显示变更摘要，不修改人格。'),
          if (page.entries.isEmpty)
            const Text('没有历史记录。')
          else
            for (final entry in page.entries)
              JySlab(
                key: Key('persona-history-version-${entry.version}'),
                tone: JyTone.raised,
                padding: const EdgeInsets.all(JySpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '版本 ${entry.version} · ${_kindLabel(entry.kind)}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text('时间（UTC）：${entry.at.toIso8601String()}'),
                    Text(
                      '锁定：${entry.lockedBefore == null ? '' : '${_lockLabel(entry.lockedBefore!)} → '}${_lockLabel(entry.lockedAfter)}',
                    ),
                    Text(
                      '变更字段数：P0 ${entry.changedFields['p0']} · P1 ${entry.changedFields['p1']} · P2 ${entry.changedFields['p2']}',
                    ),
                  ],
                ),
              ),
        ],
      ],
    );
  }
}
