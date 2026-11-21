import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'owner_reply_preferences.dart';

final class OwnerReplyPreferencesModule extends HostModule {
  OwnerReplyPreferencesModule(this.preferences, this.authenticate);

  final OwnerReplyPreferences preferences;
  final Authenticator authenticate;

  @override
  String get name => 'owner_reply_preferences';

  @override
  List<String> get dependsOn => const ['storage', 'accounts'];

  HostResponse _invalid() => HostResponse.failure(
    const Failure(
      FailureCode.invalidArgument,
      'Invalid reply preference input',
    ),
  );

  Future<HostResponse> _handle(
    HostRequest request, {
    required bool write,
  }) async {
    final header = request.headers['authorization'];
    final bearer = header != null && header.startsWith('Bearer ')
        ? header.substring(7).trim()
        : '';
    final current = await authenticate(request);
    if (bearer.isEmpty ||
        current == null ||
        current.accountId != request.principal?.accountId ||
        current.deviceId != request.principal?.deviceId) {
      return HostResponse.failure(
        const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
      );
    }
    if (request.query.isNotEmpty) return _invalid();
    final owner = current.accountId;
    final AiId ai;
    try {
      ai = AiId.parse(request.pathParams['aiId'] ?? '');
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
      return HostResponse.fromResult(
        await preferences.read(
          owner: owner,
          device: current.deviceId,
          bearer: bearer,
          ai: ai,
        ),
      );
    }
    final body = request.jsonObject().valueOrNull;
    const fields = {
      'expectedRevision',
      'enabled',
      'length',
      'format',
      'expectedTargetToken',
    };
    if (body == null ||
        body.length != fields.length ||
        !fields.every(body.containsKey)) {
      return _invalid();
    }
    final revision = body['expectedRevision'];
    final enabled = body['enabled'];
    final token = body['expectedTargetToken'];
    if (revision is! int ||
        revision < 0 ||
        enabled is! bool ||
        (token != null && (token is! String || token.length > 128))) {
      return _invalid();
    }
    final OwnerReplyChoices choices;
    try {
      choices = OwnerReplyChoices.parse(body['length'], body['format']);
    } on FormatException {
      return _invalid();
    }
    return HostResponse.fromResult(
      await preferences.write(
        owner: owner,
        device: current.deviceId,
        bearer: bearer,
        ai: ai,
        expectedRevision: revision,
        enabled: enabled,
        choices: choices,
        expectedTargetToken: token as String?,
      ),
    );
  }

  @override
  void mount(Router router) {
    router.get(
      Routes.aiOwnerReplyPreferences,
      (request) => _handle(request, write: false),
    );
    router.put(
      Routes.aiOwnerReplyPreferences,
      (request) => _handle(request, write: true),
    );
  }
}
