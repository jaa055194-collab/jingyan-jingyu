import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../accounts/db_authenticator.dart';
import '../audit/audit_log.dart';
import '../storage/database.dart';
import 'budget_configuration.dart';
import 'provider_registry.dart';
import 'usage_meter.dart';

void mountBudgetRoutes(
  Router router, {
  required Database db,
  required Clock clock,
  required AccountsDomain accounts,
  required AuditLog audit,
}) {
  HostResponse invalid() => HostResponse.failure(
    const Failure(
      FailureCode.invalidArgument,
      'Complete valid budget input required',
    ),
  );
  HostResponse unauthenticated() => HostResponse.failure(
    const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
  );

  Future<bool> authorized(HostRequest request) async {
    final header = request.headers['authorization'] ?? '';
    final bearer = header.startsWith('Bearer ')
        ? header.substring(7).trim()
        : '';
    if ((await accounts.scope(bearer)).isErr) return false;
    final current = await accounts.authenticate(bearer);
    return current != null &&
        current.accountId == request.principal?.accountId &&
        current.deviceId == request.principal?.deviceId;
  }

  BudgetConfiguration service(HostRequest request) =>
      BudgetConfiguration.forOwner(
        ownerId: request.principal!.accountId,
        db: db,
        clock: clock,
      );
  AiId? identity(HostRequest request) {
    try {
      return AiId.parse(request.pathParams['aiId'] ?? '');
    } on FormatException {
      return null;
    }
  }

  router.get(Routes.aiBudget, (request) async {
    if (!await authorized(request)) return unauthenticated();
    final ai = identity(request);
    if (ai == null) return invalid();
    final result = await service(request).get(ai);
    if (result.failureOrNull?.details['configurationRequired'] == true) {
      return HostResponse.ok({'configurationRequired': true});
    }
    return HostResponse.fromResult(result, (view) => view.toJson());
  });

  router.put(Routes.aiBudget, (request) async {
    if (!await authorized(request)) return unauthenticated();
    final ai = identity(request);
    if (ai == null) return invalid();
    final body = request.body;
    const keys = {
      'dailyTokens',
      'layerLimits',
      'capabilityLimits',
      'offsetMinutes',
    };
    if (body is! Map ||
        body.length != keys.length ||
        body.keys.any((k) => !keys.contains(k))) {
      return invalid();
    }
    final daily = body['dailyTokens'];
    final offset = body['offsetMinutes'];
    final layers = body['layerLimits'];
    final capabilities = body['capabilityLimits'];
    bool complete(Object? value, Iterable<String> names) =>
        value is Map &&
        value.length == names.length &&
        names.every((name) => value[name] is int && (value[name] as int) >= 0);
    if (daily is! int ||
        daily < 0 ||
        offset is! int ||
        offset < -840 ||
        offset > 840 ||
        !complete(layers, BudgetLayer.values.map((l) => l.name)) ||
        !complete(capabilities, ProviderCapability.values.map((c) => c.name))) {
      return invalid();
    }
    final budget = UsageBudget(
      dailyTokens: daily,
      layerLimits: {
        for (final l in BudgetLayer.values) l: (layers as Map)[l.name] as int,
      },
      capabilityLimits: {
        for (final c in ProviderCapability.values)
          c: (capabilities as Map)[c.name] as int,
      },
    );
    final result = await service(
      request,
    ).configure(ai, budget, offsetMinutes: offset);
    if (result.isErr) return HostResponse.failure(result.failureOrNull!);
    await audit.record(
      AuditEntry(
        at: clock.now(),
        actorId: request.principal!.accountId,
        action: 'budget.configure',
        targetKind: 'ai_profile',
        targetId: ai.value,
        meta: {'offsetMinutes': offset},
      ),
    );
    return HostResponse.ok(
      BudgetConfigurationView(budget: budget, offsetMinutes: offset).toJson(),
    );
  });
}
