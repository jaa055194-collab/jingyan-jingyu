import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import '../../audit/audit_log.dart';
import 'social_level_service.dart';

/// Explicit configuration only. Saving L0 does not cancel tasks; no queues or
/// reply dispatch are connected. L3/L4 does not grant recipient consent/L4 mode.
final class SocialLevelModule extends HostModule {
  SocialLevelModule({
    required this.service,
    required this.authenticate,
    required this.clock,
  });
  final SocialLevelService service;
  final Authenticator authenticate;
  final Clock clock;
  late AuditLog _audit;
  @override
  String get name => 'social_level';
  @override
  List<String> get dependsOn => const ['storage', 'accounts'];
  @override
  Future<void> configure(HostServices services) async {
    services.provide<SocialLevelService>(service, owner: name);
    _audit = services.get<AuditLog>();
  }

  HostResponse _bad() => HostResponse.failure(
    const Failure(FailureCode.invalidArgument, 'Invalid social level input'),
  );
  Future<HostResponse> _handle(
    HostRequest request, {
    required bool write,
  }) async {
    final current = await authenticate(request);
    if (current == null ||
        current.accountId != request.principal?.accountId ||
        current.deviceId != request.principal?.deviceId) {
      return HostResponse.failure(
        const Failure(FailureCode.unauthenticated, 'Authentication required'),
      );
    }
    final AiId ai;
    final AccountId owner;
    try {
      ai = AiId.parse(request.pathParams['aiId'] ?? '');
      owner = AccountId.parse(current.accountId);
    } on FormatException {
      return _bad();
    }
    if (request.query.isNotEmpty) return _bad();
    if (!write) {
      final length = request.headers['content-length'];
      if (request.body != null ||
          (length != null && int.tryParse(length) != 0) ||
          request.headers.containsKey('transfer-encoding')) {
        return _bad();
      }
      return HostResponse.fromResult(
        await service.get(owner: owner, ai: ai),
        (view) => view.toJson(),
      );
    }
    final body = request.jsonObject().valueOrNull;
    if (body == null || body.length != 1 || body['level'] is! String) {
      return _bad();
    }
    final level = AiSocialLevel.tryParse(body['level'] as String);
    if (level == null) return _bad();
    final result = await service.set(owner: owner, ai: ai, level: level);
    if (result.isOk) {
      // Existing audit service is postcommit, not atomic with setting storage.
      await _audit.record(
        AuditEntry(
          at: clock.now(),
          actorId: owner.value,
          action: 'ai.social_level.configure',
          targetKind: 'ai_profile',
          targetId: ai.value,
          meta: {'level': level.wire},
        ),
      );
    }
    return HostResponse.fromResult(result, (view) => view.toJson());
  }

  @override
  void mount(Router router) {
    router.get(
      Routes.aiSocialLevel,
      (request) => _handle(request, write: false),
    );
    router.put(
      Routes.aiSocialLevel,
      (request) => _handle(request, write: true),
    );
  }
}
