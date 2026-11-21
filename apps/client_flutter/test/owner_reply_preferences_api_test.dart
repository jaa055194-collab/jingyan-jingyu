import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/owner_reply_preferences_api.dart';
import 'package:flutter_test/flutter_test.dart';

const _path = '/api/v1/ai-profiles/profile-a/owner-reply-preferences';
const _target = <String, Object?>{
  'providerId': 'fixture-provider',
  'model': 'fixture-chat-model',
  'origin': 'https://provider.example.invalid:8443',
  'token': 'fixture-target-A',
};
Map<String, Object?> _reply({
  int revision = 0,
  bool enabled = false,
  String? length,
  String? format,
  Map<String, Object?>? target = _target,
}) => {
  'revision': revision,
  'enabled': enabled,
  'length': length,
  'format': format,
  'target': target,
};

void main() {
  late HttpServer server;
  late StreamSubscription<HttpRequest> subscription;
  late HostConnection connection;
  late OwnerReplyPreferencesApi api;
  late Object? payload;
  late int status;
  final requests = <(String method, String path, String body)>[];

  setUp(() async {
    requests.clear();
    payload = _reply();
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture-bearer',
      onUnauthorized: () async =>
          fail('a stale preference request must not replay authentication'),
    );
    api = OwnerReplyPreferencesApi(connection);
    subscription = server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      requests.add((request.method, request.uri.path, raw));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(payload));
      await request.response.close();
    });
  });
  tearDown(() async {
    await connection.close();
    await subscription.cancel();
    await server.close(force: true);
  });

  Future<OwnerReplyPreferences> read() async =>
      (await api.read('profile-a')).state!;

  test('default off is distinct from an unavailable read', () async {
    payload = _reply(target: null);
    final current = await read();
    expect(
      (
        current.revision,
        current.enabled,
        current.length,
        current.format,
        current.target,
      ),
      (0, false, null, null, null),
    );
    expect(requests.single, ('GET', _path, ''));
    status = 404;
    final denied = await api.read('profile-a');
    expect(denied.state, isNull);
    expect(denied.problem, OwnerReplyPreferenceProblem.refused);
    status = 503;
    expect(
      (await api.read('profile-a')).problem,
      OwnerReplyPreferenceProblem.unavailable,
    );
  });

  test(
    'malformed choices, extra fields and unsafe destination labels fail closed',
    () async {
      for (final invalid in <Map<String, Object?>>[
        {..._reply(), 'history': []},
        _reply()..remove('length'),
        {..._reply(), 'revision': -1},
        {..._reply(), 'revision': 1.0},
        {..._reply(), 'length': 'arbitrary text'},
        {..._reply(), 'format': true},
        _reply(enabled: true, length: 'brief', target: null),
        _reply(enabled: true),
        _reply(target: {..._target, 'apiKey': 'must not surface'}),
        _reply(
          target: {
            ..._target,
            'origin': 'https://user@provider.example.invalid',
          },
        ),
        _reply(
          target: {
            ..._target,
            'origin': 'https://provider.example.invalid/private?key=opaque',
          },
        ),
        _reply(target: {..._target, 'origin': 'file:///tmp/private'}),
        _reply(target: {..._target, 'model': 'unsafe\u202Elabel'}),
        _reply(target: {..._target, 'token': ''}),
      ]) {
        payload = invalid;
        final result = await api.read('profile-a');
        expect(result.problem, OwnerReplyPreferenceProblem.unavailable);
        expect(result.state, isNull);
      }
    },
  );

  test('writes bind to resolved profile, exact revision, choices and private offer token', () async {
    final current = await read();
    expect(current.target?.origin, _target['origin']);
    expect(current.target?.model, _target['model']);
    expect(current.target?.providerId, _target['providerId']);
    payload = _reply(
      revision: 1,
      enabled: true,
      length: 'brief',
      format: 'bullets',
    );
    final result = await api.save(
      'profile-a',
      current: current,
      enabled: true,
      length: OwnerReplyLength.brief,
      format: OwnerReplyFormat.bullets,
    );
    expect(result.state?.enabled, true);
    expect(requests.last.$1, 'PUT');
    expect(requests.last.$2, _path);
    expect(jsonDecode(requests.last.$3), {
      'expectedRevision': 0,
      'enabled': true,
      'length': 'brief',
      'format': 'bullets',
      'expectedTargetToken': 'fixture-target-A',
    });
    payload = _reply(revision: 2, target: null);
    expect(
      (await api.save(
        'profile-a',
        current: result.state!,
        enabled: false,
        length: null,
        format: null,
      )).state?.enabled,
      false,
    );
    expect(jsonDecode(requests.last.$3), {
      'expectedRevision': 1,
      'enabled': false,
      'length': null,
      'format': null,
      'expectedTargetToken': null,
    });
    expect(requests.length, 3);
  });

  test(
    'missing target, empty opt-in or another profile is refused without PUT',
    () async {
      payload = _reply(target: null);
      final noTarget = await read();
      expect(
        (await api.save(
          'profile-a',
          current: noTarget,
          enabled: true,
          length: OwnerReplyLength.brief,
          format: null,
        )).problem,
        OwnerReplyPreferenceProblem.refused,
      );
      payload = _reply();
      final current = await read();
      expect(
        (await api.save(
          'profile-a',
          current: current,
          enabled: true,
          length: null,
          format: null,
        )).problem,
        OwnerReplyPreferenceProblem.refused,
      );
      expect(
        (await api.save(
          'profile-b',
          current: current,
          enabled: false,
          length: null,
          format: null,
        )).problem,
        OwnerReplyPreferenceProblem.refused,
      );
      expect(requests.map((r) => r.$1), ['GET', 'GET']);
    },
  );

  test('wrong response revision, options, or target is unknown rather than success', () async {
    final current = await read();
    for (final wrong in [
      _reply(enabled: true, length: 'brief'),
      _reply(revision: 2, enabled: true, length: 'brief'),
      _reply(revision: 1, enabled: false, length: 'brief'),
      _reply(revision: 1, enabled: true, length: 'detailed'),
      _reply(
        revision: 1,
        enabled: true,
        length: 'brief',
        target: {..._target, 'model': 'other-model'},
      ),
      _reply(
        revision: 1,
        enabled: true,
        length: 'brief',
        target: {..._target, 'token': 'fixture-target-B'},
      ),
      _reply(
        revision: 1,
        enabled: true,
        length: 'brief',
        target: {..._target, 'origin': 'https://changed.example.invalid'},
      ),
    ]) {
      payload = wrong;
      expect(
        (await api.save(
          'profile-a',
          current: current,
          enabled: true,
          length: OwnerReplyLength.brief,
          format: null,
        )).problem,
        OwnerReplyPreferenceProblem.unknown,
      );
    }
    expect(requests.where((r) => r.$1 == 'PUT').length, 7);
  });

  test(
    'refusal, conflict, and unknown writes are distinct and never replay',
    () async {
      final current = await read();
      payload = {'error': 'opaque fixture detail'};
      for (final (code, problem) in [
        (400, OwnerReplyPreferenceProblem.refused),
        (401, OwnerReplyPreferenceProblem.refused),
        (403, OwnerReplyPreferenceProblem.refused),
        (404, OwnerReplyPreferenceProblem.refused),
        (409, OwnerReplyPreferenceProblem.conflict),
        (500, OwnerReplyPreferenceProblem.unknown),
      ]) {
        status = code;
        final result = await api.save(
          'profile-a',
          current: current,
          enabled: false,
          length: OwnerReplyLength.brief,
          format: null,
        );
        expect(result.problem, problem);
        expect(result.state, isNull);
      }
      expect(requests.length, 7);
    },
  );
}
