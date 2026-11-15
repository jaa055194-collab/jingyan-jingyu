import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../accounts/db_authenticator.dart';
import '../storage/database.dart';
import 'conversation_preferences.dart';

void mountConversationPreferenceRoutes(
  Router router, {
  required Database db,
  required AccountsDomain accounts,
}) {
  final prefs = ConversationPreferences(database: db);
  Future<HostResponse> handle(
    HostRequest request, {
    required bool write,
  }) async {
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
    HostResponse bad() => HostResponse.failure(
      const Failure(FailureCode.invalidArgument, 'Invalid preference input'),
    );
    if (request.query.isNotEmpty) return bad();
    final conversation = request.pathParams['conversationId'] ?? '';
    if (!write) {
      if (request.body != null) return bad();
      return HostResponse.fromResult(
        await prefs.get(
          accountId: current.accountId,
          conversationId: conversation,
        ),
      );
    }
    final body = request.jsonObject().valueOrNull;
    if (body == null || body.length != 1 || body['pinned'] is! bool) {
      return bad();
    }
    return HostResponse.fromResult(
      await prefs.set(
        accountId: current.accountId,
        conversationId: conversation,
        pinned: body['pinned'] as bool,
      ),
    );
  }

  router.get(
    Routes.conversationPreferences,
    (request) => handle(request, write: false),
  );
  router.put(
    Routes.conversationPreferences,
    (request) => handle(request, write: true),
  );
}
