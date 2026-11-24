import 'dart:math' as math;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../app/status_panel.dart';
import '../../net/host_connection.dart';
import '../../net/search_api.dart';
import '../../ui/jy_motion.dart';
import '../../ui/jy_palette.dart';
import '../../ui/jy_tokens.dart';
import '../../ui/jy_typography.dart';

/// Signature the settings entry binds to [SearchApi.searchMessages].
typedef MessageSearcher = Future<SearchOutcome> Function(
  String query, {
  required int limit,
  String? senderId,
  MessageKind? kind,
  DateTime? from,
  DateTime? to,
});

enum _Phase {
  unbound,
  idle,
  loading,
  empty,
  denied,
  unavailable,
  malformed,
  ready,
}

/// Honest, read-only global message search over the merged host route.
///
/// Nothing is fetched when the screen opens: the user types a query and submits
/// it explicitly. Tapping a hit opens nothing, because this slice has no result
/// navigation; it only unfolds a snippet that is longer than three lines. Every
/// failure is a distinct state — denied, unavailable and malformed are never
/// collapsed into "no results".
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

  /// What sits under the query: the idle hint, a spinner, a status panel or
  /// the hits.
  List<Widget> _results(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return switch (_phase) {
      _Phase.unbound => const <Widget>[],
      _Phase.idle => <Widget>[
        Text(
          '尚未搜索：输入关键词后点击“搜索”。打开本页不会自动发起请求。',
          key: const Key('search-idle'),
          style: text.bodyMedium?.copyWith(color: palette.text2),
        ),
      ],
      _Phase.loading => const <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(vertical: JySpace.x3),
          child: Center(child: CircularProgressIndicator()),
        ),
      ],
      _Phase.denied => const <Widget>[
        StatusPanel(
          key: Key('search-denied'),
          icon: Icons.lock_outline,
          title:
              '未登录或无权限：宿主拒绝了本次搜索。这不代表没有匹配，'
              '也不代表任何消息不存在。',
          tone: StatusTone.error,
        ),
      ],
      _Phase.unavailable => const <Widget>[
        StatusPanel(
          key: Key('search-unavailable'),
          icon: Icons.cloud_off_outlined,
          title: '宿主暂不可用或请求失败，结果未知（未知≠无结果）。不会自动重试，请稍后手动重新搜索。',
          tone: StatusTone.error,
        ),
      ],
      _Phase.malformed => const <Widget>[
        StatusPanel(
          key: Key('search-malformed'),
          icon: Icons.error_outline,
          title: '宿主响应不符合约定格式，本次结果已整体丢弃，未显示任何命中。',
          tone: StatusTone.error,
        ),
      ],
      _Phase.empty => <Widget>[
        StatusPanel(
          key: const Key('search-empty'),
          icon: Icons.search_off,
          title:
              '没有命中：“${_submitted ?? ''}”。这只表示宿主本次没有返回命中，'
              '不代表该词在全部历史中不存在（扫描有界，盲索引可能未覆盖）。',
        ),
      ],
      _Phase.ready => <Widget>[
        Column(
          key: const Key('search-results'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '命中 ${_hits.length} 条（宿主返回顺序，未排序、未评分；'
              '条数受上限约束，不代表全部匹配）',
              style: text.bodySmall?.copyWith(
                color: palette.text2,
                fontFeatures: JyTypography.tabularFigures,
              ),
            ),
            for (final SearchHit hit in _hits) ...<Widget>[
              const SizedBox(height: JySpace.md),
              _HitCard(key: Key('search-hit-${hit.messageId}'), hit: hit),
            ],
          ],
        ),
      ],
    };
  }

  @override
  Widget build(BuildContext context) {
    if (!_sessionCurrent) _invalidateSession();
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('消息搜索')),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double side = _pageInset(constraints.maxWidth);
          return ListView(
            padding: EdgeInsets.fromLTRB(
              side + safe.left,
              JySpace.lg,
              side + safe.right,
              JySpace.x3 + safe.bottom,
            ),
            children: <Widget>[
              const _Note(
                '全局搜索由宿主执行：当前实现对可读会话做有界解密扫描，'
                '并优先使用加密盲索引候选。这里不是客户端全文索引，不排序、不评分，'
                '也不保证覆盖全部历史或返回全部匹配。',
                textKey: Key('search-mechanism-note'),
              ),
              const SizedBox(height: JySpace.lg),
              if (widget.search == null)
                const _Banner(
                  '当前入口未接线宿主连接：消息搜索不可用（需装配 SearchApi）。',
                  key: Key('search-unbound'),
                  icon: Icons.link_off,
                )
              else if (_sessionInvalidated)
                const _Banner(
                  '登录或锁定状态已变化。旧搜索已清除，请返回后重新打开消息搜索。',
                  key: Key('search-invalidated'),
                  icon: Icons.lock_outline,
                  announce: true,
                )
              else ...<Widget>[
                _QueryRow(
                  field: TextField(
                    key: const Key('search-query'),
                    controller: _query,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      labelText: '搜索关键词（1–200 字符，留空不搜索）',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  button: FilledButton(
                    key: const Key('search-submit'),
                    onPressed: _busy ? null : _submit,
                    child: Text(_busy ? '搜索中…' : '搜索'),
                  ),
                ),
                const SizedBox(height: JySpace.lg),
                ..._results(context),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// One hit as the host returned it: the snippet, then one line per field.
///
/// A snippet longer than three lines folds, and tapping the card unfolds or
/// folds it again; a card whose snippet fits does not react to taps. A hit
/// never opens its conversation and never searches again.
class _HitCard extends StatefulWidget {
  const _HitCard({super.key, required this.hit});

  final SearchHit hit;

  @override
  State<_HitCard> createState() => _HitCardState();
}

class _HitCardState extends State<_HitCard> {
  bool _expanded = false;

  /// Lines a folded snippet shows.
  static const int _foldedLines = 3;

  @override
  void didUpdateWidget(_HitCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new search folds the snippet again.
    if (!identical(oldWidget.hit, widget.hit)) _expanded = false;
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
    return collapsed.length <= 160
        ? collapsed
        : '${collapsed.substring(0, 160)}…';
  }

  /// Whether [snippet] needs more than [_foldedLines] lines at [width].
  static bool _folds(
    BuildContext context,
    String snippet,
    TextStyle? style,
    double width,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: snippet,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      maxLines: _foldedLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width);
    final bool folds = painter.didExceedMaxLines;
    painter.dispose();
    return folds;
  }

  @override
  Widget build(BuildContext context) {
    final SearchHit hit = widget.hit;
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final bool reduced = JyMotion.reducedOf(context);
    final String snippet = _snippet(hit);
    final TextStyle? snippetStyle = text.titleMedium?.copyWith(
      color: palette.text1,
    );
    final TextStyle? meta = text.bodySmall?.copyWith(
      color: palette.text2,
      fontFeatures: JyTypography.tabularFigures,
    );
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Measured at the full width: a snippet that folds there also
          // folds next to the chevron, and one that fits gets no chevron.
          final bool folds = _folds(
            context,
            snippet,
            snippetStyle,
            math.max(0.0, constraints.maxWidth - 2 * JySpace.lg),
          );
          final Widget content = Padding(
            padding: const EdgeInsets.all(JySpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      // With reduced motion the snippet changes size at once.
                      child: AnimatedSize(
                        duration: reduced
                            ? Duration.zero
                            : JyDurations.standard,
                        curve: JyCurves.enter,
                        alignment: AlignmentDirectional.topStart,
                        child: Text(
                          snippet,
                          style: snippetStyle,
                          maxLines: _expanded ? null : _foldedLines,
                          overflow: _expanded ? null : TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    if (folds) ...<Widget>[
                      const SizedBox(width: JySpace.sm),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: reduced ? Duration.zero : JyDurations.quick,
                        curve: JyCurves.emphasized,
                        child: Icon(Icons.expand_more, color: palette.signal),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: JySpace.sm),
                Wrap(
                  spacing: JySpace.lg,
                  runSpacing: JySpace.xs,
                  children: <Widget>[
                    Text('会话：${hit.conversationId}', style: meta),
                    Text('发送者：${hit.senderId}', style: meta),
                    Text('类型：${hit.kind.wire}', style: meta),
                    Text('序号：${hit.seq}', style: meta),
                    Text(
                      '时间：${hit.sentAt.toIso8601String()}',
                      style: meta?.copyWith(color: palette.text3),
                    ),
                    Text('命中方式：${_modeLabel(hit.mode)}', style: meta),
                  ],
                ),
              ],
            ),
          );
          if (!folds) return content;
          return Semantics(
            container: true,
            button: true,
            expanded: _expanded,
            onTapHint: _expanded ? '收起摘要' : '展开摘要',
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: content,
            ),
          );
        },
      ),
    );
  }
}

/// Widest the content column gets; wider windows centre it.
const double _maxContentWidth = 720;

/// Page side padding: 16 on narrow layouts, 24 from 720 up, and on wide
/// windows enough to keep the content column [_maxContentWidth] wide.
double _pageInset(double width) {
  if (width < _maxContentWidth) {
    return JySpace.pageNarrow;
  }
  return math.max(JySpace.pageWide, (width - _maxContentWidth) / 2);
}

/// The query and its button: side by side from [_sideBySide] wide, the
/// button under the field below that.
class _QueryRow extends StatelessWidget {
  const _QueryRow({required this.field, required this.button});

  final Widget field;
  final Widget button;

  static const double _sideBySide = 520;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= _sideBySide) {
          return Row(
            children: <Widget>[
              Expanded(child: field),
              const SizedBox(width: JySpace.md),
              button,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            field,
            const SizedBox(height: JySpace.md),
            button,
          ],
        );
      },
    );
  }
}

/// What the page does and does not do: text2 on a raised block. [textKey]
/// goes on the Text itself, where the tests read it.
class _Note extends StatelessWidget {
  const _Note(this.message, {this.textKey});

  final String message;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: palette.raised,
        shape: JyShapes.rounded(
          JyRadius.lg,
          side: BorderSide(color: palette.hairline),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(JySpace.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.info_outline, size: 20, color: palette.text2),
            const SizedBox(width: JySpace.md),
            Expanded(
              child: Text(
                message,
                key: textKey,
                style: text.bodySmall?.copyWith(color: palette.text2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An info notice on signalSoft, announced as a live region when [announce]
/// is set. Stands in for JyBanner until the lib/ui components land.
class _Banner extends StatelessWidget {
  const _Banner(
    this.message, {
    super.key,
    required this.icon,
    this.announce = false,
  });

  final String message;
  final IconData icon;
  final bool announce;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      liveRegion: announce,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: palette.signalSoft,
          shape: JyShapes.rounded(JyRadius.md),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: JySpace.lg,
            vertical: JySpace.md,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, size: 20, color: palette.onSignalSoft),
              const SizedBox(width: JySpace.md),
              Expanded(
                child: Text(
                  message,
                  style: text.bodyMedium?.copyWith(color: palette.onSignalSoft),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
