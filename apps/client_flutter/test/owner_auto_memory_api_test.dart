import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/owner_auto_memory_api.dart';
import 'package:flutter_test/flutter_test.dart';

const _profile = 'profile-a';
const _base = '/api/v1/ai-profiles/profile-a/owner-auto-memory';
const _settings = '$_base/settings';
const _target = {
  'providerId': 'fixture-provider',
  'model': 'fixture-model',
  'origin': 'https://provider.example.invalid:8443',
  'token': 'target-token-A',
};
const _created = '2026-01-01T09:00:00.000Z';

Map<String, Object?> entry({
  String id = 'mem-a',
  String text = '记住我喜欢桂花',
  String tier = 't0',
  String status = 'active',
  String createdAt = _created,
}) => {
  'id': id,
  'text': text,
  'tier': tier,
  'status': status,
  'createdAt': createdAt,
};

Map<String, Object?> settingsState({
  int revision = 0,
  bool enabled = false,
  Map<String, Object?>? target = _target,
}) => {'revision': revision, 'enabled': enabled, 'target': target};

Map<String, Object?> listState({
  int revision = 0,
  int maxEntries = 50,
  List<Map<String, Object?>>? entries,
}) => {
  'revision': revision,
  'maxEntries': maxEntries,
  'entries': entries ?? <Map<String, Object?>>[],
};

void main() {
  late HttpServer server;
  late HostConnection connection;
  late OwnerAutoMemoryApi api;
  late Object? response;
  late int status;
  late int authRenewals;
  final requests = <(String method, String path, String raw)>[];
  setUp(() async {
    response = settingsState();
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
    api = OwnerAutoMemoryApi(connection);
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  test('settings and entries use explicit strict GETs', () async {
    final settings = await api.readSettings(_profile);
    expect(settings.state!.revision, 0);
    expect(settings.state!.enabled, false);
    expect(settings.state!.target, isNotNull);
    expect(requests.single, ('GET', _settings, ''));

    response = listState();
    final entries = await api.readEntries(_profile);
    expect(entries.state!.entries, isEmpty);
    expect(entries.state!.maxEntries, 50);
    expect(requests.last, ('GET', _base, ''));
    expect(requests, hasLength(2));
    expect(authRenewals, 0);
  });

  test('enable sends exact settings PUT and target token', () async {
    final current = (await api.readSettings(_profile)).state!;
    response = settingsState(revision: 1, enabled: true);
    final enabled = await api.setEnabled(
      _profile,
      current: current,
      enabled: true,
    );
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
    response = settingsState(revision: 2, enabled: false);
    final disabled = await api.setEnabled(
      _profile,
      current: enabled.state!,
      enabled: false,
    );
    expect(disabled.state!.enabled, isFalse);
    expect(requests.last, (
      'PUT',
      _settings,
      jsonEncode({
        'expectedRevision': 1,
        'enabled': false,
        'expectedTargetToken': null,
      }),
    ));
  });

  test('delete and clear use exact paths and bodies', () async {
    response = listState(revision: 0, entries: [
      entry(),
      entry(id: 'mem-b', text: '我最近睡得很晚', tier: 't1', status: 'pending'),
    ]);
    final current = (await api.readEntries(_profile)).state!;
    response = listState(revision: 1, entries: [
      entry(id: 'mem-b', text: '我最近睡得很晚', tier: 't1', status: 'pending'),
    ]);
    final deleted = await api.deleteEntry(
      _profile,
      current: current,
      memoryId: 'mem-a',
    );
    expect(deleted.state!.entries.single.id, 'mem-b');
    expect(requests.last, (
      'DELETE',
      '$_base/mem-a',
      jsonEncode({'expectedRevision': 0}),
    ));
    response = listState(revision: 2);
    final cleared = await api.clear(_profile, current: deleted.state!);
    expect(cleared.state!.entries, isEmpty);
    expect(requests.last, (
      'DELETE',
      _base,
      jsonEncode({'expectedRevision': 1}),
    ));
  });

  test('enable requires a current target and disable keeps entries', () async {
    response = settingsState(target: null);
    final emptyTarget = (await api.readSettings(_profile)).state!;
    expect(
      await api.setEnabled(_profile, current: emptyTarget, enabled: true),
      isA<OwnerAutoMemoryResult<OwnerAutoMemorySettings>>(),
    );
    expect(
      (await api.setEnabled(_profile, current: emptyTarget, enabled: true))
          .problem,
      OwnerAutoMemoryProblem.refused,
    );
    expect(requests, hasLength(2));
  });

  test('malformed and wrong-status mutations map to distinct problems', () async {
    final current = (await api.readSettings(_profile)).state!;
    for (final (code, problem) in [
      (400, OwnerAutoMemoryProblem.refused),
      (401, OwnerAutoMemoryProblem.refused),
      (404, OwnerAutoMemoryProblem.refused),
      (409, OwnerAutoMemoryProblem.conflict),
      (500, OwnerAutoMemoryProblem.unknown),
    ]) {
      status = code;
      response = {'error': 'private fixture error'};
      final result = await api.setEnabled(
        _profile,
        current: current,
        enabled: true,
      );
      expect(result.problem, problem);
    }
    expect(requests.where((r) => r.$1 == 'PUT'), hasLength(5));
    expect(authRenewals, 0);
  });

  test('strict decode rejects malformed settings, entries and timestamps', () async {
    for (final bad in [
      settingsState(revision: -1),
      settingsState(enabled: true, target: null),
      settingsState(target: {'providerId': 'p'}),
      {...settingsState(), 'extra': true},
    ]) {
      response = bad;
      expect(
        (await api.readSettings(_profile)).problem,
        OwnerAutoMemoryProblem.unavailable,
      );
    }
    expect(requests, hasLength(4));

    for (final bad in [
      listState(entries: [entry(id: '../bad')]),
      listState(entries: [entry(text: 'x\ny')]),
      listState(entries: [entry(tier: 't2')]),
      listState(entries: [entry(status: 'deleted')]),
      listState(entries: [entry(), entry()]),
      listState(maxEntries: 0),
      {...listState(), 'extra': true},
    ]) {
      response = bad;
      expect(
        (await api.readEntries(_profile)).problem,
        OwnerAutoMemoryProblem.unavailable,
      );
    }
  });

  test('success receipts must advance one revision', () async {
    final current = (await api.readSettings(_profile)).state!;
    for (final bad in [
      settingsState(revision: 0, enabled: true),
      settingsState(revision: 2, enabled: true),
    ]) {
      response = bad;
      final result = await api.setEnabled(
        _profile,
        current: current,
        enabled: true,
      );
      expect(result.problem, OwnerAutoMemoryProblem.unknown);
    }
  });
}
