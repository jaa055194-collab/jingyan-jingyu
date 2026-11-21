import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'owner_rule_greeting.dart';

final class OwnerRuleGreetingModule extends HostModule {
  OwnerRuleGreetingModule(this.greetings, {this.enableTimer = true});
  final OwnerRuleGreeting greetings;
  final bool enableTimer;
  Timer? _timer;
  Future<void>? _tick;

  @override
  String get name => 'owner_rule_greeting';

  @override
  List<String> get dependsOn => const [
    'storage',
    'accounts',
    'messages',
    'social',
    'social_level',
  ];

  @override
  Future<void> configure(HostServices services) async =>
      services.provide<OwnerRuleGreeting>(greetings, owner: name);

  @override
  Future<void> start() async {
    greetings.beginObservation();
    if (!enableTimer) return;
    _timer = Timer.periodic(OwnerRuleGreeting.pollInterval, (_) {
      if (_tick != null) return;
      _tick = greetings
          .poll()
          .then<void>((_) {}, onError: (Object _, StackTrace _) {})
          .whenComplete(() => _tick = null);
    });
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _tick;
  }

  @override
  void mount(Router router) {
    router.get(
      Routes.aiOwnerRuleGreeting,
      (r) => _handle(r, write: false, global: false),
    );
    router.put(
      Routes.aiOwnerRuleGreeting,
      (r) => _handle(r, write: true, global: false),
    );
    router.get(
      Routes.ownerRuleGreetingStop,
      (r) => _handle(r, write: false, global: true),
    );
    router.put(
      Routes.ownerRuleGreetingStop,
      (r) => _handle(r, write: true, global: true),
    );
  }

  HostResponse _invalid() => HostResponse.failure(
    const Failure(
      FailureCode.invalidArgument,
      'Invalid rule greeting settings',
    ),
  );

  Future<HostResponse> _handle(
    HostRequest request, {
    required bool write,
    required bool global,
  }) async {
    final principal = request.principal;
    final authorization = request.headers['authorization'];
    if (principal == null ||
        authorization == null ||
        !authorization.startsWith('Bearer ')) {
      return HostResponse.failure(
        const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
      );
    }
    if (request.query.isNotEmpty) return _invalid();
    final caller = (
      owner: principal.accountId,
      device: principal.deviceId,
      bearer: authorization.substring(7).trim(),
    );
    final AiId? ai;
    try {
      ai = global ? null : AiId.parse(request.pathParams['aiId'] ?? '');
    } on FormatException {
      return _invalid();
    }
    if (!write) {
      final length = request.headers['content-length'];
      if (request.body != null ||
          (length != null && int.tryParse(length) != 0) ||
          request.headers.containsKey('transfer-encoding')) {
        return _invalid();
      }
      return _response(
        await (global
            ? greetings.stopSettings(caller)
            : greetings.settings(caller, ai!)),
      );
    }
    final body = request.jsonObject().valueOrNull;
    if (body == null) return _invalid();
    final expectedRevision = body['expectedRevision'];
    if (expectedRevision is! int || expectedRevision < 0) return _invalid();
    if (global) {
      final blocked = body['blocked'];
      if (body.length != 2 || blocked is! bool) return _invalid();
      return _response(
        await greetings.stopSettings(
          caller,
          update: (expectedRevision: expectedRevision, blocked: blocked),
        ),
      );
    }
    if (body.length != 8 ||
        !const {
          'expectedRevision',
          'enabled',
          'localMinute',
          'offsetMinutes',
          'quietStartMinute',
          'quietEndMinute',
          'expectedChatRevision',
          'expectedGlobalRevision',
        }.every(body.containsKey)) {
      return _invalid();
    }
    final enabled = body['enabled'];
    final minute = body['localMinute'];
    final offset = body['offsetMinutes'];
    final quietStart = body['quietStartMinute'];
    final quietEnd = body['quietEndMinute'];
    final chat = body['expectedChatRevision'];
    final globalRevision = body['expectedGlobalRevision'];
    if (enabled is! bool ||
        minute is! int ||
        quietStart is! int ||
        quietEnd is! int ||
        (offset != null && offset is! int) ||
        (chat != null && chat is! int) ||
        (globalRevision != null && globalRevision is! int)) {
      return _invalid();
    }
    return _response(
      await greetings.settings(
        caller,
        ai!,
        update: (
          expectedRevision: expectedRevision,
          enabled: enabled,
          localMinute: minute,
          offsetMinutes: offset as int?,
          quietStartMinute: quietStart,
          quietEndMinute: quietEnd,
          expectedChatRevision: chat as int?,
          expectedGlobalRevision: globalRevision as int?,
        ),
      ),
    );
  }

  HostResponse _response(Result<Map<String, Object?>> result) => result.isOk
      ? HostResponse(
          200,
          json: result.value,
          headers: const {'Cache-Control': 'no-store'},
        )
      : HostResponse.failure(result.failureOrNull!);
}
