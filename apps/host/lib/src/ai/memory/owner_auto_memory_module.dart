import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'owner_auto_memory.dart';

/// Owner-only auto chat-history memory management. The bearer principal is
/// checked again in the same transaction as every read and mutation; no owner,
/// AI account, tier or entry is accepted from the request body.
final class OwnerAutoMemoryModule extends HostModule {
  OwnerAutoMemoryModule(this.autoMemory, this.authenticate);
  final OwnerAutoMemory autoMemory;
  final Authenticator authenticate;

  /// Bounded opaque token shape. Exact equality with the host-issued token is
  /// still enforced inside the service transaction, never here.
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  @override
  String get name => 'owner_auto_memory';

  @override
  List<String> get dependsOn => const ['storage', 'accounts'];

  HostResponse _invalid() => HostResponse.failure(
    const Failure(FailureCode.invalidArgument, 'Invalid auto memory input'),
  );

  static bool _validRevision(Object? value) => value is int && value >= 0;

  static bool _validTargetToken(Object? value) =>
      value == null || (value is String && _tokenPattern.hasMatch(value));

  Future<HostResponse> _handle(
    HostRequest request, {
    required String kind,
  }) async {
    final current = await authenticate(request);
    final header = request.headers['authorization'];
    final bearer = header != null && header.startsWith('Bearer ')
        ? header.substring(7).trim()
        : '';
    if (current == null ||
        bearer.isEmpty ||
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
    if (kind == 'settingsRead' || kind == 'list') {
      final length = request.headers['content-length'];
      if (request.body != null ||
          (length != null && int.tryParse(length) != 0) ||
          request.headers.containsKey('transfer-encoding')) {
        return _invalid();
      }
      return _response(
        kind == 'settingsRead'
            ? await autoMemory.readSettings(
                owner: owner,
                device: current.deviceId,
                bearer: bearer,
                ai: ai,
              )
            : await autoMemory.listEntries(
                owner: owner,
                device: current.deviceId,
                bearer: bearer,
                ai: ai,
              ),
      );
    }
    final body = request.jsonObject().valueOrNull;
    if (body == null) return _invalid();
    if (kind == 'settingsWrite') {
      if (body.length != 3 ||
          body['enabled'] is! bool ||
          !_validRevision(body['expectedRevision']) ||
          !_validTargetToken(body['expectedTargetToken'])) {
        return _invalid();
      }
      return _response(
        await autoMemory.setEnabled(
          owner: owner,
          device: current.deviceId,
          bearer: bearer,
          ai: ai,
          expectedRevision: body['expectedRevision'] as int,
          enabled: body['enabled'] as bool,
          expectedTargetToken: body['expectedTargetToken'] as String?,
        ),
      );
    }
    if (kind == 'delete') {
      final memoryId = request.pathParams['memoryId'];
      if (body.length != 1 ||
          memoryId == null ||
          !_validRevision(body['expectedRevision'])) {
        return _invalid();
      }
      return _response(
        await autoMemory.deleteEntry(
          owner: owner,
          device: current.deviceId,
          bearer: bearer,
          ai: ai,
          memoryId: memoryId,
          expectedRevision: body['expectedRevision'] as int,
        ),
      );
    }
    if (kind == 'clear') {
      if (body.length != 1 || !_validRevision(body['expectedRevision'])) {
        return _invalid();
      }
      return _response(
        await autoMemory.clearEntries(
          owner: owner,
          device: current.deviceId,
          bearer: bearer,
          ai: ai,
          expectedRevision: body['expectedRevision'] as int,
        ),
      );
    }
    return _invalid();
  }

  HostResponse _response(Result<Map<String, Object?>> result) => result.isOk
      ? HostResponse(
          200,
          json: result.value,
          headers: const {'Cache-Control': 'no-store'},
        )
      : HostResponse.failure(result.failureOrNull!);

  @override
  void mount(Router router) {
    router.get(
      Routes.aiOwnerAutoMemorySettings,
      (r) => _handle(r, kind: 'settingsRead'),
    );
    router.put(
      Routes.aiOwnerAutoMemorySettings,
      (r) => _handle(r, kind: 'settingsWrite'),
    );
    router.get(Routes.aiOwnerAutoMemory, (r) => _handle(r, kind: 'list'));
    router.delete(
      Routes.aiOwnerAutoMemoryEntry,
      (r) => _handle(r, kind: 'delete'),
    );
    router.delete(
      Routes.aiOwnerAutoMemory,
      (r) => _handle(r, kind: 'clear'),
    );
  }
}
