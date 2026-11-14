import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../accounts/db_authenticator.dart';
import '../storage/database.dart';
import 'ai_identity.dart';

/// Register existing AI accounts and resolve their owner-scoped profiles.
/// Account creation is separate: account and profile transactions cannot be
/// composed atomically through the current public domain interfaces.
void mountAiRoutes(
  Router router, {
  required AccountsDomain accounts,
  required Database db,
}) {
  HostResponse invalid() => HostResponse.failure(
    const Failure(FailureCode.invalidArgument, 'Invalid AI profile input'),
  );

  Future<Result<AccountSession>> session(HostRequest request) {
    final header = request.headers['authorization'] ?? '';
    return accounts.scope(
      header.startsWith('Bearer ') ? header.substring(7).trim() : '',
    );
  }

  AiIdentityResolver resolver(HostRequest request) =>
      AiIdentityResolver.forOwner(
        ownerId: request.principal!.accountId,
        db: db,
      );

  Map<String, Object?> encode(AiIdentity identity) => {
    'profileId': identity.profileId.value,
    'accountId': identity.aiAccountId.value,
    'ownerAccountId': identity.ownerAccountId.value,
  };

  router.post(Routes.aiProfileRegister, (request) async {
    final authenticated = await session(request);
    if (authenticated.isErr) {
      return HostResponse.failure(authenticated.failureOrNull!);
    }
    final body = request.jsonObject().valueOrNull;
    if (body == null || body.keys.any((key) => key != 'accountId')) {
      return invalid();
    }
    final raw = body['accountId'];
    if (raw is! String) return invalid();
    final AccountId accountId;
    try {
      accountId = AccountId.parse(raw);
    } on FormatException {
      return invalid();
    }
    return HostResponse.fromResult(
      await resolver(request).register(accountId),
      encode,
    );
  });

  router.get(Routes.aiProfile, (request) async {
    final authenticated = await session(request);
    if (authenticated.isErr) {
      return HostResponse.failure(authenticated.failureOrNull!);
    }
    final AiId profileId;
    try {
      profileId = AiId.parse(request.pathParams['aiId'] ?? '');
    } on FormatException {
      return invalid();
    }
    return HostResponse.fromResult(
      await resolver(request).resolve(profileId),
      encode,
    );
  });
}
