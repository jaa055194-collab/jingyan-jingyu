import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../accounts/db_authenticator.dart';
import '../audit/audit_log.dart';
import '../storage/database.dart';
import 'private_conversations.dart';

/// Fixed private members are the authenticated account and the explicit target.
/// The bearer account/device are revalidated even behind a cached authenticator.
void mountPrivateRoutes(
  Router router, {
  required Database db,
  required Clock clock,
  required AccountsDomain accounts,
  required AuditLog audit,
  required PrivateConversations direct,
}) {
  HostResponse invalid() => HostResponse.failure(
    const Failure(
      FailureCode.invalidArgument,
      'Invalid private conversation input',
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

  router.get(Routes.directConversations, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final body = request.body;
    if (body != null && (body is! Map || body.isNotEmpty)) return invalid();
    return HostResponse.fromResult(
      await direct.list(actor),
      (items) => {
        'conversations': [for (final item in items) item.toJson()],
      },
    );
  });

  router.post(Routes.directConversations, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final body = request.jsonObject().valueOrNull;
    if (body == null || body.length != 1 || body['accountId'] is! String) {
      return invalid();
    }
    final result = await direct.open(
      actorId: actor,
      targetId: body['accountId'] as String,
    );
    if (result.isErr) return HostResponse.failure(result.failureOrNull!);
    final conversation = result.value;
    await audit.record(
      AuditEntry(
        at: clock.now(),
        actorId: actor,
        action: 'direct.open',
        targetKind: 'conversation',
        targetId: conversation.id,
      ),
    );
    return HostResponse.ok(conversation.toJson());
  });
}
