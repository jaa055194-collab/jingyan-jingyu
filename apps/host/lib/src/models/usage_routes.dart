import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../accounts/db_authenticator.dart';
import '../storage/database.dart';
import 'usage_summary.dart';

void mountUsageRoutes(
  Router router, {
  required Database db,
  required Clock clock,
  required AccountsDomain accounts,
}) {
  router.get(Routes.aiUsage, (request) async {
    final header = request.headers['authorization'] ?? '';
    final bearer = header.startsWith('Bearer ')
        ? header.substring(7).trim()
        : '';
    final scoped = await accounts.scope(bearer);
    final current = scoped.isOk ? await accounts.authenticate(bearer) : null;
    if (current == null ||
        current.accountId != request.principal?.accountId ||
        current.deviceId != request.principal?.deviceId) {
      return HostResponse.failure(
        const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
      );
    }
    final AiId ai;
    try {
      ai = AiId.parse(request.pathParams['aiId'] ?? '');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'Invalid AI profile'),
      );
    }
    if (request.query.isNotEmpty) {
      return HostResponse.failure(
        const Failure(
          FailureCode.invalidArgument,
          'Usage day is server derived',
        ),
      );
    }
    final result = await UsageSummary.forOwner(
      ownerId: current.accountId,
      db: db,
      clock: clock,
    ).today(ai);
    if (result.failureOrNull?.details['configurationRequired'] == true) {
      return HostResponse.ok({'configurationRequired': true});
    }
    return HostResponse.fromResult(result);
  });
}
