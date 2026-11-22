import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/owner_memory_notes_api.dart';
import 'package:flutter_test/flutter_test.dart';

const _profile = 'profile-a';
const _base = '/api/v1/ai-profiles/profile-a/owner-memory-notes';
const _settings = '$_base/settings';
const _target = {
  'providerId': 'fixture-provider',
  'model': 'fixture-model',
  'origin': 'https://provider.example.invalid:8443',
  'token': 'target-token-A',
};
const _created = '2026-01-01T09:00:00.000Z';

Map<String, Object?> note({
  String id = 'note-a',
  String text = '喜欢桂花',
  String createdAt = _created,
  String updatedAt = _created,
}) => {'id': id, 'text': text, 'createdAt': createdAt, 'updatedAt': updatedAt};

Map<String, Object?> state({
  int revision = 0,
  bool enabled = false,
  int maxNotes = 20,
  int maxNoteBytes = 512,
  List<Map<String, Object?>>? notes,
  Map<String, Object?>? target = _target,
}) => {
  'revision': revision,
  'enabled': enabled,
  'maxNotes': maxNotes,
  'maxNoteBytes': maxNoteBytes,
  'notes': notes ?? <Map<String, Object?>>[],
  'target': target,
};

void main() {
  late HttpServer server;
  late HostConnection connection;
  late OwnerMemoryNotesApi api;
  late Object? response;
  late int status;
  late int authRenewals;
  final requests = <(String method, String path, String raw)>[];
  setUp(() async {
    response = state();
    status = 200;
    authRenewals = 0;
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add((
        request.method,
        request.uri.toString(),
        await utf8.decoder.bind(request).join(),
      ));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'synthetic',
      onUnauthorized: () async {
        authRenewals++;
        return true;
      },
    );
    api = OwnerMemoryNotesApi(connection);
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  test('default read is an explicit strict GET', () async {
    final result = await api.read(_profile);
    final loaded = result.state!;
    expect(result.problem, isNull);
    expect(
      (
        loaded.revision,
        loaded.enabled,
        loaded.maxNotes,
        loaded.maxNoteBytes,
        loaded.notes.length,
      ),
      (0, false, 20, 512, 0),
    );
    expect(loaded.target, isNotNull);
    expect(requests.single, ('GET', _base, ''));
    expect(authRenewals, 0);
  });

  test('add sends trimmed plain text and exact revision', () async {
    final current = (await api.read(_profile)).state!;
    response = state(revision: 1, notes: [note(text: '喜欢桂花')]);
    final result = await api.add(_profile, current: current, text: '  喜欢桂花  ');
    expect(result.problem, isNull);
    expect(result.state!.revision, 1);
    expect(requests.last, (
      'POST',
      _base,
      jsonEncode({'text': '喜欢桂花', 'expectedRevision': 0}),
    ));
    expect(requests, hasLength(2));
  });

  test('edit, delete, and clear use exact paths and bodies', () async {
    final initial = (await api.read(_profile)).state!;
    response = state(revision: 1, notes: [note()]);
    final afterAdd = (await api.add(
      _profile,
      current: initial,
      text: '喜欢桂花',
    )).state!;
    response = state(revision: 2, notes: [note(text: '喜欢白色')]);
    final afterEdit = await api.edit(
      _profile,
      current: afterAdd,
      noteId: 'note-a',
      text: '喜欢白色',
    );
    expect(afterEdit.problem, isNull);
    expect(requests.last, (
      'PATCH',
      '$_base/note-a',
      jsonEncode({'text': '喜欢白色', 'expectedRevision': 1}),
    ));
    response = state(revision: 3);
    final afterDelete = await api.delete(
      _profile,
      current: afterEdit.state!,
      noteId: 'note-a',
    );
    expect(afterDelete.problem, isNull);
    expect(requests.last, (
      'DELETE',
      '$_base/note-a',
      jsonEncode({'expectedRevision': 2}),
    ));
    response = state(revision: 4, notes: [note(text: '另一条')]);
    final beforeClear = (await api.read(_profile)).state!;
    response = state(revision: 5);
    final cleared = await api.clear(_profile, current: beforeClear);
    expect(cleared.problem, isNull);
    expect(cleared.state!.notes, isEmpty);
    expect(requests.last, (
      'DELETE',
      _base,
      jsonEncode({'expectedRevision': 4}),
    ));
  });

  test(
    'separate use permission uses exact settings PUT and target token',
    () async {
      final current = (await api.read(_profile)).state!;
      response = state(revision: 1, enabled: true);
      final enabled = await api.setEnabled(
        _profile,
        current: current,
        enabled: true,
      );
      expect(enabled.problem, isNull);
      expect(enabled.state!.enabled, isTrue);
      expect(requests.last, (
        'PUT',
        _settings,
        jsonEncode({
          'expectedRevision': 0,
          'enabled': true,
          'expectedTargetToken': 'target-token-A',
        }),
      ));
      response = state(revision: 2, enabled: false);
      final disabled = await api.setEnabled(
        _profile,
        current: enabled.state!,
        enabled: false,
      );
      expect(disabled.problem, isNull);
      expect(requests.last, (
        'PUT',
        _settings,
        jsonEncode({
          'expectedRevision': 1,
          'enabled': false,
          'expectedTargetToken': null,
        }),
      ));
    },
  );

  test(
    'enable requires a current target and disable preserves notes',
    () async {
      final noTarget = (await api.read(_profile)).state!;
      response = state(target: null);
      final emptyTarget = (await api.read(_profile)).state!;
      expect(
        await api.setEnabled(_profile, current: emptyTarget, enabled: true),
        const OwnerMemoryResult.failed(OwnerMemoryProblem.refused),
      );
      expect(requests, hasLength(2));
      expect(noTarget.target, isNotNull);
      response = state(revision: 1, enabled: true, notes: [note()]);
      final enabledWithTarget = (await api.read(_profile)).state!;
      response = state(
        revision: 2,
        enabled: false,
        notes: [note()],
        target: null,
      );
      final disabled = await api.setEnabled(
        _profile,
        current: enabledWithTarget,
        enabled: false,
      );
      expect(disabled.problem, isNull);
      expect(disabled.state!.notes.single.text, '喜欢桂花');
    },
  );

  test('strict text validation rejects empty, oversized, control and extra fields before host', () async {
    final current = (await api.read(_profile)).state!;
    for (final text in [' \t\n', 'x\ny', '\u0001bad', '花' * 171, 'a' * 513]) {
      final result = await api.add(_profile, current: current, text: text);
      expect(result.problem, OwnerMemoryProblem.refused, reason: text);
    }
    expect(requests, hasLength(1));
  });

  test('note limit is locally bounded', () async {
    final current = (await api.read(_profile)).state!;
    final full = OwnerMemoryNotes(
      profileId: _profile,
      revision: 1,
      enabled: false,
      maxNotes: 20,
      maxNoteBytes: 512,
      notes: [
        for (var i = 0; i < 20; i++)
          OwnerMemoryNote(
            id: 'id-$i',
            text: 'n',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
      ],
      target: null,
    );
    expect(
      await api.add(_profile, current: full, text: 'extra'),
      const OwnerMemoryResult.failed(OwnerMemoryProblem.refused),
    );
    expect(requests, hasLength(1));
    expect(current.maxNotes, 20);
  });

  test('malformed, wrong-revision, and ambiguous mutations are distinct and never replayed', () async {
    final current = (await api.read(_profile)).state!;
    for (final (code, problem) in [
      (400, OwnerMemoryProblem.refused),
      (401, OwnerMemoryProblem.refused),
      (404, OwnerMemoryProblem.refused),
      (409, OwnerMemoryProblem.conflict),
      (500, OwnerMemoryProblem.unknown),
    ]) {
      status = code;
      response = {'error': 'private fixture error'};
      final result = await api.add(
        _profile,
        current: current,
        text: 'synthetic',
      );
      expect(result.problem, problem);
    }
    expect(requests.where((request) => request.$1 == 'POST'), hasLength(5));
    expect(authRenewals, 0);
  });

  test('strict state decode rejects malformed notes, limits, target, and timestamps', () async {
    for (final bad in [
      state(notes: [note(id: '../bad')]),
      state(notes: [note(createdAt: '2026-02-30T09:00:00.000Z')]),
      state(notes: [note(text: 'x\ny')]),
      state(notes: [note(text: 'x' * 513)]),
      state(notes: [note(), note()]),
      state(maxNotes: 0),
      state(maxNoteBytes: 0),
      state(enabled: true, target: null),
      state(target: {'providerId': 'p'}),
      {...state(), 'extra': true},
    ]) {
      response = bad;
      expect(await api.read(_profile), isA<OwnerMemoryResult>());
      expect(
        (await api.read(_profile)).problem,
        OwnerMemoryProblem.unavailable,
      );
    }
    expect(requests, hasLength(20));
  });

  test('success receipts must advance one revision and reflect the requested change', () async {
    final current = (await api.read(_profile)).state!;
    for (final bad in [
      state(revision: 0, notes: [note()]),
      state(revision: 2, notes: [note()]),
      state(revision: 1, notes: []),
      state(revision: 1, notes: [note(text: 'different')]),
      state(revision: 1, enabled: true, notes: [note()]),
    ]) {
      response = bad;
      final result = await api.add(_profile, current: current, text: '喜欢桂花');
      expect(result.problem, OwnerMemoryProblem.unknown);
    }
  });
}
