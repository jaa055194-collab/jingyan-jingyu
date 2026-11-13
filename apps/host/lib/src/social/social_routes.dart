import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'conversation_service.dart';

/// Mount authenticated group routes; identity always comes from the principal.
/// Direct messages are not implemented: friendship/blocking policy is required.
void mountSocialRoutes(Router router, ConversationService conversations) {
  HostResponse invalid() => HostResponse.failure(
    const Failure(
      FailureCode.invalidArgument,
      'Invalid group input; DM is not implemented',
    ),
  );

  router.get(Routes.conversations, (request) async {
    final result = await conversations.list(request.principal!.accountId);
    return HostResponse.fromResult(
      result,
      (groups) => {
        'conversations': [for (final group in groups) group.toJson()],
      },
    );
  });

  router.post(Routes.conversations, (request) async {
    final body = request.jsonObject().valueOrNull;
    if (body == null ||
        body.keys.any(
          (key) => !const {'name', 'kind', 'historyVisibility'}.contains(key),
        )) {
      return invalid();
    }
    final name = body['name'];
    final kind = body['kind'];
    final visibility = body['historyVisibility'];
    if (name is! String ||
        (body.containsKey('kind') && kind != 'group') ||
        (body.containsKey('historyVisibility') &&
            visibility != 'all' &&
            visibility != 'joined')) {
      return invalid();
    }
    final result = await conversations.createGroup(
      ownerAccountId: request.principal!.accountId,
      name: name,
      historyVisibility: visibility == 'joined'
          ? HistoryVisibility.joined
          : HistoryVisibility.all,
    );
    return HostResponse.fromResult(result, (group) => group.toJson());
  });

  router.post(Routes.conversationMembers, (request) async {
    final body = request.jsonObject().valueOrNull;
    if (body == null || body.keys.any((key) => key != 'accountId')) {
      return invalid();
    }
    final accountId = body['accountId'];
    if (accountId is! String) return invalid();
    // The service enforces owner-only invitations and returns notFound for
    // non-owners, unknown groups, and accounts that cannot join.
    final result = await conversations.addMember(
      actorAccountId: request.principal!.accountId,
      conversationId: request.pathParams['conversationId']!,
      memberAccountId: accountId,
    );
    return HostResponse.fromResult(result);
  });
}
