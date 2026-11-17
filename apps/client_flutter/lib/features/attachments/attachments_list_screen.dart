import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/attachment_api.dart';
import '../../net/host_connection.dart';

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

  Widget _card(AttachmentListItem item, TextStyle? title) => Card(
    key: Key('attachment-item-${item.id}'),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.kind, style: title),
          Text('MIME：${item.mime}'),
          Text('大小：${_bytes(item.size)}'),
          Text('状态：${_status(item.extractionStatus)}'),
          Text('会话：${item.conversationId ?? '未绑定会话'}'),
          Text('创建：${item.createdAt.toUtc().toIso8601String()}'),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final bound = widget.listAttachments != null;
    return Scaffold(
      appBar: AppBar(title: const Text('附件列表')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '只读列出当前账号的附件元数据（类型/大小/状态/会话）；'
            '不显示、不存储提取正文或文件字节。不代表可发送、可下载或已授权。',
          ),
          const SizedBox(height: 12),
          if (!bound)
            const Text(
              '当前入口未接线宿主连接：附件列表不可用（需装配 AttachmentApi）。',
              key: Key('attachments-unbound'),
            )
          else ...[
            TextField(
              key: const Key('attachments-conversation'),
              controller: _conversation,
              decoration: const InputDecoration(
                labelText: '会话标识（可选，留空=全部会话）',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _load(),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('attachments-refresh'),
              onPressed: _busy ? null : () => _load(),
              child: Text(_busy ? '读取中…' : '刷新'),
            ),
            const SizedBox(height: 12),
            if (_phase == _Phase.loading)
              const Center(child: CircularProgressIndicator())
            else if (_phase == _Phase.denied)
              Text(
                _notice ?? '无权限查看附件列表。',
                key: const Key('attachments-denied'),
              )
            else if (_phase == _Phase.unknown)
              Text(
                _notice ?? '读取失败或结果未确认。',
                key: const Key('attachments-unknown'),
              )
            else if (_phase == _Phase.empty)
              const Text('没有可显示的附件（或该会话暂无附件）。', key: Key('attachments-empty'))
            else if (_phase == _Phase.ready) ...[
              for (final item in _items) _card(item, text.titleMedium),
              if (_hasMore)
                TextButton(
                  key: const Key('attachments-load-more'),
                  onPressed: _busy ? null : () => _load(more: true),
                  child: const Text('加载更多'),
                ),
            ],
          ],
        ],
      ),
    );
  }
}
