import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../net/attachment_send_flow.dart' show AttachmentContentSource;
import '../net/attachment_upload_api.dart';

/// File-backed attachment content with bounded, metadata-only inspection.
///
/// The local path is not sent. After explicit confirmation, the upload flow
/// streams the file to the chat host and verifies its size and SHA-256.
class FileAttachmentContent implements AttachmentContentSource {
  FileAttachmentContent._({
    required this.path,
    required this.kind,
    required this.size,
    required this.mime,
    required this.sha256,
    required this.displayName,
  });

  final String path;
  @override
  final String kind;
  @override
  final int size;
  @override
  final String mime;
  @override
  final String sha256;
  final String displayName;

  static const Map<String, String> _imageMimes = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'bmp': 'image/bmp',
  };

  /// Opens and inspects one picked file. Unsupported image formats and files
  /// beyond the host's declared limit are rejected before any HTTP request.
  static Future<FileAttachmentContent> load(
    String path, {
    required String kind,
    String? displayName,
    String? declaredMime,
  }) async {
    if (kind != 'image' && kind != 'file') {
      throw const FormatException('不支持的附件类型');
    }
    final file = File(path);
    if (!await file.exists()) throw const FormatException('所选文件不可用');
    final size = await file.length();
    if (size == 0) throw const FormatException('不能发送空文件');
    if (size > AttachmentUploadApi.maxDeclaredBytes) {
      throw const FormatException('附件不能超过 128 MiB');
    }
    final name = safeDisplayName(displayName ?? file.uri.pathSegments.last);
    final extension = _extension(name);
    final selectedMime = _imageMimes[extension] ?? declaredMime;
    if (kind == 'image' &&
        (selectedMime == null || !_imageMimes.containsValue(selectedMime))) {
      throw const FormatException('仅支持 PNG、JPEG、GIF、WebP 或 BMP 图片');
    }
    final mime = kind == 'image' ? selectedMime! : 'application/octet-stream';

    String digest;
    try {
      digest = (await crypto.sha256.bind(file.openRead()).first).toString();
    } on FileSystemException {
      throw const FormatException('所选文件不可用');
    }
    if (await file.length() != size) {
      throw const FormatException('所选文件在读取时发生变化');
    }
    return FileAttachmentContent._(
      path: path,
      kind: kind,
      size: size,
      mime: mime,
      sha256: digest,
      displayName: name,
    );
  }

  @override
  Stream<List<int>> openRead() => File(path).openRead();

  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static String safeDisplayName(String raw) {
    final basename = raw
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .replaceAll('\\', '/')
        .split('/')
        .last
        .trim();
    if (basename.isEmpty || basename == '.' || basename == '..') return '附件';
    if (basename.runes.length <= 120) return basename;
    final dot = basename.lastIndexOf('.');
    final extension = dot > 0 ? basename.substring(dot) : '';
    final suffix = extension.length <= 16 ? extension : '';
    final stem = suffix.isEmpty ? basename : basename.substring(0, dot);
    return String.fromCharCodes(stem.runes.take(120 - suffix.length)) + suffix;
  }
}
