import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'owner_memory_notes.dart';

/// Owner-only note management. The bearer principal is checked again in the
/// same transaction as every read and mutation; no owner, AI account or tier
/// is accepted from the request body.
final class OwnerMemoryNotesModule extends HostModule {
  OwnerMemoryNotesModule(this.notes, this.authenticate);
  final OwnerMemoryNotes notes;
  final Authenticator authenticate;

  @override
  String get name => 'owner_memory_notes';

  @override
  List<String> get dependsOn => const ['storage', 'accounts'];

  HostResponse _invalid() => HostResponse.failure(
    const Failure(FailureCode.invalidArgument, 'Invalid memory note input'),
  );

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
    final noteId = request.pathParams['noteId'];
    if (kind == 'read' || kind == 'settingsRead') {
      final length = request.headers['content-length'];
      if (request.body != null ||
          (length != null && int.tryParse(length) != 0) ||
          request.headers.containsKey('transfer-encoding')) {
        return _invalid();
      }
      return _response(
        await notes.read(
          owner: owner,
          device: current.deviceId,
          bearer: bearer,
          ai: ai,
        ),
      );
    }
    final body = request.jsonObject().valueOrNull;
    if (body == null) return _invalid();
    if (kind == 'add') {
      if (body.length != 2 ||
          body['text'] is! String ||
          body['expectedRevision'] is! int) {
        return _invalid();
      }
      return _response(
        await notes.add(
          owner: owner,
          device: current.deviceId,
          bearer: bearer,
          ai: ai,
          text: body['text'] as String,
          expectedRevision: body['expectedRevision'] as int,
        ),
      );
    }
    if (kind == 'edit') {
      if (body.length != 2 ||
          noteId == null ||
          body['text'] is! String ||
          body['expectedRevision'] is! int) {
        return _invalid();
      }
      return _response(
        await notes.edit(
          owner: owner,
          device: current.deviceId,
          bearer: bearer,
          ai: ai,
          noteId: noteId,
          text: body['text'] as String,
          expectedRevision: body['expectedRevision'] as int,
        ),
      );
    }
    if (kind == 'delete') {
      if (body.length != 1 ||
          noteId == null ||
          body['expectedRevision'] is! int) {
        return _invalid();
      }
      return _response(
        await notes.delete(
          owner: owner,
          device: current.deviceId,
          bearer: bearer,
          ai: ai,
          noteId: noteId,
          expectedRevision: body['expectedRevision'] as int,
        ),
      );
    }
    if (kind == 'clear') {
      if (body.length != 1 || body['expectedRevision'] is! int) {
        return _invalid();
      }
      return _response(
        await notes.clear(
          owner: owner,
          device: current.deviceId,
          bearer: bearer,
          ai: ai,
          expectedRevision: body['expectedRevision'] as int,
        ),
      );
    }
    if (kind == 'settings') {
      if (body.length != 3 ||
          body['enabled'] is! bool ||
          body['expectedRevision'] is! int ||
          (body['expectedTargetToken'] != null &&
              (body['expectedTargetToken'] is! String ||
                  (body['expectedTargetToken'] as String).length > 128))) {
        return _invalid();
      }
      return _response(
        await notes.setEnabled(
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
    router.get(Routes.aiOwnerMemoryNotes, (r) => _handle(r, kind: 'read'));
    router.post(Routes.aiOwnerMemoryNotes, (r) => _handle(r, kind: 'add'));
    router.add(
      'PATCH',
      Routes.aiOwnerMemoryNote,
      (r) => _handle(r, kind: 'edit'),
    );
    router.delete(Routes.aiOwnerMemoryNote, (r) => _handle(r, kind: 'delete'));
    router.delete(Routes.aiOwnerMemoryNotes, (r) => _handle(r, kind: 'clear'));
    router.put(
      Routes.aiOwnerMemoryNoteSettings,
      (r) => _handle(r, kind: 'settings'),
    );
  }
}
