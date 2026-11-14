import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../accounts/db_authenticator.dart';
import '../audit/audit_log.dart';
import 'topic_service.dart';

/// Mounts group topic metadata and existing-message pointers only.
/// Authorization for a topic's parent group remains inside TopicService.
void mountTopicRoutes(
  Router router, {
  required TopicService topics,
  required AccountsDomain accounts,
  required Clock clock,
  required AuditLog audit,
}) {
  HostResponse invalid() => HostResponse.failure(
    const Failure(FailureCode.invalidArgument, 'Invalid topic input'),
  );
  HostResponse unauthenticated() => HostResponse.failure(
    const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
  );

  String? id(Object? value) {
    if (value is! String) return null;
    try {
      return validateId(value);
    } on FormatException {
      return null;
    }
  }

  Future<String?> actorId(HostRequest request) async {
    final principal = request.principal;
    if (principal == null) return null;
    final header = request.headers['authorization'] ?? '';
    final bearer = header.startsWith('Bearer ')
        ? header.substring(7).trim()
        : '';
    if ((await accounts.scope(bearer)).isErr) return null;
    final current = await accounts.authenticate(bearer);
    if (current == null ||
        current.accountId != principal.accountId ||
        current.deviceId != principal.deviceId) {
      return null;
    }
    return id(principal.accountId);
  }

  String? bodyId(HostRequest request, String field) {
    final body = request.body;
    if (body is! Map<String, Object?> || body.length != 1) return null;
    return id(body[field]);
  }

  Map<String, Object?> topicMetadata(GroupTopic topic) => {
    'id': topic.id,
    'conversationId': topic.conversationId,
    'rootMessageId': topic.rootMessageId,
    'createdBy': topic.createdBy,
    'createdAt': topic.createdAt.toUtc().toIso8601String(),
  };

  Map<String, Object?> referenceMetadata(TopicMessageReference reference) => {
    'messageId': reference.messageId,
    'seq': reference.seq,
    'senderId': reference.senderId,
  };

  Future<void> record(
    String actor,
    String topic,
    String action,
    Map<String, Object?> metadata,
  ) => audit.record(
    AuditEntry(
      at: clock.now(),
      actorId: actor,
      action: action,
      targetKind: 'topic',
      targetId: topic,
      meta: metadata,
    ),
  );

  router.get(Routes.groupTopics, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final conversation = id(request.pathParams['conversationId']);
    if (conversation == null || request.body != null) return invalid();
    return HostResponse.fromResult(
      await topics.list(actorAccountId: actor, conversationId: conversation),
      (items) => items.map(topicMetadata).toList(),
    );
  });

  router.post(Routes.groupTopics, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final conversation = id(request.pathParams['conversationId']);
    final root = bodyId(request, 'rootMessageId');
    if (conversation == null || root == null) return invalid();
    final result = await topics.create(
      actorAccountId: actor,
      conversationId: conversation,
      rootMessageId: root,
    );
    if (result.isOk) {
      await record(actor, result.value.id, 'topic.create', {
        'conversationId': conversation,
        'rootMessageId': root,
      });
    }
    return HostResponse.fromResult(result, topicMetadata);
  });

  router.get(Routes.topic, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final topic = id(request.pathParams['topicId']);
    if (topic == null || request.body != null) return invalid();
    return HostResponse.fromResult(
      await topics.get(actorAccountId: actor, topicId: topic),
      topicMetadata,
    );
  });

  router.get(Routes.topicReferences, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final topic = id(request.pathParams['topicId']);
    if (topic == null || request.body != null) return invalid();
    return HostResponse.fromResult(
      await topics.references(actorAccountId: actor, topicId: topic),
      (items) => items.map(referenceMetadata).toList(),
    );
  });

  router.post(Routes.topicReferences, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final topic = id(request.pathParams['topicId']);
    final message = bodyId(request, 'messageId');
    if (topic == null || message == null) return invalid();
    final result = await topics.associate(
      actorAccountId: actor,
      topicId: topic,
      messageId: message,
    );
    if (result.isOk) {
      await record(actor, topic, 'topic.reference.associate', {
        'messageId': message,
      });
    }
    return HostResponse.fromResult(result);
  });
}
