import 'package:material_ui/material_ui.dart';

import '../../net/attachment_api.dart';

/// Honest, read-only attachment metadata viewer.
///
/// The host exposes no recent/conversation attachment list route, so this
/// screen never lists or invents attachments: the developer enters an explicit
/// attachment id and the exact host metadata is shown. Decrypted text is never
/// requested or rendered. Not-found/unknown states are honest and there is no
/// automatic retry.
class AttachmentsScreen extends StatefulWidget {
  const AttachmentsScreen({super.key, this.readAttachment});

  /// Host-backed reader ([AttachmentApi.readAttachment] in production).
  final Future<AttachmentMetadata> Function(String attachmentId)?
  readAttachment;

  @override
  State<AttachmentsScreen> createState() => _AttachmentsScreenState();
}

class _AttachmentsScreenState extends State<AttachmentsScreen> {
  final _attachmentId = TextEditingController();
  AttachmentMetadata? _metadata;
  String? _notice;
  bool _busy = false;

  @override
  void dispose() {
    _attachmentId.dispose();
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

  Future<void> _read() async {
    final read = widget.readAttachment;
    final id = _attachmentId.text.trim();
    if (read == null || id.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _notice = null;
      _metadata = null;
    });
    try {
      final metadata = await read(id);
      if (!mounted) return;
      setState(() => _metadata = metadata);
    } catch (_) {
      // Never surface upstream bodies, ids the host rejected, or provider text.
      if (!mounted) return;
      setState(() {
        _metadata = null;
        _notice = '未找到或读取失败；元数据未确认。不会自动重试。';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final read = widget.readAttachment;
    return Scaffold(
      appBar: AppBar(title: const Text('附件元数据')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '宿主未提供附件列表路由；按附件标识只读查看单条元数据（类型/大小/状态），'
            '不显示、不存储文件内容或解密正文。',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('attachment-id-input'),
            controller: _attachmentId,
            decoration: const InputDecoration(
              labelText: '附件标识（attachmentId）',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _read(),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('attachment-read'),
            onPressed: read == null || _busy ? null : _read,
            child: Text(_busy ? '读取中…' : '读取元数据'),
          ),
          if (read == null) ...[
            const SizedBox(height: 8),
            const Text(
              '当前入口未接线宿主连接：读取不可用（需装配 AttachmentApi）。',
              key: Key('attachment-unbound'),
            ),
          ],
          if (_notice != null) ...[
            const SizedBox(height: 12),
            Text(_notice!, key: const Key('attachment-notice')),
          ],
          if (_metadata != null) ...[
            const SizedBox(height: 12),
            Card(
              key: const Key('attachment-metadata'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('附件元数据', style: text.titleMedium),
                    const SizedBox(height: 8),
                    Text('类型：${_metadata!.kind} · MIME：${_metadata!.mime}'),
                    Text('大小：${_bytes(_metadata!.size)}'),
                    Text('状态：${_status(_metadata!.extractionStatus)}'),
                    Text('会话：${_metadata!.conversationId ?? '未绑定会话'}'),
                    Text(
                      '创建：${_metadata!.createdAt.toUtc().toIso8601String()}',
                    ),
                    const SizedBox(height: 4),
                    const Text('仅为元数据，不代表可发送、可下载或已授权。'),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
