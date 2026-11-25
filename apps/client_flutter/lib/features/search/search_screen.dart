import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../net/host_connection.dart';
import '../../net/search_api.dart';

/// Signature the settings entry binds to [SearchApi.searchMessages].
typedef MessageSearcher =
    Future<SearchOutcome> Function(
      String query, {
      required int limit,
      String? senderId,
      MessageKind? kind,
      DateTime? from,
      DateTime? to,
    });

enum _Phase { unbound, idle, loading, empty, denied, unavailable, malformed, ready }

/// Honest, read-only global message search over the merged host route.
///
/// Nothing is fetched when the screen opens: the user types a query and submits
/// it explicitly. Nothing is opened when a hit is tapped, because this slice has
/// no result navigation. Every failure is a distinct state — denied, unavailable
/// and malformed are never collapsed into "no results".
///
/// The search itself happens on the host (bounded scan or encrypted blind
/// index). This screen adds no local index, no ranking, no re-matching and no
/// coverage claim; the [SearchHitMode] reported per hit is the host's own.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    this.search,
    this.pageSize = 50,
    this.session,
  });

  /// Host-backed searcher ([SearchApi.searchMessages] in production).
  final MessageSearcher? search;

  /// Optional shell session pin for pushed routes.
  ///
  /// When supplied, the route is private to the account and opaque session
  /// epoch present at first mount. A lock/logout/account change invalidates it
  /// permanently until the route is reopened.
  final ShellViewModel? session;

  /// Page size, 1..100 (host bound).
  final int pageSize;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  List<SearchHit> _hits = const <SearchHit>[];
  _Phase _phase = _Phase.idle;
  bool _busy = false;

  late final ShellViewModel? _session;
  late final String? _accountAtMount;
  late final Object? _sessionAtMount;
  bool _sessionInvalidated = false;

  /// The query that produced the currently displayed result, if any.
  String? _submitted;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _accountAtMount = _session?.connectedAccountId;
    _sessionAtMount = _session?.ownAiSessionContext;
    _session?.addListener(_sessionChanged);
    // Deliberately no request: an empty query is not a search.
    _phase = widget.search == null ? _Phase.unbound : _Phase.idle;
  }

  @override
  void dispose() {
    _session?.removeListener(_sessionChanged);
    _query.dispose();
    super.dispose();
  }

  bool get _sessionCurrent {
    final session = _session;
    if (!identical(widget.session, session)) return false;
    return session == null ||
        (session.authenticated &&
            !session.locked &&
            _accountAtMount != null &&
            _sessionAtMount != null &&
            session.connectedAccountId == _accountAtMount &&
            session.ownAiSessionContext == _sessionAtMount);
  }

  void _invalidateSession() {
    if (_sessionInvalidated) return;
    _sessionInvalidated = true;
    _hits = const <SearchHit>[];
    _submitted = null;
    // Remove the field before notifying its controller listeners.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _query.clear();
    });
  }

  void _sessionChanged() {
    // Latch on the notification, even if lock and unlock occur in one frame.
    if (mounted && !_sessionInvalidated && !_sessionCurrent) {
      setState(_invalidateSession);
    }
  }

  bool _canUseSearch() {
    if (!mounted) return false;
    _sessionChanged();
    return !_sessionInvalidated;
  }

  Future<void> _submit() async {
    if (!_canUseSearch()) return;
    final search = widget.search;
    final raw = _query.text;
    // Empty/whitespace performs no request at all — not even a local filter.
    if (search == null || _busy || raw.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _phase = _Phase.loading;
      _hits = const <SearchHit>[];
      _submitted = raw;
    });
    SearchOutcome outcome;
    try {
      outcome = await search(raw, limit: widget.pageSize);
    } on HostRequestException catch (error) {
      outcome = switch (error.failure.code) {
        FailureCode.unauthenticated ||
        FailureCode.forbidden => const SearchUnauthenticated(),
        _ => const SearchUnavailable(),
      };
    } on FormatException {
      outcome = const SearchMalformed();
    } catch (_) {
      // Transport details never reach the UI; the result is simply unknown.
      outcome = const SearchUnavailable();
    }
    if (!_canUseSearch()) return;
    final _Phase phase;
    final List<SearchHit> rows;
    switch (outcome) {
      case SearchLoaded(isEmpty: true):
        phase = _Phase.empty;
        rows = const <SearchHit>[];
      case SearchLoaded(:final hits):
        phase = _Phase.ready;
        rows = hits;
      case SearchUnauthenticated():
        phase = _Phase.denied;
        rows = const <SearchHit>[];
      case SearchUnavailable():
        phase = _Phase.unavailable;
        rows = const <SearchHit>[];
      case SearchMalformed():
        phase = _Phase.malformed;
        rows = const <SearchHit>[];
    }
    setState(() {
      _busy = false;
      _phase = phase;
      _hits = rows;
    });
  }

  static String _modeLabel(SearchHitMode mode) => switch (mode) {
    SearchHitMode.blind => '盲索引候选',
    SearchHitMode.scan => '有界扫描',
  };

  static String _snippet(SearchHit hit) {
    final text = hit.text;
    if (text == null) return '无文本正文（该消息不含 text 字段）';
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.isEmpty) return '无文本正文（正文为空）';
    return collapsed.length <= 160 ? collapsed : '${collapsed.substring(0, 160)}…';
  }

  Widget _card(SearchHit hit, TextTheme text) => Card(
    key: Key('search-hit-${hit.messageId}'),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_snippet(hit), style: text.titleMedium),
          const SizedBox(height: 6),
          Text('会话：${hit.conversationId}'),
          Text('发送者：${hit.senderId}'),
          Text('类型：${hit.kind.wire}'),
          Text('序号：${hit.seq}'),
          Text('时间：${hit.sentAt.toIso8601String()}'),
          Text('命中方式：${_modeLabel(hit.mode)}'),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_sessionCurrent) _invalidateSession();
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('消息搜索')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '全局搜索由宿主执行：当前实现对可读会话做有界解密扫描，'
            '并优先使用加密盲索引候选。这里不是客户端全文索引，不排序、不评分，'
            '也不保证覆盖全部历史或返回全部匹配。',
            key: Key('search-mechanism-note'),
          ),
          const SizedBox(height: 12),
          if (widget.search == null)
            const Text(
              '当前入口未接线宿主连接：消息搜索不可用（需装配 SearchApi）。',
              key: Key('search-unbound'),
            )
          else if (_sessionInvalidated)
            Semantics(
              liveRegion: true,
              child: const Text(
                '登录或锁定状态已变化。旧搜索已清除，请返回后重新打开消息搜索。',
                key: Key('search-invalidated'),
              ),
            )
          else ...[
            TextField(
              key: const Key('search-query'),
              controller: _query,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: '搜索关键词（1–200 字符，留空不搜索）',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton(
                key: const Key('search-submit'),
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? '搜索中…' : '搜索'),
              ),
            ),
            const SizedBox(height: 12),
            if (_phase == _Phase.idle)
              const Text(
                '尚未搜索：输入关键词后点击“搜索”。打开本页不会自动发起请求。',
                key: Key('search-idle'),
              )
            else if (_phase == _Phase.loading)
              const Center(child: CircularProgressIndicator())
            else if (_phase == _Phase.denied)
              const Text(
                '未登录或无权限：宿主拒绝了本次搜索。这不代表没有匹配，'
                '也不代表任何消息不存在。',
                key: Key('search-denied'),
              )
            else if (_phase == _Phase.unavailable)
              const Text(
                '宿主暂不可用或请求失败，结果未知（未知≠无结果）。不会自动重试，请稍后手动重新搜索。',
                key: Key('search-unavailable'),
              )
            else if (_phase == _Phase.malformed)
              const Text(
                '宿主响应不符合约定格式，本次结果已整体丢弃，未显示任何命中。',
                key: Key('search-malformed'),
              )
            else if (_phase == _Phase.empty)
              Text(
                '没有命中：“${_submitted ?? ''}”。这只表示宿主本次没有返回命中，'
                '不代表该词在全部历史中不存在（扫描有界，盲索引可能未覆盖）。',
                key: const Key('search-empty'),
              )
            else if (_phase == _Phase.ready)
              Column(
                key: const Key('search-results'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '命中 ${_hits.length} 条（宿主返回顺序，未排序、未评分；'
                    '条数受上限约束，不代表全部匹配）',
                    style: text.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  for (final hit in _hits) _card(hit, text),
                ],
              ),
          ],
        ],
      ),
    );
  }
}
