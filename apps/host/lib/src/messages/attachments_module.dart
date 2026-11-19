/// 附件 HTTP 模块：装配 [AttachmentService] 并暴露分片上传与读取路由。
library;

import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'attachments.dart';
import 'messages_module.dart' show MembershipCheck;

/// 附件模块。
class AttachmentsModule extends HostModule {
  AttachmentsModule({required AttachmentService attachments})
    : _attachments = attachments;

  final AttachmentService _attachments;
  late HostServices _services;

  @override
  String get name => 'attachments';

  @override
  Future<void> configure(HostServices services) async {
    _services = services;
  }

  @override
  void mount(Router router) {
    router.post(Routes.attachmentUploads, _initiate);
    router.put(Routes.attachmentUploadChunk, _chunk);
    router.post(Routes.attachmentUploadComplete, _complete);
    router.delete(Routes.attachmentUpload, _abort);
    router.get(Routes.attachments, _list);
    router.get(Routes.attachment, _get);
    router.delete(Routes.attachment, _delete);
  }

  Future<HostResponse> _initiate(HostRequest request) async {
    final principal = request.principal!;
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final json = body.value;
    final mime = json['mime'];
    final size = json['size'];
    final kind = json['kind'];
    final rawConversation = json['conversationId'];
    if (mime is! String ||
        size is! int ||
        kind is! String ||
        (rawConversation != null && rawConversation is! String)) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad body'),
      );
    }
    final conversationId = rawConversation as String?;
    if (conversationId != null) {
      final members = _services.maybeGet<MembershipCheck>();
      final canPost =
          members != null &&
          await members.canPost(principal.accountId, conversationId);
      if (!canPost) {
        return HostResponse.failure(
          const Failure(FailureCode.notFound, 'not visible'),
        );
      }
    }
    final result = await _attachments.initiateUpload(
      ownerAccountId: principal.accountId,
      mime: mime,
      size: size,
      kind: kind,
      conversationId: conversationId,
    );
    return HostResponse.fromResult(result);
  }

  Future<HostResponse> _chunk(HostRequest request) async {
    final principal = request.principal!;
    final uploadId = request.pathParams['uploadId']!;
    final index = int.tryParse(request.pathParams['index']!);
    if (index == null || index < 0) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad chunk index'),
      );
    }
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final data = body.value['dataBase64'];
    if (data is! String) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad chunk body'),
      );
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad base64'),
      );
    }
    final result = await _attachments.uploadChunk(
      ownerAccountId: principal.accountId,
      uploadId: uploadId,
      index: index,
      bytes: bytes,
    );
    return HostResponse.fromResult(result);
  }

  Future<HostResponse> _complete(HostRequest request) async {
    final principal = request.principal!;
    final uploadId = request.pathParams['uploadId']!;
    String? expectedSha256;
    final body = request.jsonObject();
    if (body is Ok<Map<String, Object?>>) {
      final value = body.value['sha256'];
      if (value is String) expectedSha256 = value;
    }
    final result = await _attachments.completeUpload(
      ownerAccountId: principal.accountId,
      uploadId: uploadId,
      expectedSha256: expectedSha256,
    );
    return HostResponse.fromResult(result);
  }

  Future<HostResponse> _abort(HostRequest request) async {
    final principal = request.principal!;
    final uploadId = request.pathParams['uploadId']!;
    final result = await _attachments.abortUpload(
      ownerAccountId: principal.accountId,
      uploadId: uploadId,
    );
    return HostResponse.fromResult(result, (_) => {'aborted': true});
  }

  Future<HostResponse> _list(HostRequest request) async {
    final principal = request.principal!;
    if (request.body != null) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad body'),
      );
    }
    const allowed = {'limit', 'before', 'conversationId'};
    if (request.query.keys.any((key) => !allowed.contains(key))) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad query'),
      );
    }
    var limit = 50;
    final rawLimit = request.query['limit'];
    if (rawLimit != null) {
      final parsed = int.tryParse(rawLimit);
      if (parsed == null) {
        return HostResponse.failure(
          const Failure(FailureCode.invalidArgument, 'bad limit'),
        );
      }
      limit = parsed;
    }
    final result = await _attachments.listOwn(
      ownerAccountId: principal.accountId,
      conversationId: request.query['conversationId'],
      limit: limit,
      before: request.query['before'],
    );
    return HostResponse.fromResult(result);
  }

  Future<HostResponse> _get(HostRequest request) async {
    final principal = request.principal!;
    final attachmentId = request.pathParams['attachmentId']!;
    final members = _services.maybeGet<MembershipCheck>();
    final result = await _attachments.getAttachment(
      accountId: principal.accountId,
      attachmentId: attachmentId,
      canReadConversation: members?.canRead,
    );
    return HostResponse.fromResult(result);
  }

  Future<HostResponse> _delete(HostRequest request) async {
    final principal = request.principal!;
    final attachmentId = request.pathParams['attachmentId']!;
    final result = await _attachments.deleteAttachment(
      ownerAccountId: principal.accountId,
      attachmentId: attachmentId,
    );
    return HostResponse.fromResult(result, (_) => {'removed': true});
  }
}
