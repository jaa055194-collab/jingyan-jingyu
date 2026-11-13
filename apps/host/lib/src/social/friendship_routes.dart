import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../accounts/db_authenticator.dart';
import '../audit/audit_log.dart';
import '../storage/database.dart';
import 'friendship_service.dart';

/// Friendship authority always belongs to the currently authenticated account.
/// Operators cannot substitute their AI account when granting consent.
void mountFriendshipRoutes(
  Router router, {
  required Database db,
  required Clock clock,
  required AccountsDomain accounts,
  required AuditLog audit,
}) {
  HostResponse invalid() => HostResponse.failure(
    const Failure(FailureCode.invalidArgument, 'Invalid friendship input'),
  );
  HostResponse unauthenticated() => HostResponse.failure(
    const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
  );

  Future<AccountId?> principalAccountId(HostRequest request) async {
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
      return AccountId.parse(principal.accountId);
    } on FormatException {
      return null;
    }
  }

  AccountId? targetId(HostRequest request) {
    try {
      return AccountId.parse(request.pathParams['accountId'] ?? '');
    } on FormatException {
      return null;
    }
  }

  FriendshipService service(AccountId actor) =>
      FriendshipService(actorId: actor, database: db, clock: clock);

  router.get(Routes.friendState, (request) async {
    final actor = await principalAccountId(request);
    if (actor == null) return unauthenticated();
    final target = targetId(request);
    if (target == null) return invalid();
    return HostResponse.fromResult(
      await service(actor).getState(target),
      (state) => {'state': state.name},
    );
  });

  Future<HostResponse> mutate(
    HostRequest request,
    String action,
    Future<Result<void>> Function(FriendshipService, AccountId) operation,
  ) async {
    final actor = await principalAccountId(request);
    if (actor == null) return unauthenticated();
    final target = targetId(request);
    final body = request.body;
    if (target == null || (body != null && (body is! Map || body.isNotEmpty))) {
      return invalid();
    }
    final result = await operation(service(actor), target);
    if (result.isErr) return HostResponse.failure(result.failureOrNull!);
    await audit.record(
      AuditEntry(
        at: clock.now(),
        actorId: actor.value,
        action: 'friendship.$action',
        targetKind: 'account',
        targetId: target.value,
      ),
    );
    return HostResponse.ok(null);
  }

  router.post(
    Routes.friendRequest,
    (request) => mutate(request, 'request', (s, target) => s.request(target)),
  );
  router.post(
    Routes.friendAccept,
    (request) => mutate(request, 'accept', (s, target) => s.accept(target)),
  );
  router.post(
    Routes.friendDeny,
    (request) => mutate(request, 'deny', (s, target) => s.deny(target)),
  );
  router.post(
    Routes.friendBlock,
    (request) => mutate(request, 'block', (s, target) => s.block(target)),
  );
  router.delete(
    Routes.friendBlock,
    (request) => mutate(request, 'unblock', (s, target) => s.unblock(target)),
  );
}
