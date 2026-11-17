import 'dart:async';
import 'dart:io';

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

/// Read-only GET of one attachment's metadata by explicit attachment id.
///
/// There is no host route listing recent/conversation attachments; this adapter
/// does not fabricate one. Existing [HostConnection] bounded 401 renewal is
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
}
