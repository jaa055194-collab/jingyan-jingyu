import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../storage/cipher.dart';
import '../storage/database.dart';
import 'android_private_chat.dart';

/// Private Android exchange sync; no ordinary chat, settings or dispatch.
final class AndroidPrivateChatModule extends HostModule {
  late AndroidPrivateChat _chat;

  @override
  String get name => 'android_private_chat';

  @override
  List<String> get dependsOn => const ['storage', 'accounts', 'models'];

  @override
  Future<void> configure(HostServices services) async {
    _chat = AndroidPrivateChat(
      services.get<Database>(),
      services.get<ColumnCipher>(),
      services.get<Clock>(),
    );
  }

  @override
  void mount(Router router) {
    router.get(Routes.androidPrivateChat, (request) => _handle(request));
    router.post(
      Routes.androidPrivateChat,
      (request) => _handle(request, write: true),
    );
  }

  static final _cursor = RegExp(r'^(0|[1-9][0-9]{0,18})$');

  Future<HostResponse> _handle(
    HostRequest request, {
    bool write = false,
  }) async {
    final principal = request.principal;
    final header = request.headers['authorization'] ?? '';
    final bearer = header.startsWith('Bearer ')
        ? header.substring(7).trim()
        : '';
    if (principal == null || bearer.isEmpty) {
      return HostResponse.failure(
        const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
      );
    }
    final AiId profile;
    try {
      profile = AiId.parse(request.pathParams['aiId'] ?? '');
    } on FormatException {
      return _invalid;
    }
    final claim = (
      owner: principal.accountId,
      device: principal.deviceId,
      bearer: bearer,
      profile: profile,
    );
    if (!write) {
      final length = request.headers['content-length'];
      if (request.body != null ||
          (length != null && int.tryParse(length) != 0) ||
          request.headers.containsKey('transfer-encoding') ||
          request.query.keys.any((key) => key != 'after')) {
        return _invalid;
      }
      final raw = request.query['after'] ?? '0';
      final after = _cursor.hasMatch(raw) ? int.tryParse(raw, radix: 10) : null;
      if (after == null || after < 0) return _invalid;
      final result = await _chat.list(claim, after);
      if (result case Err(:final failure)) return HostResponse.failure(failure);
      return HostResponse(
        200,
        json: result.value,
        headers: const {'cache-control': 'no-store'},
      );
    }

    final body = request.body;
    if (request.query.isNotEmpty ||
        body is! Map<String, Object?> ||
        body.length != 3) {
      return _invalid;
    }
    final exchangeId = body['exchangeId'];
    final user = body['user'];
    final assistant = body['assistant'];
    if (exchangeId is! String || user is! String || assistant is! String) {
      return _invalid;
    }
    return HostResponse.fromResult(
      await _chat.push(
        claim,
        exchangeId: exchangeId,
        user: user,
        assistant: assistant,
      ),
      (seq) => {'seq': seq},
    );
  }

  static final _invalid = HostResponse.failure(
    const Failure(
      FailureCode.invalidArgument,
      'Invalid private transcript input',
    ),
  );
}
