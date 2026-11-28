import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../net/attachment_api.dart';
import '../../ui/jy_palette.dart';
import '../../ui/jy_tokens.dart';
import '../../ui/jy_typography.dart';

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

  static IconData _statusIcon(String status) => switch (status) {
    'pending' => Icons.hourglass_empty,
    'extracted' => Icons.check_circle_outline,
    'failed' => Icons.error_outline,
    'unsupported' => Icons.block,
    _ => Icons.help_outline,
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
    final read = widget.readAttachment;
    final metadata = _metadata;
    final notice = _notice;
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('附件元数据')),
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
                '宿主未提供附件列表路由；按附件标识只读查看单条元数据（类型/大小/状态），'
                '不显示、不存储文件内容或解密正文。',
              ),
              const SizedBox(height: JySpace.lg),
              _QueryRow(
                field: TextField(
                  key: const Key('attachment-id-input'),
                  controller: _attachmentId,
                  decoration: const InputDecoration(
                    labelText: '附件标识（attachmentId）',
                    prefixIcon: Icon(Icons.attach_file),
                  ),
                  onSubmitted: (_) => _read(),
                ),
                button: FilledButton(
                  key: const Key('attachment-read'),
                  onPressed: read == null || _busy ? null : _read,
                  child: Text(_busy ? '读取中…' : '读取元数据'),
                ),
              ),
              // States sit right under the control they come from.
              if (read == null) ...<Widget>[
                const SizedBox(height: JySpace.md),
                const _Banner(
                  '当前入口未接线宿主连接：读取不可用（需装配 AttachmentApi）。',
                  key: Key('attachment-unbound'),
                  icon: Icons.link_off,
                ),
              ],
              if (notice != null) ...<Widget>[
                const SizedBox(height: JySpace.md),
                _Banner(
                  notice,
                  key: const Key('attachment-notice'),
                  icon: Icons.error_outline,
                  error: true,
                ),
              ],
              if (metadata != null) ...<Widget>[
                const SizedBox(height: JySpace.lg),
                _metadataCard(metadata),
              ],
            ],
          );
        },
      ),
    );
  }

  /// The metadata as one slab: one line per field, each a single sentence,
  /// with a hairline between lines and the scope note at the foot.
  Widget _metadataCard(AttachmentMetadata metadata) {
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<(IconData, String)> lines = <(IconData, String)>[
      (_kindIcon(metadata.kind), '类型：${metadata.kind} · MIME：${metadata.mime}'),
      (Icons.data_usage, '大小：${_bytes(metadata.size)}'),
      (
        _statusIcon(metadata.extractionStatus),
        '状态：${_status(metadata.extractionStatus)}',
      ),
      (Icons.chat_bubble_outline, '会话：${metadata.conversationId ?? '未绑定会话'}'),
      (Icons.schedule, '创建：${metadata.createdAt.toUtc().toIso8601String()}'),
    ];
    return Card(
      key: const Key('attachment-metadata'),
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final (int index, (IconData icon, String line))
              in lines.indexed) ...<Widget>[
            if (index > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: _lineTextStart,
                color: palette.hairline,
              ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: JySpace.lg,
                vertical: JySpace.md,
              ),
              child: Row(
                children: <Widget>[
                  Icon(icon, size: 20, color: palette.text3),
                  const SizedBox(width: JySpace.lg),
                  Expanded(
                    child: Text(
                      line,
                      style: (index == 0 ? text.titleSmall : text.bodyMedium)
                          ?.copyWith(fontFeatures: JyTypography.tabularFigures),
                    ),
                  ),
                ],
              ),
            ),
          ],
          Divider(height: 1, thickness: 1, color: palette.hairline),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              JySpace.lg,
              JySpace.md,
              JySpace.lg,
              JySpace.lg,
            ),
            child: Text(
              '仅为元数据，不代表可发送、可下载或已授权。',
              style: text.bodySmall?.copyWith(color: palette.text3),
            ),
          ),
        ],
      ),
    );
  }

  /// Where a metadata line's text starts, so the hairlines line up with it.
  static const double _lineTextStart = JySpace.lg + 20 + JySpace.lg;
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

/// The input and its button: side by side from [_sideBySide] wide, the
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

/// A notice next to the control it is about: info on signalSoft, an error on
/// dangerSoft and announced as a live region. Stands in for JyBanner until
/// the lib/ui components land.
class _Banner extends StatelessWidget {
  const _Banner(
    this.message, {
    super.key,
    required this.icon,
    this.error = false,
  });

  final String message;
  final IconData icon;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Color fill = error ? palette.dangerSoft : palette.signalSoft;
    final Color ink = error ? palette.onDangerSoft : palette.onSignalSoft;
    return Semantics(
      container: true,
      liveRegion: error,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: fill,
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
              Icon(icon, size: 20, color: error ? palette.danger : ink),
              const SizedBox(width: JySpace.md),
              Expanded(
                child: Text(
                  message,
                  style: text.bodyMedium?.copyWith(color: ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
