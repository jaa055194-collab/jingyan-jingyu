import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../accounts/db_authenticator.dart';
import '../audit/audit_log.dart';
import '../storage/database.dart';
import 'owner_ai_direct_consent.dart';

/// Explicit ownerTextOnly consent metadata, not a send/model-dispatch endpoint.
/// The authenticated account and device are independently revalidated; no owner
/// or AI account identity is accepted from JSON. Admin grants no delegation.
void mountOwnerAiDirectRoutes(
  Router router, {
  required Database db,
  required Clock clock,
  required AccountsDomain accounts,
  required AuditLog audit,
}) {
  final service = OwnerAiDirectConsent(database: db, clock: clock);
  Future<HostResponse> handle(HostRequest request, String operation) async {
    final header = request.headers['authorization'] ?? '';
    final bearer = header.startsWith('Bearer ')
        ? header.substring(7).trim()
        : '';
    final session = await accounts.scope(bearer);
    final current = session.isOk ? await accounts.authenticate(bearer) : null;
    if (current == null ||
        current.accountId != request.principal?.accountId ||
        current.deviceId != request.principal?.deviceId) {
      return HostResponse.failure(
        const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
      );
    }
    HostResponse bad() => HostResponse.failure(
      const Failure(FailureCode.invalidArgument, 'Invalid consent input'),
    );
    if (request.query.isNotEmpty) return bad();
    final profile = request.pathParams['aiId'] ?? '';
    if (operation == 'get') {
      if (request.body != null) return bad();
      return HostResponse.fromResult(
        await service.get(ownerId: current.accountId, aiProfileId: profile),
      );
    }
    final body = request.jsonObject().valueOrNull;
    if (body == null ||
        body.length != 1 ||
        body['expectedRevision'] is! int ||
        (body['expectedRevision'] as int) < 0) {
      return bad();
    }
    final revision = body['expectedRevision'] as int;
    final result = operation == 'open'
        ? await service.open(
            ownerId: current.accountId,
            aiProfileId: profile,
            expectedRevision: revision,
          )
        : await service.revoke(
            ownerId: current.accountId,
            aiProfileId: profile,
            expectedRevision: revision,
          );
    if (result.isErr) return HostResponse.failure(result.failureOrNull!);
    final view = result.value;
    // Consent has committed. Audit is best-effort and non-atomic; do not return
    // 500 for an applied CAS mutation or pretend audit delivery is guaranteed.
    // Envelope only: no messages, source text, provider identity or credentials.
    try {
      await audit.record(
        AuditEntry(
          at: clock.now(),
          actorId: current.accountId,
          action: 'owner_ai_direct.$operation',
          targetKind: 'ai_profile',
          targetId: profile,
          meta: {'revision': view['revision'], 'enabled': view['enabled']},
        ),
      );
    } catch (_) {
      // Keep the truthful committed consent response, as message recall does.
    }
    return HostResponse.ok(view);
  }

  router.get(Routes.ownerAiDirectConsent, (r) => handle(r, 'get'));
  router.post(Routes.ownerAiDirectConsent, (r) => handle(r, 'open'));
  router.delete(Routes.ownerAiDirectConsent, (r) => handle(r, 'revoke'));
}
