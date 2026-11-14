/// 附件正文抽取（M03 attachments）。
///
/// 只对文本类 MIME 做真正的解码；二进制、PDF、DOCX、图片与音视频一律诚实
/// 标记为 [ExtractStatus.unsupported]，绝不臆造解析结果。抽取结果由上层决定
/// 是否加密落库。
library;

import 'dart:convert';

/// 抽取结果状态。
enum ExtractStatus {
  /// 成功抽取到非空文本。
  extracted,

  /// 该 MIME 不支持正文抽取（二进制等）。
  unsupported,

  /// 解码成功但内容为空（或只有空白）。
  empty,

  /// 解码/处理过程中出现异常。
  error,
}

/// 一次正文抽取的结果。
class ExtractResult {
  const ExtractResult(this.status, [this.text]);

  final ExtractStatus status;

  /// 抽取出的文本；仅在 [ExtractStatus.extracted] 时非空。
  final String? text;
}

/// 纯函数式文本抽取器。
class AttachmentTextExtractor {
  AttachmentTextExtractor._();

  /// 抽取文本上限：1 MiB（按 UTF-16 code unit 计）。
  static const int maxTextLength = 1 << 20;

  static const Set<String> _supportedMimes = {
    'text/plain',
    'text/markdown',
    'text/csv',
    'text/html',
    'application/json',
    'application/xml',
    'text/xml',
  };

  static const Map<String, String> _namedEntities = {
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': ' ',
    'mdash': '\u2014',
    'ndash': '\u2013',
    'hellip': '\u2026',
    'copy': '\u00A9',
    'reg': '\u00AE',
    'trade': '\u2122',
  };

  static final RegExp _namedEntityPattern = RegExp(
    r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);',
  );
  static final RegExp _scriptBlock = RegExp(
    r'<script\b[^>]*>[\s\S]*?</script>',
    caseSensitive: false,
  );
  static final RegExp _styleBlock = RegExp(
    r'<style\b[^>]*>[\s\S]*?</style>',
    caseSensitive: false,
  );
  static final RegExp _brTag = RegExp(r'<br\s*/?>', caseSensitive: false);
  static final RegExp _blockClose = RegExp(
    r'</(?:p|div|li|tr|h[1-6])>',
    caseSensitive: false,
  );
  static final RegExp _anyTag = RegExp(r'<[^>]+>');
  static final RegExp _inlineWhitespace = RegExp(r'[ \t\f\v]+');
  static final RegExp _blankLines = RegExp(r'\n{3,}');

  /// 抽取 [mime] 对应的正文。[bytes] 为原始字节。
  static ExtractResult extract({required String mime, required List<int> bytes}) {
    final normalized = _normalizeMime(mime);
    if (!_supportedMimes.contains(normalized)) {
      return const ExtractResult(ExtractStatus.unsupported);
    }
    try {
      final decoded = _decodeUtf8(bytes);
      final String text;
      if (normalized == 'text/html') {
        text = _stripHtml(decoded);
      } else {
        text = decoded;
      }
      final capped = text.length > maxTextLength
          ? text.substring(0, maxTextLength)
          : text;
      if (capped.trim().isEmpty) {
        return const ExtractResult(ExtractStatus.empty);
      }
      return ExtractResult(ExtractStatus.extracted, capped);
    } catch (_) {
      return const ExtractResult(ExtractStatus.error);
    }
  }

  static String _normalizeMime(String mime) {
    final trimmed = mime.split(';').first.trim().toLowerCase();
    return trimmed;
  }

  static String _decodeUtf8(List<int> bytes) =>
      const Utf8Decoder(allowMalformed: true).convert(bytes);

  static String _stripHtml(String html) {
    var text = html
        .replaceAll(_scriptBlock, ' ')
        .replaceAll(_styleBlock, ' ')
        .replaceAll(_brTag, '\n')
        .replaceAll(_blockClose, '\n')
        .replaceAll(_anyTag, ' ');
    text = _decodeEntities(text);
    text = text.replaceAll(_inlineWhitespace, ' ');
    text = text.replaceAll(RegExp(r'\n[ \t]+'), '\n');
    text = text.replaceAll(_blankLines, '\n\n');
    return text.trim();
  }

  static String _decodeEntities(String input) => input.replaceAllMapped(
    _namedEntityPattern,
    (match) {
      final token = match.group(1)!;
      if (token.startsWith('#x') || token.startsWith('#X')) {
        final code = int.tryParse(token.substring(2), radix: 16);
        return code == null ? match.group(0)! : String.fromCharCode(code);
      }
      if (token.startsWith('#')) {
        final code = int.tryParse(token.substring(1));
        return code == null ? match.group(0)! : String.fromCharCode(code);
      }
      return _namedEntities[token.toLowerCase()] ?? match.group(0)!;
    },
  );
}
