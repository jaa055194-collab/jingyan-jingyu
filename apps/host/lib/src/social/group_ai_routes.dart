import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../accounts/db_authenticator.dart';
import '../audit/audit_log.dart';
import '../storage/database.dart';
import 'group_ai_policy.dart';

/// Mounts group AI configuration only; no route checks or consumes admissions.
///
/// Settings PUT is a full replacement: dailyCap is required, while omitted
/// maxPerRound, autonomousInterjection, interjectionGapSeconds and hosting use
/// GroupAiSettings defaults. The AI owner's interval is configured separately.
void mountGroupAiRoutes(
  Router router, {
  required Database db,
  required Clock clock,
  required AccountsDomain accounts,
  required AuditLog audit,
}) {
  HostResponse invalid() => HostResponse.failure(
    const Failure(FailureCode.invalidArgument, 'Invalid group AI input'),
  );
  HostResponse unauthenticated() => HostResponse.failure(
    const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
  );
  // Duration stores signed 64-bit microseconds; validate before multiplication.
  const maxDurationSeconds = 9223372036854;

  Future<AccountId?> actorId(HostRequest request) async {
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

  ConversationId? conversationId(HostRequest request) {
    try {
      return ConversationId.parse(request.pathParams['conversationId'] ?? '');
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

  GroupAiPolicy policy(AccountId actor) =>
      GroupAiPolicy.configuration(actorId: actor, database: db, clock: clock);

  Map<String, Object?> settingsMetadata(GroupAiSettings settings) => {
    'dailyCap': settings.dailyCap,
    'maxPerRound': settings.maxPerRound,
    'autonomousInterjection': settings.autonomousInterjection,
    'interjectionGapSeconds': settings.interjectionGap.inSeconds,
    'hosting': settings.hosting,
  };

  Future<void> record(
    AccountId actor,
    ConversationId conversation,
    String action,
    Map<String, Object?> metadata,
  ) => audit.record(
    AuditEntry(
      at: clock.now(),
      actorId: actor.value,
      action: action,
      targetKind: 'conversation',
      targetId: conversation.value,
      meta: metadata,
    ),
  );

  router.get(Routes.groupAiSettings, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final group = conversationId(request);
    if (group == null || request.body != null) return invalid();
    return HostResponse.fromResult(
      await policy(actor).getSettings(group),
      (settings) => {
        ...settingsMetadata(settings),
        'minIntervalSeconds': settings.minInterval.inSeconds,
      },
    );
  });

  router.put(Routes.groupAiSettings, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final group = conversationId(request);
    final body = request.jsonObject().valueOrNull;
    const allowed = {
      'dailyCap',
      'maxPerRound',
      'autonomousInterjection',
      'interjectionGapSeconds',
      'hosting',
    };
    if (group == null ||
        body == null ||
        body.keys.any((key) => !allowed.contains(key)) ||
        body['dailyCap'] is! int ||
        (body.containsKey('maxPerRound') && body['maxPerRound'] is! int) ||
        (body.containsKey('autonomousInterjection') &&
            body['autonomousInterjection'] is! bool) ||
        (body.containsKey('interjectionGapSeconds') &&
            (body['interjectionGapSeconds'] is! int ||
                (body['interjectionGapSeconds'] as int) < 0 ||
                (body['interjectionGapSeconds'] as int) >
                    maxDurationSeconds)) ||
        (body.containsKey('hosting') && body['hosting'] is! bool)) {
      return invalid();
    }
    final settings = GroupAiSettings(
      dailyCap: body['dailyCap'] as int,
      maxPerRound: body['maxPerRound'] as int? ?? 1,
      autonomousInterjection: body['autonomousInterjection'] as bool? ?? false,
      interjectionGap: Duration(
        seconds: body['interjectionGapSeconds'] as int? ?? 600,
      ),
      hosting: body['hosting'] as bool? ?? false,
    );
    final scopedPolicy = policy(actor);
    final result = await scopedPolicy.updateSettings(group, settings);
    if (result.isOk) {
      final effective = await scopedPolicy.getSettings(group);
      if (effective.isOk) {
        await record(
          actor,
          group,
          'group.ai.settings.update',
          settingsMetadata(effective.value),
        );
      }
    }
    return HostResponse.fromResult(result);
  });

  router.put(Routes.groupAiInterval, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final group = conversationId(request);
    final ai = targetId(request);
    final body = request.jsonObject().valueOrNull;
    if (group == null ||
        ai == null ||
        body == null ||
        body.length != 1 ||
        body['seconds'] is! int ||
        (body['seconds'] as int) < 0 ||
        (body['seconds'] as int) > maxDurationSeconds) {
      return invalid();
    }
    final seconds = body['seconds'] as int;
    final result = await policy(
      actor,
    ).updateMinInterval(ai, group, Duration(seconds: seconds));
    if (result.isOk) {
      await record(actor, group, 'group.ai.interval.update', {
        'targetAccountId': ai.value,
        'seconds': seconds,
      });
    }
    return HostResponse.fromResult(result);
  });

  router.put(Routes.groupAiMute, (request) async {
    final actor = await actorId(request);
    if (actor == null) return unauthenticated();
    final group = conversationId(request);
    final ai = targetId(request);
    final body = request.jsonObject().valueOrNull;
    if (group == null ||
        ai == null ||
        body == null ||
        body.length != 1 ||
        body['muted'] is! bool) {
      return invalid();
    }
    final muted = body['muted'] as bool;
    final result = await policy(actor).setMuted(ai, group, muted: muted);
    if (result.isOk) {
      await record(actor, group, 'group.ai.mute.update', {
        'targetAccountId': ai.value,
        'muted': muted,
      });
    }
    return HostResponse.fromResult(result);
  });
}
