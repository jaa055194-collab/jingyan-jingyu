import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

class AttachmentUploadSession {
  const AttachmentUploadSession(this.uploadId, this.chunkSize);
  final String uploadId;
  final int chunkSize;
}

class AttachmentUploadProgress {
  const AttachmentUploadProgress(this.received, this.nextChunk);
  final int received;
  final int nextChunk;
}

class CompletedAttachmentUpload {
  const CompletedAttachmentUpload(this.attachmentId, this.size, this.sha256);
  final String attachmentId;
  final int size;
  final String sha256;
}

/// Explicit HTTP stages for the existing host attachment contract.
///
/// This adapter never chooses files, grants AI consent, retries an uncertain
/// stage, queues messages, or persists an upload. Callers must retain the same
/// session/bytes for an explicit chunk retry and respect the advertised limit.
/// A completion response is a stored attachment, not a sent chat message.
class AttachmentUploadApi {
  AttachmentUploadApi(this.connection);
  final HostConnection connection;
  static const maxDeclaredBytes = 128 * 1024 * 1024;
  static const maxChunkBytes = 512 * 1024;
  static const _kinds = {'file', 'image', 'video', 'voice', 'text', 'live2d'};
  static final _digest = RegExp(r'^[0-9a-f]{64}$');

  Future<AttachmentUploadSession> initiate({
    required String mime,
    required int size,
    required String kind,
    String? conversationId,
  }) async {
    final normalizedMime = mime.trim();
    if (normalizedMime.isEmpty ||
        normalizedMime.length > 255 ||
        size < 0 ||
        size > maxDeclaredBytes ||
        !_kinds.contains(kind)) {
      throw const FormatException('附件上传参数无效');
    }
    if (conversationId != null) {
      validateId(conversationId, kind: 'conversation');
    }
    try {
      final body = await connection.request(
        'POST',
        Routes.attachmentUploads,
        body: {
          'mime': normalizedMime,
          'size': size,
          'kind': kind,
          'conversationId': ?conversationId,
        },
      );
      final id = body['uploadId'], chunk = body['chunkSize'];
      if (id is! String ||
          chunk is! int ||
          chunk < 1 ||
          chunk > maxChunkBytes) {
        throw const FormatException();
      }
      return AttachmentUploadSession(validateId(id, kind: 'upload'), chunk);
    } on FormatException {
      throw const FormatException('附件上传会话响应无效');
    }
  }

  Future<AttachmentUploadProgress> putChunk({
    required String uploadId,
    required int index,
    required List<int> bytes,
  }) async {
    validateId(uploadId, kind: 'upload');
    if (index < 0 ||
        bytes.length > maxChunkBytes ||
        bytes.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('附件分片参数无效');
    }
    // Encode before the first await so later caller mutation cannot change a
    // request or its bounded 401 authentication replay.
    final byteLength = bytes.length;
    final encoded = base64Encode(List<int>.from(bytes));
    try {
      final body = await connection.request(
        'PUT',
        Routes.attachmentUploadChunk
            .replaceAll('{uploadId}', Uri.encodeComponent(uploadId))
            .replaceAll('{index}', '$index'),
        body: {'dataBase64': encoded},
      );
      final received = body['received'], next = body['nextChunk'];
      if (received is! int ||
          received < byteLength ||
          received > maxDeclaredBytes ||
          next is! int ||
          next != index + 1) {
        throw const FormatException();
      }
      return AttachmentUploadProgress(received, next);
    } on FormatException {
      throw const FormatException('附件分片响应无效');
    }
  }

  /// Aborts one pending upload owned by the current account. Only an explicit
  /// caller failure path should invoke this; it is never retried automatically.
  Future<void> abort(String uploadId) async {
    validateId(uploadId, kind: 'upload');
    try {
      final body = await connection.request(
        'DELETE',
        Routes.attachmentUpload.replaceAll(
          '{uploadId}',
          Uri.encodeComponent(uploadId),
        ),
      );
      if (body['aborted'] != true) throw const FormatException();
    } on FormatException {
      throw const FormatException('附件取消响应无效');
    }
  }

  Future<CompletedAttachmentUpload> complete({
    required String uploadId,
    String? expectedSha256,
  }) async {
    validateId(uploadId, kind: 'upload');
    if (expectedSha256 != null && !_digest.hasMatch(expectedSha256)) {
      throw const FormatException('附件校验摘要无效');
    }
    try {
      final body = await connection.request(
        'POST',
        Routes.attachmentUploadComplete.replaceAll(
          '{uploadId}',
          Uri.encodeComponent(uploadId),
        ),
        body: {'sha256': ?expectedSha256},
      );
      final id = body['id'], size = body['size'], digest = body['sha256'];
      if (id is! String ||
          size is! int ||
          size < 0 ||
          size > maxDeclaredBytes ||
          digest is! String ||
          !_digest.hasMatch(digest) ||
          (expectedSha256 != null && digest != expectedSha256)) {
        throw const FormatException();
      }
      return CompletedAttachmentUpload(
        validateId(id, kind: 'attachment'),
        size,
        digest,
      );
    } on FormatException {
      throw const FormatException('附件完成响应无效');
    }
  }
}
