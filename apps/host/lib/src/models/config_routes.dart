import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../accounts/db_authenticator.dart';
import '../audit/audit_log.dart';
import '../storage/database.dart';
import 'binding_matrix.dart';
import 'provider_registry.dart';

/// Owner-scoped binding configuration. Budget routes are intentionally absent
/// until configuration and timezone can be persisted in one transaction.
void mountModelConfigRoutes(
  Router router, {
  required Database db,
  required Clock clock,
  required AccountsDomain accounts,
  required AuditLog audit,
}) {
  HostResponse invalid() => HostResponse.failure(
    const Failure(FailureCode.invalidArgument, 'Invalid binding input'),
  );

  Future<HostResponse?> authenticate(HostRequest request) async {
    final header = request.headers['authorization'] ?? '';
    final bearer = header.startsWith('Bearer ')
        ? header.substring(7).trim()
        : '';
    final session = await accounts.scope(bearer);
    if (session.isErr) return HostResponse.failure(session.failureOrNull!);
    final current = await accounts.authenticate(bearer);
    if (current == null ||
        current.accountId != request.principal?.accountId ||
        current.deviceId != request.principal?.deviceId) {
      return HostResponse.failure(
        const Failure(FailureCode.unauthenticated, 'Authentication required'),
      );
    }
    return null;
  }

  BindingMatrix matrix(HostRequest request) =>
      BindingMatrix.forOwner(request.principal!.accountId, db);

  AiId? profile(HostRequest request) {
    try {
      return AiId.parse(request.pathParams['aiId'] ?? '');
    } on FormatException {
      return null;
    }
  }

  ProviderCapability? capability(HostRequest request) {
    final raw = request.pathParams['capability'];
    for (final value in ProviderCapability.values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  Future<void> record(
    HostRequest request,
    String action,
    AiId ai,
    ProviderCapability capability,
  ) => audit.record(
    AuditEntry(
      at: clock.now(),
      actorId: request.principal!.accountId,
      action: action,
      targetKind: 'model_binding',
      targetId: '${ai.value}:${capability.name}',
    ),
  );

  router.get(Routes.aiBindings, (request) async {
    final failure = await authenticate(request);
    if (failure != null) return failure;
    final ai = profile(request);
    if (ai == null) return invalid();
    return HostResponse.fromResult(
      await matrix(request).list(ai),
      (bindings) => bindings.map((binding) => binding.toJson()).toList(),
    );
  });

  router.put(Routes.aiBinding, (request) async {
    final failure = await authenticate(request);
    if (failure != null) return failure;
    final ai = profile(request);
    final cap = capability(request);
    if (ai == null || cap == null) return invalid();
    final body = request.body;
    if (body is! Map<String, Object?> ||
        body.length != 2 ||
        !body.containsKey('providerId') ||
        !body.containsKey('model')) {
      return invalid();
    }
    final providerId = body['providerId'];
    final model = body['model'];
    if (providerId is! String || model is! String) return invalid();
    try {
      validateId(providerId, kind: 'provider');
    } on FormatException {
      return invalid();
    }
    final result = await matrix(
      request,
    ).set(ai, cap, providerId: providerId, model: model);
    if (result.isOk) await record(request, 'binding.set', ai, cap);
    return HostResponse.fromResult(result, (binding) => binding.toJson());
  });

  router.delete(Routes.aiBinding, (request) async {
    final failure = await authenticate(request);
    if (failure != null) return failure;
    final ai = profile(request);
    final cap = capability(request);
    if (ai == null || cap == null) return invalid();
    final result = await matrix(request).clear(ai, cap);
    if (result.isOk) await record(request, 'binding.clear', ai, cap);
    return HostResponse.fromResult(result);
  });
}
