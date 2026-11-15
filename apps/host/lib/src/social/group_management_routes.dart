import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../accounts/db_authenticator.dart';
import '../audit/audit_log.dart';
import 'conversation_service.dart';

/// Mounts authenticated routes for group ownership and membership management.
/// Actor identity always comes from a currently valid bearer and its principal.
void mountGroupManagementRoutes(
  Router router, {
  required ConversationService conversations,
  required AccountsDomain accounts,
  required Clock clock,
  required AuditLog audit,
}) {
  HostResponse invalid() => HostResponse.failure(
    const Failure(
      FailureCode.invalidArgument,
      'Invalid group management input',
    ),
  );
  HostResponse unauthenticated() => HostResponse.failure(
    const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
  );

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
    try {
      return AccountId.parse(principal.accountId).value;
    } on FormatException {
      return null;
    }
  }

  String? conversationId(HostRequest request) {
    try {
      return ConversationId.parse(
        request.pathParams['conversationId'] ?? '',
      ).value;
    } on FormatException {
      return null;
    }
  }

  String? pathAccountId(HostRequest request) {
    try {
      return AccountId.parse(request.pathParams['accountId'] ?? '').value;
    } on FormatException {
      return null;
    }
  }

  bool emptyBody(HostRequest request) => request.body == null;

  Future<void> record(
    String actor,
    String conversation,
    String action, {
    String? targetAccountId,
  }) => audit.record(
    AuditEntry(
      at: clock.now(),
      actorId: actor,
      action: action,
      targetKind: 'conversation',
      targetId: conversation,
      meta: {'targetAccountId': ?targetAccountId},
    ),
  );

  router.put(Routes.groupName, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final conversation = conversationId(request);
    final body = request.jsonObject().valueOrNull;
    if (conversation == null ||
        request.query.isNotEmpty ||
        body == null ||
        body.length != 1 ||
        body['name'] is! String) {
      return invalid();
    }
    final result = await conversations.setName(
      actorId: actor,
      conversationId: conversation,
      name: body['name'] as String,
    );
    if (result.isOk) await record(actor, conversation, 'group.name.set');
    return HostResponse.fromResult(result);
  });

  router.put(Routes.groupOwner, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final conversation = conversationId(request);
    if (conversation == null) return invalid();
    final body = request.jsonObject().valueOrNull;
    if (body == null || body.length != 1 || body['accountId'] is! String) {
      return invalid();
    }
    final target = body['accountId'] as String;
    try {
      AccountId.parse(target);
    } on FormatException {
      return invalid();
    }
    final result = await conversations.transferOwnership(
      actorId: actor,
      conversationId: conversation,
      newOwnerId: target,
    );
    if (result.isOk) {
      await record(
        actor,
        conversation,
        'group.owner.transfer',
        targetAccountId: target,
      );
    }
    return HostResponse.fromResult(result);
  });

  router.post(Routes.groupLeave, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final conversation = conversationId(request);
    if (conversation == null || !emptyBody(request)) return invalid();
    final result = await conversations.leave(
      actorId: actor,
      conversationId: conversation,
    );
    if (result.isOk) await record(actor, conversation, 'group.leave');
    return HostResponse.fromResult(result);
  });

  router.delete(Routes.groupMember, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final conversation = conversationId(request);
    final target = pathAccountId(request);
    if (conversation == null || target == null || !emptyBody(request)) {
      return invalid();
    }
    final result = await conversations.removeMember(
      actorId: actor,
      conversationId: conversation,
      targetId: target,
    );
    if (result.isOk) {
      await record(
        actor,
        conversation,
        'group.member.remove',
        targetAccountId: target,
      );
    }
    return HostResponse.fromResult(result);
  });

  router.post(Routes.groupAiWithdraw, (request) async {
    final operator = await actorId(request);
    if (operator == null) return unauthenticated();
    final conversation = conversationId(request);
    final aiAccount = pathAccountId(request);
    if (conversation == null || aiAccount == null || !emptyBody(request)) {
      return invalid();
    }
    final result = await conversations.withdrawAi(
      operatorId: operator,
      conversationId: conversation,
      aiAccountId: aiAccount,
    );
    if (result.isOk) {
      await record(
        operator,
        conversation,
        'group.ai.withdraw',
        targetAccountId: aiAccount,
      );
    }
    return HostResponse.fromResult(result);
  });

  router.put(Routes.groupAnnouncement, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final conversation = conversationId(request);
    if (conversation == null) return invalid();
    final body = request.jsonObject().valueOrNull;
    if (body == null ||
        body.keys.any((key) => key != 'text') ||
        (body['text'] != null && body['text'] is! String)) {
      return invalid();
    }
    final result = await conversations.setAnnouncement(
      actorId: actor,
      conversationId: conversation,
      text: body['text'] as String?,
    );
    if (result.isOk) {
      await record(actor, conversation, 'group.announcement.set');
    }
    return HostResponse.fromResult(result);
  });

  router.get(Routes.groupAnnouncement, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final conversation = conversationId(request);
    if (conversation == null) return invalid();
    final result = await conversations.getAnnouncement(
      accountId: actor,
      conversationId: conversation,
    );
    return HostResponse.fromResult(result, (text) => {'announcement': text});
  });
}
