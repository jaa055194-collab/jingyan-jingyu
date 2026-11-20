import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// Metadata of one stored attachment, exactly as the host returns it — minus
/// the decrypted `extractedText`, which this adapter deliberately drops.
/// The client never renders or retains attachment file content.
class AttachmentMetadata {
  const AttachmentMetadata({
    required this.id,
    required this.ownerAccountId,
    required this.conversationId,
    required this.kind,
    required this.mime,
    required this.size,
    required this.sha256,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.extractionStatus,
    required this.createdAt,
  });

  final String id;
  final String ownerAccountId;
  final String? conversationId;
  final String kind;
  final String mime;
  final int size;
  final String sha256;
  final int? width;
  final int? height;
  final int? durationMs;
  final String extractionStatus;
  final DateTime createdAt;

  static const _optionalInts = {'width', 'height', 'durationMs'};

  factory AttachmentMetadata.fromJson(Map<String, Object?> json) {
    try {
      const keys = {
        'id',
        'ownerAccountId',
        'conversationId',
        'kind',
        'mime',
        'size',
        'sha256',
        'width',
        'height',
        'durationMs',
        'extractionStatus',
        'createdAt',
      };
      if (json.containsKey('extractedText')) {
        // The host may include decrypted text for owners; this adapter is
        // metadata-only and never parses or transports that field.
        throw const FormatException();
      }
      if (json.length != keys.length ||
          json.keys.any((key) => !keys.contains(key))) {
        throw const FormatException();
      }
      final conversation = json['conversationId'];
      final size = json['size'];
      final digest = json['sha256'];
      final kind = json['kind'];
      final mime = json['mime'];
      final status = json['extractionStatus'];
      if (conversation != null && conversation is! String) {
        throw const FormatException();
      }
      if (size is! int || size < 0) throw const FormatException();
      if (digest is! String || !_sha256.hasMatch(digest)) {
        throw const FormatException();
      }
      if (kind is! String || mime is! String || mime.trim().isEmpty) {
        throw const FormatException();
      }
      if (status is! String || !_statuses.contains(status)) {
        throw const FormatException();
      }
      final optional = <int?>{};
      for (final key in _optionalInts) {
        final value = json[key];
        if (value == null) {
          optional.add(null);
        } else if (value is int && value >= 0) {
          optional.add(value);
        } else {
          throw const FormatException();
        }
      }
      final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');
      if (createdAt == null) throw const FormatException();
      return AttachmentMetadata(
        id: validateId(json['id'] as String, kind: 'attachment'),
        ownerAccountId: validateId(
          json['ownerAccountId'] as String,
          kind: 'account',
        ),
        conversationId: conversation as String?,
        kind: kind,
        mime: mime,
        size: size,
        sha256: digest,
        width: optional.elementAt(0),
        height: optional.elementAt(1),
        durationMs: optional.elementAt(2),
        extractionStatus: status,
        createdAt: createdAt,
      );
    } on FormatException {
      throw const FormatException('附件元数据响应无效');
    }
  }

  static final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');
  static const _statuses = {'pending', 'extracted', 'failed', 'unsupported'};
}

/// One attachment in the owner-scoped list route. Metadata only: the list DTO
/// has **no** `extractedText` and no bytes, and this adapter rejects any payload
/// that tries to include them.
class AttachmentListItem {
  const AttachmentListItem({
    required this.id,
    required this.conversationId,
    required this.kind,
    required this.mime,
    required this.size,
    required this.extractionStatus,
    required this.createdAt,
  });

  final String id;
  final String? conversationId;
  final String kind;
  final String mime;
  final int size;
  final String extractionStatus;
  final DateTime createdAt;

  static const _statuses = {'pending', 'extracted', 'failed', 'unsupported'};

  factory AttachmentListItem.fromJson(Map<String, Object?> json) {
    try {
      const keys = {
        'id',
        'conversationId',
        'kind',
        'mime',
        'size',
        'extractionStatus',
        'createdAt',
      };
      if (json.containsKey('extractedText') ||
          json.containsKey('bytes') ||
          json.length != keys.length ||
          json.keys.any((key) => !keys.contains(key))) {
        throw const FormatException();
      }
      final conversation = json['conversationId'];
      final kind = json['kind'];
      final mime = json['mime'];
      final size = json['size'];
      final status = json['extractionStatus'];
      if (conversation != null) {
        if (conversation is! String) throw const FormatException();
        validateId(conversation, kind: 'conversation');
      }
      if (kind is! String || kind.trim().isEmpty) throw const FormatException();
      if (mime is! String || mime.trim().isEmpty) throw const FormatException();
      if (size is! int || size < 0) throw const FormatException();
      if (status is! String || !_statuses.contains(status)) {
        throw const FormatException();
      }
      final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');
      if (createdAt == null) throw const FormatException();
      return AttachmentListItem(
        id: validateId(json['id'] as String, kind: 'attachment'),
        conversationId: conversation as String?,
        kind: kind,
        mime: mime,
        size: size,
        extractionStatus: status,
        createdAt: createdAt,
      );
    } on FormatException {
      throw const FormatException('附件列表响应无效');
    }
  }
}

/// One bounded image fetched through a message-scoped route.
///
/// The adapter verifies the declared size, digest and MIME type, and never
/// exposes decrypted text or a local path.
class MessageImage {
  const MessageImage({
    required this.mime,
    required this.bytes,
    required this.sha256,
  });

  final String mime;
  final Uint8List bytes;
  final String sha256;

  static const int maxBytes = 8 * 1024 * 1024;
  static const Set<String> allowedMimes = {
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'image/bmp',
  };

  factory MessageImage.fromJson(Map<String, Object?> json) {
    const keys = {'mime', 'size', 'sha256', 'dataBase64'};
    if (json.length != keys.length ||
        json.keys.any((key) => !keys.contains(key))) {
      throw const FormatException();
    }
    final mime = json['mime'];
    final size = json['size'];
    final digest = json['sha256'];
    final encoded = json['dataBase64'];
    if (mime is! String ||
        !allowedMimes.contains(mime) ||
        size is! int ||
        size < 1 ||
        size > maxBytes ||
        digest is! String ||
        digest.length != 64 ||
        encoded is! String) {
      throw const FormatException();
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw const FormatException();
    }
    if (bytes.length != size ||
        crypto.sha256.convert(bytes).toString() != digest) {
      throw const FormatException();
    }
    return MessageImage(mime: mime, bytes: bytes, sha256: digest);
  }
}

/// Read-only GET of one attachment's metadata by explicit attachment id.///
/// Also provides an owner-scoped metadata list ([listAttachments]); both routes
/// are read-only and the adapter never requests, parses or surfaces decrypted
/// text or file bytes. Existing [HostConnection] bounded 401 renewal is
/// inherited. Decrypted text is never requested, parsed or surfaced.
class AttachmentApi {
  AttachmentApi(this.connection);
  final HostConnection connection;

  Future<AttachmentMetadata> readAttachment(
    String attachmentId, {
    bool retryAuthentication = true,
  }) async {
    String path;
    try {
      path = Routes.attachment.replaceAll(
        '{attachmentId}',
        Uri.encodeComponent(validateId(attachmentId, kind: 'attachment')),
      );
    } on FormatException {
      throw const FormatException('附件标识参数无效');
    }
    try {
      final json = await connection.request(
        'GET',
        path,
        retryAuthentication: retryAuthentication,
      );
      return AttachmentMetadata.fromJson(json);
    } on FormatException {
      throw const FormatException('附件元数据响应无效');
    } on SocketException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on HttpException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    }
  }

  /// Owner-only cleanup for a completed but unsent attachment.
  Future<void> deleteAttachment(
    String attachmentId, {
    bool retryAuthentication = true,
  }) async {
    String path;
    try {
      path = Routes.attachment.replaceAll(
        '{attachmentId}',
        Uri.encodeComponent(validateId(attachmentId, kind: 'attachment')),
      );
    } on FormatException {
      throw const FormatException('附件标识参数无效');
    }
    try {
      final body = await connection.request(
        'DELETE',
        path,
        retryAuthentication: retryAuthentication,
      );
      if (body['removed'] != true) throw const FormatException();
    } on FormatException {
      throw const FormatException('附件删除响应无效');
    } on SocketException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on HttpException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    }
  }

  /// Message-scoped bounded image bytes.
  ///
  /// The host authorizes this against the message, its conversation and its
  /// sender, so a caller cannot turn an attachment id into a download channel.
  Future<MessageImage> readMessageImage({
    required String conversationId,
    required String messageId,
    bool retryAuthentication = true,
  }) async {
    String path;
    try {
      path = Routes.messageAttachment
          .replaceFirst(
            '{conversationId}',
            Uri.encodeComponent(
              validateId(conversationId, kind: 'conversation'),
            ),
          )
          .replaceFirst(
            '{messageId}',
            Uri.encodeComponent(validateId(messageId, kind: 'message')),
          );
    } on FormatException {
      throw const FormatException('消息标识参数无效');
    }
    try {
      final json = await connection.request(
        'GET',
        path,
        retryAuthentication: retryAuthentication,
      );
      return MessageImage.fromJson(json);
    } on FormatException {
      throw const FormatException('消息图片响应无效');
    } on SocketException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on HttpException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    }
  }

  /// Owner-scoped metadata list: `GET /attachments`.
  ///
  /// [conversationId] optionally filters to one conversation; [limit] is 1..100;
  /// [before] pages older items (the host returns each item's `createdAt`); pass
  /// the oldest item's `createdAt` to fetch the next page. The response is a JSON
  /// array of metadata-only items — no `extractedText`, no bytes.
  Future<List<AttachmentListItem>> listAttachments({
    String? conversationId,
    int limit = 50,
    DateTime? before,
    bool retryAuthentication = true,
  }) async {
    if (limit < 1 || limit > 100) {
      throw const FormatException('附件列表分页参数无效');
    }
    final query = <String, String>{'limit': '$limit'};
    if (conversationId != null) {
      try {
        query['conversationId'] = validateId(
          conversationId,
          kind: 'conversation',
        );
      } on FormatException {
        throw const FormatException('附件列表参数无效');
      }
    }
    if (before != null) query['before'] = before.toUtc().toIso8601String();
    try {
      final items = await connection.requestList(
        'GET',
        Routes.attachments,
        query: query,
        retryAuthentication: retryAuthentication,
      );
      return [
        for (final item in items)
          if (item is Map<String, dynamic>)
            AttachmentListItem.fromJson(item.cast<String, Object?>())
          else
            throw const FormatException('附件列表响应无效'),
      ];
    } on FormatException {
      throw const FormatException('附件列表响应无效');
    } on SocketException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on HttpException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    }
  }
}
