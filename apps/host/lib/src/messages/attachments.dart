/// 附件服务（M03 attachments）：分片上传、正文抽取与加密落库、可见性读取。
///
/// 媒体本体存宿主硬盘（`{mediaDir}/{owner}/{id}`），库里只存索引与加密正文。
/// 上传中写 `.part`，完成后校验声明大小与 sha256 再改名落库。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../lifecycle/quota.dart';
import '../storage/cipher.dart';
import '../storage/database.dart';
import 'attachment_extraction.dart';

/// 磁盘剩余/总容量探测。注入假实现即可在测试里控制配额分支。
typedef DiskSpaceProbe = Future<({int freeBytes, int totalBytes})> Function();

/// 附件服务。调用方负责 database/cipher 生命周期与 mediaDir 可写性。
class AttachmentService {
  AttachmentService({
    required Database database,
    required ColumnCipher cipher,
    required String mediaDir,
    this.clock = const SystemClock(),
    DiskSpaceProbe? diskSpace,
    int quotaBytes = QuotaPolicy.defaultQuotaBytes,
    String Function()? newId,
  }) : _database = database,
       _cipher = cipher,
       _mediaDir = mediaDir,
       _quotaBytes = quotaBytes,
       _newId = newId ?? _randomId,
       _diskSpace = diskSpace;

  final Database _database;
  final ColumnCipher _cipher;
  final String _mediaDir;
  final Clock clock;
  final int _quotaBytes;
  final String Function() _newId;

  /// 可注入的磁盘探针；缺省时使用尽力而为的默认实现。
  final DiskSpaceProbe? _diskSpace;

  /// 单次上传声明的绝对上限。作为内存/磁盘 DoS 的第一道上界；真实配额由
  /// [QuotaPolicy]（M12 策略，尚未接入真实计量）判定。
  static const int _maxDeclaredBytes = 128 * 1024 * 1024;

  /// 超过此大小的附件不做正文抽取（避免把整份大文件读进内存）。
  static const int _maxExtractInputBytes = 4 * 1024 * 1024;

  /// 参考 HTTP 适配层 JSON 体上限 1 MiB（http_server.dart），分片以 base64 传输，
  /// 因此对外公布的分片大小必须小于 1MiB 的 base64 膨胀后上限。
  static const int _transportChunkBytes = 512 * 1024;

  /// 每账号最多同时存在的 pending 上传会话数（并发上传闸门，DB 计数，不会泄漏）。
  static const int _maxPendingUploadsPerAccount = 3;

  static const Set<String> _kinds = {
    'file',
    'image',
    'video',
    'voice',
    'text',
    'live2d',
  };

  static String _randomId() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
  }

  static UploadKind? _uploadKind(String kind) => switch (kind) {
    'file' => UploadKind.file,
    'image' => UploadKind.image,
    'video' => UploadKind.video,
    'voice' => UploadKind.voice,
    'text' => UploadKind.text,
    'live2d' => UploadKind.live2d,
    _ => null,
  };

  Future<({int freeBytes, int totalBytes})> _probeDisk() async {
    final probe = _diskSpace;
    if (probe != null) return probe();
    return _defaultDiskSpace();
  }

  Future<({int freeBytes, int totalBytes})> _defaultDiskSpace() async {
    // dart:io 没有可移植的空闲空间查询接口，尽力保证目录存在；无法探测时按
    // “充足”处理，绝不用不可用的探针拦住合法上传。
    try {
      final directory = Directory(_mediaDir);
      if (!await directory.exists()) await directory.create(recursive: true);
    } catch (_) {
      // 目录不可用时与探针失败同义：按充足处理，后续写盘会真实报错。
    }
    const ample = QuotaPolicy.defaultQuotaBytes;
    return (freeBytes: ample, totalBytes: ample);
  }

  String _ownerDir(String ownerAccountId) => '$_mediaDir/$ownerAccountId';

  /// 初始化一次上传会话。返回 uploadId 与建议分片大小。
  Future<Result<Map<String, Object?>>> initiateUpload({
    required String ownerAccountId,
    required String mime,
    required int size,
    required String kind,
    String? conversationId,
  }) async {
    try {
      validateId(ownerAccountId, kind: 'account');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'invalid owner id');
    }
    final uploadKind = _uploadKind(kind);
    final trimmedMime = mime.trim();
    if (uploadKind == null ||
        !_kinds.contains(kind) ||
        trimmedMime.isEmpty ||
        trimmedMime.length > 255 ||
        size < 0 ||
        size > _maxDeclaredBytes) {
      return err(FailureCode.invalidArgument, 'invalid upload request');
    }
    if (conversationId != null) {
      try {
        validateId(conversationId, kind: 'conversation');
      } on FormatException {
        return err(FailureCode.invalidArgument, 'invalid conversation id');
      }
    }

    final usedRows = await _database.query(
      "SELECT COALESCE(SUM(size), 0) AS total FROM attachments "
      "WHERE owner_account_id = ? AND kind IN ('video','voice','file','live2d')",
      [ownerAccountId],
    );
    final usedBytes = (usedRows.single['total'] as int?) ?? 0;
    final disk = await _probeDisk();
    final decision = QuotaPolicy.evaluate(
      usedBytes: usedBytes,
      quotaBytes: _quotaBytes,
      kind: uploadKind,
      uploadBytes: size,
      diskFreeBytes: disk.freeBytes,
      diskTotalBytes: disk.totalBytes,
    );
    if (decision.isErr) return Err(decision.failureOrNull!);

    final pending = await _database.query(
      "SELECT COUNT(*) AS c FROM attachment_uploads "
      "WHERE owner_account_id = ? AND status = 'pending'",
      [ownerAccountId],
    );
    if ((pending.single['c'] as int) >= _maxPendingUploadsPerAccount) {
      return err(FailureCode.rateLimited, 'too many pending uploads');
    }

    final id = validateId(_newId(), kind: 'upload');
    await _database.execute(
      'INSERT INTO attachment_uploads('
      'id, owner_account_id, conversation_id, kind, mime, declared_size, '
      'received_bytes, next_chunk, status, created_at'
      ') VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?)',
      [
        id,
        ownerAccountId,
        conversationId,
        kind,
        trimmedMime,
        size,
        'pending',
        clock.now().toUtc().toIso8601String(),
      ],
    );
    final advertised = decision.value.chunkSizeBytes < _transportChunkBytes
        ? decision.value.chunkSizeBytes
        : _transportChunkBytes;
    return Ok(<String, Object?>{'uploadId': id, 'chunkSize': advertised});
  }

  /// 上传一个分片。index 必须等于 next_chunk；重发 next_chunk-1 且大小一致为
  /// 幂等 no-op。
  Future<Result<Map<String, Object?>>> uploadChunk({
    required String ownerAccountId,
    required String uploadId,
    required int index,
    required List<int> bytes,
  }) async {
    try {
      validateId(ownerAccountId, kind: 'account');
      validateId(uploadId, kind: 'upload');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'invalid id');
    }
    if (index < 0) {
      return err(FailureCode.invalidArgument, 'invalid chunk index');
    }
    final rows = await _database.query(
      'SELECT * FROM attachment_uploads WHERE id = ? AND owner_account_id = ?',
      [uploadId, ownerAccountId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'upload not found');
    final row = rows.single;
    if (row['status'] != 'pending') {
      return err(FailureCode.conflict, 'upload is not pending');
    }
    final declared = row['declared_size'] as int;
    final received = row['received_bytes'] as int;
    final nextChunk = row['next_chunk'] as int;

    // 幂等重发：允许重发上一条已接收的分片（大小一致时）。
    if (index == nextChunk - 1 && nextChunk > 0) {
      final existing = await _database.query(
        'SELECT size FROM attachment_upload_chunks '
        'WHERE upload_id = ? AND chunk_index = ?',
        [uploadId, index],
      );
      if (existing.isNotEmpty &&
          (existing.single['size'] as int) == bytes.length) {
        return Ok(<String, Object?>{'received': received, 'nextChunk': nextChunk});
      }
      return err(FailureCode.invalidArgument, 'duplicate chunk size mismatch');
    }
    if (index != nextChunk) {
      return err(FailureCode.invalidArgument, 'unexpected chunk index');
    }
    if (received + bytes.length > declared) {
      return err(FailureCode.invalidArgument, 'chunk exceeds declared size');
    }

    final ownerDir = Directory(_ownerDir(ownerAccountId));
    await ownerDir.create(recursive: true);
    final part = File('${ownerDir.path}/$uploadId.part');
    final handle = await part.open(mode: FileMode.append);
    try {
      await handle.writeFrom(bytes);
    } finally {
      await handle.close();
    }

    final newReceived = received + bytes.length;
    final newNext = index + 1;
    await _database.transaction((tx) async {
      await tx.execute(
        'INSERT OR REPLACE INTO attachment_upload_chunks('
        'upload_id, chunk_index, size) VALUES (?, ?, ?)',
        [uploadId, index, bytes.length],
      );
      await tx.execute(
        'UPDATE attachment_uploads SET received_bytes = ?, next_chunk = ? '
        'WHERE id = ?',
        [newReceived, newNext, uploadId],
      );
    });
    return Ok(<String, Object?>{'received': newReceived, 'nextChunk': newNext});
  }

  /// 完成上传：校验声明大小与（可选）期望 sha256，抽取正文并加密落库。
  Future<Result<Map<String, Object?>>> completeUpload({
    required String ownerAccountId,
    required String uploadId,
    String? expectedSha256,
  }) async {
    try {
      validateId(ownerAccountId, kind: 'account');
      validateId(uploadId, kind: 'upload');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'invalid id');
    }
    final rows = await _database.query(
      'SELECT * FROM attachment_uploads WHERE id = ? AND owner_account_id = ?',
      [uploadId, ownerAccountId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'upload not found');
    final row = rows.single;
    if (row['status'] != 'pending') {
      return err(FailureCode.conflict, 'upload is not pending');
    }
    final declared = row['declared_size'] as int;
    final received = row['received_bytes'] as int;
    if (received != declared) {
      return err(FailureCode.invalidArgument, 'declared size mismatch');
    }

    final part = File('${_ownerDir(ownerAccountId)}/$uploadId.part');
    if (!await part.exists()) {
      if (declared != 0) {
        return err(FailureCode.internal, 'upload part missing');
      }
      await part.writeAsBytes(const <int>[], flush: true);
    }
    if (await part.length() != declared) {
      return err(FailureCode.invalidArgument, 'stored size mismatch');
    }
    // Stream-hash the blob instead of loading it fully into memory.
    final digest = (await sha256.bind(part.openRead()).single).toString();
    if (expectedSha256 != null && expectedSha256 != digest) {
      return err(FailureCode.invalidArgument, 'sha256 mismatch');
    }

    final attachmentId = validateId(_newId(), kind: 'attachment');
    final finalFile = File('${_ownerDir(ownerAccountId)}/$attachmentId');
    await part.rename(finalFile.path);

    // Only small blobs are read back for text extraction; large binaries are not
    // parsed (marked unsupported) to bound memory use.
    final ExtractResult extracted;
    if (declared <= _maxExtractInputBytes) {
      extracted = AttachmentTextExtractor.extract(
        mime: row['mime'] as String,
        bytes: await finalFile.readAsBytes(),
      );
    } else {
      extracted = const ExtractResult(ExtractStatus.unsupported);
    }
    String? sealedText;
    if (extracted.status == ExtractStatus.extracted && extracted.text != null) {
      sealedText = _cipher.encrypt(
        extracted.text!,
        aad: 'attachments:text:$attachmentId',
      );
    }
    final extractionStatus = extracted.status.name;

    await _database.transaction((tx) async {
      await tx.execute(
        'INSERT INTO attachments('
        'id, owner_account_id, conversation_id, kind, mime, size, sha256, '
        'rel_path, width, height, duration_ms, extracted_text, '
        'extraction_status, created_at'
        ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?)',
        [
          attachmentId,
          ownerAccountId,
          row['conversation_id'],
          row['kind'],
          row['mime'],
          declared,
          digest,
          '$ownerAccountId/$attachmentId',
          sealedText,
          extractionStatus,
          clock.now().toUtc().toIso8601String(),
        ],
      );
      await tx.execute(
        "UPDATE attachment_uploads SET status = 'completed' WHERE id = ?",
        [uploadId],
      );
    });
    return Ok(<String, Object?>{
      'id': attachmentId,
      'size': declared,
      'sha256': digest,
      'extractionStatus': extractionStatus,
    });
  }

  /// 读取附件元数据；owner 或可读该会话的成员可见。extracted 时附带解密正文。
  Future<Result<Map<String, Object?>>> getAttachment({
    required String accountId,
    required String attachmentId,
    Future<bool> Function(String, String)? canReadConversation,
  }) async {
    try {
      validateId(accountId, kind: 'account');
      validateId(attachmentId, kind: 'attachment');
    } on FormatException {
      return err(FailureCode.notFound, 'attachment not found');
    }
    final rows = await _database.query(
      'SELECT * FROM attachments WHERE id = ?',
      [attachmentId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'attachment not found');
    final row = rows.single;
    var allowed = row['owner_account_id'] == accountId;
    if (!allowed) {
      final conversationId = row['conversation_id'] as String?;
      if (conversationId != null && canReadConversation != null) {
        allowed = await canReadConversation(accountId, conversationId);
      }
    }
    if (!allowed) return err(FailureCode.notFound, 'attachment not found');

    final metadata = <String, Object?>{
      'id': row['id'],
      'ownerAccountId': row['owner_account_id'],
      'conversationId': row['conversation_id'],
      'kind': row['kind'],
      'mime': row['mime'],
      'size': row['size'],
      'sha256': row['sha256'],
      'width': row['width'],
      'height': row['height'],
      'durationMs': row['duration_ms'],
      'extractionStatus': row['extraction_status'],
      'createdAt': row['created_at'],
    };
    if (row['extraction_status'] == 'extracted' && row['extracted_text'] != null) {
      final decoded = _cipher.decrypt(
        row['extracted_text'] as String,
        aad: 'attachments:text:$attachmentId',
      );
      if (decoded.isErr) {
        return err(
          FailureCode.internal,
          'stored attachment text cannot be decoded',
        );
      }
      metadata['extractedText'] = decoded.value;
    }
    return Ok(metadata);
  }

  /// 删除附件（仅 owner）：删行并尽力删除 blob 文件。
  Future<Result<void>> deleteAttachment({
    required String ownerAccountId,
    required String attachmentId,
  }) async {
    try {
      validateId(ownerAccountId, kind: 'account');
      validateId(attachmentId, kind: 'attachment');
    } on FormatException {
      return err(FailureCode.notFound, 'attachment not found');
    }
    final rows = await _database.query(
      'SELECT rel_path FROM attachments '
      'WHERE id = ? AND owner_account_id = ?',
      [attachmentId, ownerAccountId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'attachment not found');
    final relPath = rows.single['rel_path'] as String;
    await _database.execute(
      'DELETE FROM attachments WHERE id = ? AND owner_account_id = ?',
      [attachmentId, ownerAccountId],
    );
    try {
      final file = File('$_mediaDir/$relPath');
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 行已删除；孤立的 blob 由后续清理负责，删除接口保持成功。
    }
    return const Ok<void>(null);
  }

  /// 校验一个附件可被某发送者引用于某会话的消息中。
  ///
  /// 要求：附件存在、属于发送者本人、且上传时就绑定到同一会话（会话成员可见性
  /// 与历史边界仍由消息发送处的成员策略判定）。不满足一律按不可见处理。
  Future<Result<void>> assertSendable({
    required String ownerAccountId,
    required String attachmentId,
    required String conversationId,
  }) async {
    try {
      validateId(ownerAccountId, kind: 'account');
      validateId(attachmentId, kind: 'attachment');
      validateId(conversationId, kind: 'conversation');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'invalid id');
    }
    final rows = await _database.query(
      'SELECT owner_account_id, conversation_id FROM attachments WHERE id = ?',
      [attachmentId],
    );
    if (rows.isEmpty ||
        rows.single['owner_account_id'] != ownerAccountId) {
      return err(FailureCode.notFound, 'attachment not found');
    }
    if (rows.single['conversation_id'] != conversationId) {
      return err(FailureCode.invalidArgument, 'attachment not in conversation');
    }
    return const Ok<void>(null);
  }

  /// 在本人自有附件中，按抽取正文做包含匹配（私密，仅返回本人附件）。
  Future<Result<List<Map<String, Object?>>>> searchOwn({
    required String ownerAccountId,
    required String query,
    int limit = 50,
  }) async {
    if (query.trim().isEmpty || query.length > 200 || limit < 1 || limit > 100) {
      return err(FailureCode.invalidArgument, 'invalid query');
    }
    try {
      validateId(ownerAccountId, kind: 'account');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'invalid owner id');
    }
    final needle = query.toLowerCase();
    final rows = await _database.query(
      "SELECT * FROM attachments WHERE owner_account_id = ? "
      "AND extraction_status = 'extracted' ORDER BY rowid",
      [ownerAccountId],
    );
    final items = <Map<String, Object?>>[];
    for (final row in rows) {
      if (items.length >= limit) break;
      final sealed = row['extracted_text'] as String?;
      if (sealed == null) continue;
      final id = row['id'] as String;
      final decoded = _cipher.decrypt(sealed, aad: 'attachments:text:$id');
      if (decoded.isErr) {
        return err(FailureCode.internal, 'stored attachment text cannot be decoded');
      }
      final text = decoded.value;
      final at = text.toLowerCase().indexOf(needle);
      if (at < 0) continue;
      items.add(<String, Object?>{
        'id': id,
        'conversationId': row['conversation_id'],
        'kind': row['kind'],
        'mime': row['mime'],
        'size': row['size'],
        'createdAt': row['created_at'],
        'snippet': _snippet(text, at, needle.length),
      });
    }
    return Ok(items);
  }

  static String _snippet(String text, int at, int length) {
    const radius = 30;
    final start = at - radius < 0 ? 0 : at - radius;
    final end = at + length + radius > text.length
        ? text.length
        : at + length + radius;
    final prefix = start > 0 ? '…' : '';
    final suffix = end < text.length ? '…' : '';
    return '$prefix${text.substring(start, end)}$suffix';
  }
}
