import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'creative_activity_writer.dart';
import 'creative_adapters.dart';
import 'reports/reports_models.dart';
import 'sqlite_creative_authorization_store.dart';

class CreativeAuthorizationModule extends HostModule {
  CreativeAuthorizationModule({required this.store, this.activityWriter});

  final SqliteCreativeAuthorizationStore store;
  final CreativeActivityWriter? activityWriter;

  @override
  String get name => 'creative_authorization';

  @override
  Future<void> configure(HostServices services) async {
    services.provide<CreativeAuthorizationPolicy>(store, owner: name);
    final writer = activityWriter;
    if (writer != null) {
      services.provide<CreativeActivityWriter>(writer, owner: name);
    }
  }

  @override
  void mount(Router router) {
    router.put(Routes.creativeOwnerConsent, _replace);
  }

  Future<HostResponse> _replace(HostRequest request) async {
    final owner = request.principal!.accountId;
    final aiId = request.pathParams['aiId']!;
    try {
      validateId(aiId, kind: 'ai');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad ai id'),
      );
    }
    final parsed = request.jsonObject();
    if (parsed.isErr) {
      return HostResponse.failure(parsed.failureOrNull!);
    }
    final body = parsed.value;
    if (body.length != 2 ||
        !body.containsKey('scopes') ||
        !body.containsKey('radioEnabled')) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad authorization body'),
      );
    }
    final rawScopes = body['scopes'];
    final radioEnabled = body['radioEnabled'];
    if (rawScopes is! List ||
        rawScopes.length > CreativeScope.values.length ||
        radioEnabled is! bool) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad authorization body'),
      );
    }
    final scopes = <CreativeScope>{};
    for (final raw in rawScopes) {
      if (raw is! String) {
        return HostResponse.failure(
          const Failure(FailureCode.invalidArgument, 'bad authorization scope'),
        );
      }
      CreativeScope? scope;
      for (final candidate in CreativeScope.values) {
        if (candidate.name == raw) scope = candidate;
      }
      if (scope == null || !scopes.add(scope)) {
        return HostResponse.failure(
          const Failure(FailureCode.invalidArgument, 'bad authorization scope'),
        );
      }
    }
    try {
      await store.setAuthorization(
        ownerAccountId: owner,
        aiProfileId: aiId,
        scopes: scopes,
        radioEnabled: radioEnabled,
      );
    } on CreativeAuthorizationOwnershipException {
      return HostResponse.failure(
        const Failure(FailureCode.notFound, 'not found'),
      );
    }
    return HostResponse.ok({
      'aiId': aiId,
      'scopes': scopes.map((scope) => scope.name).toList()..sort(),
      'radioEnabled': radioEnabled,
    });
  }
}
