import 'dart:math' as math;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/status_panel.dart';
import '../../net/attachment_api.dart';
import '../../net/host_connection.dart';
import '../../ui/jy_palette.dart';
import '../../ui/jy_tokens.dart';
import '../../ui/jy_typography.dart';

typedef AttachmentLister = Future<List<AttachmentListItem>> Function({
  String? conversationId,
  required int limit,
  DateTime? before,
});

/// Honest, read-only owner-scoped attachment list.
///
/// Consumes `GET /attachments` metadata only (no extracted text, no bytes).
/// States are explicit: unbound (no reader injected), loading, empty, denied,
/// unknown, or a ready list with optional "load more" pagination. Nothing here
/// downloads, decrypts or fabricates attachment content.
class AttachmentsListScreen extends StatefulWidget {
  const AttachmentsListScreen({
    super.key,
    this.listAttachments,
    this.pageSize = 50,
  });

  /// Host-backed lister ([AttachmentApi.listAttachments] in production).
  final AttachmentLister? listAttachments;

  /// Page size, 1..100 (host bound).
  final int pageSize;

  @override
  State<AttachmentsListScreen> createState() => _AttachmentsListScreenState();
}

enum _Phase { unbound, loading, empty, denied, unknown, ready }

class _AttachmentsListScreenState extends State<AttachmentsListScreen> {
  final _conversation = TextEditingController();
  final List<AttachmentListItem> _items = <AttachmentListItem>[];
  _Phase _phase = _Phase.loading;
  String? _notice;
  bool _busy = false;
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    if (widget.listAttachments == null) {
      _phase = _Phase.unbound;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _conversation.dispose();
    super.dispose();
  }

  static String _bytes(int value) {
    const kib = 1024, mib = 1024 * 1024;
    if (value >= mib) return '${(value / mib).toStringAsFixed(1)} MiB';
    if (value >= kib) return '${(value / kib).toStringAsFixed(1)} KiB';
    return '$value B';
  }

  static String _status(String status) => switch (status) {
    'pending' => '抽取中',
    'extracted' => '已抽取',
    'failed' => '抽取失败',
    'unsupported' => '不支持抽取',
    _ => '未知状态',
  };

  Future<void> _load({bool more = false}) async {
    final lister = widget.listAttachments;
    if (lister == null || _busy) return;
    final raw = _conversation.text.trim();
    setState(() {
      _busy = true;
      _notice = null;
      if (!more) {
        _phase = _Phase.loading;
        _items.clear();
        _hasMore = false;
      }
    });
    try {
      final page = await lister(
        conversationId: raw.isEmpty ? null : raw,
        limit: widget.pageSize,
        before: more && _items.isNotEmpty ? _items.last.createdAt : null,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(page);
        _hasMore = page.length == widget.pageSize;
        _phase = _items.isEmpty ? _Phase.empty : _Phase.ready;
      });
    } on HostRequestException catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = switch (error.failure.code) {
          FailureCode.unauthenticated || FailureCode.forbidden => _Phase.denied,
          _ => _Phase.unknown,
        };
        _notice = _phase == _Phase.denied
            ? '无权限查看附件列表；不对结果做推测，不会自动重试。'
            : '读取失败或结果未确认；不会自动重试。';
      });
    } on FormatException {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.unknown;
        _notice = '附件列表响应无效或参数无效；不会自动重试。';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.unknown;
        _notice = '读取失败或结果未确认；不会自动重试。';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One read-only attachment: kind icon, kind, and the metadata lines.
  /// Nothing on the card is tappable.
  Widget _card(AttachmentListItem item) {
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final TextStyle? meta = text.bodySmall?.copyWith(
      color: palette.text2,
      fontFeatures: JyTypography.tabularFigures,
    );
    return Card(
      key: Key('attachment-item-${item.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(JySpace.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _IconTile(icon: _kindIcon(item.kind)),
            const SizedBox(width: JySpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(item.kind, style: text.titleMedium),
                  const SizedBox(height: JySpace.xs),
                  Wrap(
                    spacing: JySpace.lg,
                    runSpacing: JySpace.xs,
                    children: <Widget>[
                      Text('MIME：${item.mime}', style: meta),
                      Text('大小：${_bytes(item.size)}', style: meta),
                      Text('状态：${_status(item.extractionStatus)}', style: meta),
                      Text('会话：${item.conversationId ?? '未绑定会话'}', style: meta),
                      Text(
                        '创建：${item.createdAt.toUtc().toIso8601String()}',
                        style: meta,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What sits under the filter: a spinner, a status panel or the cards.
  List<Widget> _results() => switch (_phase) {
    _Phase.unbound => const <Widget>[],
    _Phase.loading => const <Widget>[
      Padding(
        padding: EdgeInsets.symmetric(vertical: JySpace.x3),
        child: Center(child: CircularProgressIndicator()),
      ),
    ],
    _Phase.denied => <Widget>[
      StatusPanel(
        key: const Key('attachments-denied'),
        icon: Icons.lock_outline,
        title: _notice ?? '无权限查看附件列表。',
        tone: StatusTone.error,
      ),
    ],
    _Phase.unknown => <Widget>[
      StatusPanel(
        key: const Key('attachments-unknown'),
        icon: Icons.error_outline,
        title: _notice ?? '读取失败或结果未确认。',
        tone: StatusTone.error,
      ),
    ],
    _Phase.empty => const <Widget>[
      StatusPanel(
        key: Key('attachments-empty'),
        icon: Icons.inbox_outlined,
        title: '没有可显示的附件（或该会话暂无附件）。',
      ),
    ],
    _Phase.ready => <Widget>[
      for (final (int index, AttachmentListItem item)
          in _items.indexed) ...<Widget>[
        if (index > 0) const SizedBox(height: JySpace.md),
        _card(item),
      ],
      if (_hasMore) ...<Widget>[
        const SizedBox(height: JySpace.sm),
        Center(
          child: TextButton(
            key: const Key('attachments-load-more'),
            onPressed: _busy ? null : () => _load(more: true),
            child: const Text('加载更多'),
          ),
        ),
      ],
    ],
  };

  @override
  Widget build(BuildContext context) {
    final bound = widget.listAttachments != null;
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('附件列表')),
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
                '只读列出当前账号的附件元数据（类型/大小/状态/会话）；'
                '不显示、不存储提取正文或文件字节。不代表可发送、可下载或已授权。',
              ),
              const SizedBox(height: JySpace.lg),
              if (!bound)
                const _Banner(
                  '当前入口未接线宿主连接：附件列表不可用（需装配 AttachmentApi）。',
                  key: Key('attachments-unbound'),
                  icon: Icons.link_off,
                )
              else ...<Widget>[
                _QueryRow(
                  field: TextField(
                    key: const Key('attachments-conversation'),
                    controller: _conversation,
                    decoration: const InputDecoration(
                      labelText: '会话标识（可选，留空=全部会话）',
                      prefixIcon: Icon(Icons.filter_list),
                    ),
                    onSubmitted: (_) => _load(),
                  ),
                  button: FilledButton(
                    key: const Key('attachments-refresh'),
                    onPressed: _busy ? null : () => _load(),
                    child: Text(_busy ? '读取中…' : '刷新'),
                  ),
                ),
                const SizedBox(height: JySpace.lg),
                ..._results(),
              ],
            ],
          );
        },
      ),
    );
  }
}

IconData _kindIcon(String kind) => switch (kind) {
  'image' => Icons.image_outlined,
  'video' => Icons.videocam_outlined,
  'audio' || 'voice' => Icons.mic_none,
  'file' || 'document' => Icons.insert_drive_file_outlined,
  _ => Icons.attach_file,
};

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

/// The filter and its button: side by side from [_sideBySide] wide, the
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

/// Kind icon on a tinted superellipse at the start of a card.
class _IconTile extends StatelessWidget {
  const _IconTile({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: palette.signalSoft,
        shape: JyShapes.rounded(JyRadius.sm),
      ),
      child: SizedBox.square(
        dimension: 40,
        child: Icon(icon, size: 22, color: palette.onSignalSoft),
      ),
    );
  }
}

/// What the page does and does not do: text2 on a raised block.
class _Note extends StatelessWidget {
  const _Note(this.message);

  final String message;

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
                style: text.bodySmall?.copyWith(color: palette.text2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An info notice on signalSoft. Stands in for JyBanner until the lib/ui
/// components land.
class _Banner extends StatelessWidget {
  const _Banner(this.message, {super.key, required this.icon});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Semantics(
      container: true,
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
