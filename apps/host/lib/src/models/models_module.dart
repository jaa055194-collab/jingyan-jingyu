import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../audit/audit_log.dart';
import '../accounts/db_authenticator.dart';
import 'ai_routes.dart';
import 'config_routes.dart';
import 'budget_routes.dart';
import 'usage_routes.dart';
import 'usage_trend_routes.dart';
import 'model_runtime.dart';
import '../security/url_guard.dart';
import '../storage/cipher.dart';
import '../storage/database.dart';
import 'provider_registry.dart';

/// Authenticated provider HTTP boundary. The host assembles migrations before
/// requests are accepted; ownership always comes from the current principal.
class ModelsModule extends HostModule {
  ModelsModule({
    required this.db,
    required this.cipher,
    required this.urlGuard,
    required this.clock,
    this.runtime,
  });

  final Database db;
  final ColumnCipher cipher;
  final UrlGuard urlGuard;
  final Clock clock;
  final ModelRuntime? runtime;
  late AuditLog _audit;
  AccountsDomain? _accounts;

  @override
  String get name => 'models';

  @override
  List<String> get dependsOn => const ['storage', 'accounts'];

  @override
  Future<void> configure(HostServices services) async {
    _audit = services.get<AuditLog>();
    _accounts = services.maybeGet<AccountsDomain>();
    final modelRuntime = runtime;
    if (modelRuntime != null) {
      services.provide<ModelRuntime>(modelRuntime, owner: name);
    }
  }

  @override
  void mount(Router router) {
    router.get(Routes.modelProviders, _list);
    router.post(Routes.modelProviders, _create);
    router.get(Routes.modelProvider, _get);
    router.put(Routes.modelProvider, _update);
    router.delete(Routes.modelProvider, _delete);
    final accounts = _accounts;
    if (accounts != null) {
      mountAiRoutes(router, accounts: accounts, db: db);
      mountUsageRoutes(router, db: db, clock: clock, accounts: accounts);
      mountUsageTrendRoutes(router, db: db, clock: clock, accounts: accounts);
      mountBudgetRoutes(
        router,
        db: db,
        clock: clock,
        accounts: accounts,
        audit: _audit,
      );
      mountModelConfigRoutes(
        router,
        db: db,
        clock: clock,
        accounts: accounts,
        audit: _audit,
      );
    }
  }

  ProviderRegistry _registry(HostRequest request) => ProviderRegistry.forOwner(
    ownerId: request.principal!.accountId,
    db: db,
    cipher: cipher,
    urlGuard: urlGuard,
    clock: clock,
  );

  HostResponse _bad() => HostResponse.failure(
    const Failure(FailureCode.invalidArgument, 'Invalid provider input'),
  );

  static const _fields = {
    'name',
    'base_url',
    'api_key',
    'capabilities',
    'enabled',
  };

  Map<String, Object?>? _body(HostRequest request, {required bool create}) {
    final body = request.body;
    if (body is! Map<String, Object?> ||
        body.keys.any((key) => !_fields.contains(key))) {
      return null;
    }
    for (final field in ['name', 'base_url', 'api_key']) {
      if ((create || body.containsKey(field)) && body[field] is! String) {
        return null;
      }
    }
    if (body.containsKey('enabled') && body['enabled'] is! bool) return null;
    if (create || body.containsKey('capabilities')) {
      final capabilities = body['capabilities'];
      if (capabilities is! List ||
          capabilities.any(
            (value) =>
                value is! String ||
                !ProviderCapability.values.any(
                  (capability) => capability.name == value,
                ),
          )) {
        return null;
      }
    }
    return body;
  }

  Set<ProviderCapability> _capabilities(Object? raw) => (raw as List)
      .map((value) => ProviderCapability.values.byName(value as String))
      .toSet();

  Future<void> _record(HostRequest request, String action, String id) =>
      _audit.record(
        AuditEntry(
          at: clock.now(),
          actorId: request.principal!.accountId,
          action: action,
          targetKind: 'provider',
          targetId: id,
        ),
      );

  Future<HostResponse> _list(HostRequest request) async =>
      HostResponse.fromResult(
        await _registry(request).list(),
        (providers) => providers.map((provider) => provider.toJson()).toList(),
      );

  Future<HostResponse> _get(HostRequest request) async =>
      HostResponse.fromResult(
        await _registry(request).get(request.pathParams['providerId']!),
        (provider) => provider.toJson(),
      );

  Future<HostResponse> _create(HostRequest request) async {
    final body = _body(request, create: true);
    if (body == null) return _bad();
    final result = await _registry(request).create(
      name: body['name'] as String,
      baseUrl: body['base_url'] as String,
      apiKey: body['api_key'] as String,
      capabilities: _capabilities(body['capabilities']),
      enabled: body['enabled'] as bool? ?? true,
    );
    if (result case Ok<ProviderView>(:final value)) {
      await _record(request, 'provider.create', value.id);
    }
    return HostResponse.fromResult(result, (provider) => provider.toJson());
  }

  Future<HostResponse> _update(HostRequest request) async {
    final body = _body(request, create: false);
    if (body == null) return _bad();
    final result = await _registry(request).update(
      request.pathParams['providerId']!,
      name: body['name'] as String?,
      baseUrl: body['base_url'] as String?,
      apiKey: body['api_key'] as String?,
      capabilities: body.containsKey('capabilities')
          ? _capabilities(body['capabilities'])
          : null,
      enabled: body['enabled'] as bool?,
    );
    if (result case Ok<ProviderView>(:final value)) {
      await _record(request, 'provider.update', value.id);
    }
    return HostResponse.fromResult(result, (provider) => provider.toJson());
  }

  Future<HostResponse> _delete(HostRequest request) async {
    final id = request.pathParams['providerId']!;
    final result = await _registry(request).delete(id);
    if (result.isOk) await _record(request, 'provider.delete', id);
    return HostResponse.fromResult(result);
  }
}
