import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/persona_history_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';

const _path = '/api/v1/ai-profiles/fixture-profile/persona/history';

Map<String, Object?> _change(int version) {
  const layers = {
    'p0': {'identity': 'opaque-owner-persona'},
    'p1': {'style': 'opaque-previous-style'},
    'p2': {'mood': 'opaque-previous-mood'},
  };
  return {
    'id': 'opaque-change-reference',
    'version': version,
    'kind': 'edit',
    'actorAccountId': 'opaque-actor',
    'before': layers,
    'after': layers,
    'diff': {
      'p0': <String, String?>{},
      'p1': {
        'opaque-field-name': 'opaque-field-value',
        'opaque-deletion': null,
      },
      'p2': <String, String?>{},
    },
    'reason': 'opaque-reason',
    'evidenceIds': ['opaque-evidence'],
    'at': '2026-02-04T10:30:00.000Z',
    'lockedBefore': false,
    'lockedAfter': false,
    'revertsChangeId': null,
  };
}

void main() {
  late HttpServer server;
  late HostConnection connection;
  late PersonaHistoryApi api;
  late List<(String, Uri)> calls;
  late Future<void> Function(HttpRequest request) respond;
  late int renewals;

  setUp(() async {
    calls = [];
    renewals = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture',
      onUnauthorized: () async {
        renewals++;
        return true;
      },
    );
    api = PersonaHistoryApi(connection);
    server.listen((request) async {
      calls.add((request.method, request.uri));
      await respond(request);
    });
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  Future<void> json(
    HttpRequest request,
    Object body, [
    int status = 200,
  ]) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<PersonaHistoryPage> read({
    int after = 0,
    HostReadCancellation? cancellation,
  }) => api.read(
    'fixture-profile',
    afterVersion: after,
    cancellation: cancellation ?? HostReadCancellation(),
  );

  test(
    'one loopback GET encodes pagination and projects only safe metadata',
    () async {
      respond = (r) => json(r, {
        'changes': [for (var i = 8; i <= 27; i++) _change(i)],
        'nextAfterVersion': 27,
      });
      final page = await read(after: 7);
      expect(calls, [('GET', Uri.parse('$_path?afterVersion=7&limit=20'))]);
      expect(page.nextAfterVersion, 27);
      expect(
        page.entries.map((entry) => entry.version),
        List.generate(20, (i) => i + 8),
      );
      final first = page.entries.first;
      expect(first.kind, PersonaHistoryKind.edit);
      expect(first.at, DateTime.utc(2026, 2, 4, 10, 30));
      expect(first.lockedBefore, false);
      expect(first.lockedAfter, false);
      expect(first.changedFields, {'p0': 0, 'p1': 2, 'p2': 0});
      expect(first.toString(), isNot(contains('opaque')));
      expect(page.toString(), isNot(contains('opaque')));
      expect(() => first.changedFields['p0'] = 1, throwsUnsupportedError);
      expect(() => page.entries.clear(), throwsUnsupportedError);
    },
  );

  test(
    'bounded query GET URL-encodes keys and values without changing the path',
    () async {
      respond = (r) => json(r, <String, Object>{});
      await connection.getBoundedJsonWithQuery(
        _path,
        query: {'afterVersion': '9&limit=100', 'note key': 'a+b#中'},
        maxResponseBytes: 64,
      );
      expect(calls, hasLength(1));
      expect(calls.single.$1, 'GET');
      final uri = calls.single.$2;
      expect(uri.path, _path);
      expect(uri.queryParameters, {
        'afterVersion': '9&limit=100',
        'note key': 'a+b#中',
      });
      expect(uri.fragment, isEmpty);
    },
  );

  test('invalid owned profile or negative cursor cannot dispatch', () async {
    respond = (r) => json(r, <String, Object>{});
    await expectLater(
      api.read('bad/id', afterVersion: 0, cancellation: HostReadCancellation()),
      throwsFormatException,
    );
    await expectLater(read(after: -1), throwsFormatException);
    expect(calls, isEmpty);
  });

  test('empty final page and shape errors do not invent history', () async {
    respond = (r) => json(r, {'changes': [], 'nextAfterVersion': null});
    final page = await read(after: 9);
    expect(page.entries, isEmpty);
    expect(page.nextAfterVersion, isNull);
    for (final payload in [
      {'changes': [], 'nextAfterVersion': 10},
      {
        'changes': [_change(10), _change(10)],
        'nextAfterVersion': null,
      },
      {
        'changes': [_change(10), _change(9)],
        'nextAfterVersion': null,
      },
      {
        'changes': [_change(8)],
        'nextAfterVersion': null,
      },
      {
        'changes': [_change(10)],
        'nextAfterVersion': 10,
      },
      {
        'changes': [for (var i = 10; i < 31; i++) _change(i)],
        'nextAfterVersion': null,
      },
      {
        'changes': [for (var i = 10; i < 30; i++) _change(i)],
        'nextAfterVersion': 30,
      },
      {
        'changes': [
          {..._change(10), 'kind': 'opaque-category'},
        ],
        'nextAfterVersion': null,
      },
      {
        'changes': [
          {..._change(10), 'at': '2026-02-31T10:30:00.000Z'},
        ],
        'nextAfterVersion': null,
      },
      {
        'changes': [
          {
            ..._change(10),
            'diff': {
              'p0': {},
              'p1': {'bad': 3},
              'p2': {},
            },
          },
        ],
        'nextAfterVersion': null,
      },
      {
        'changes': [
          {..._change(10), 'lockedAfter': 'false'},
        ],
        'nextAfterVersion': null,
      },
      {
        'changes': [
          {
            ..._change(10),
            'before': {'p0': {}, 'p1': {}, 'p2': {}},
          },
        ],
        'nextAfterVersion': null,
      },
      {'changes': [], 'nextAfterVersion': null, 'opaque-unexpected': true},
    ]) {
      respond = (r) => json(r, payload);
      await expectLater(
        read(after: 9),
        throwsA(
          isA<FormatException>().having((e) => e.source, 'source', isNull),
        ),
      );
    }
  });

  test(
    '401 never renews/replays a read and 404 remains a not-found reply',
    () async {
      for (final (status, wire, code) in [
        (401, 'unauthenticated', FailureCode.unauthenticated),
        (404, 'not_found', FailureCode.notFound),
      ]) {
        respond = (r) => json(r, {'error': wire}, status);
        await expectLater(
          read(),
          throwsA(
            isA<HostRequestException>().having(
              (e) => e.failure.code,
              'code',
              code,
            ),
          ),
        );
      }
      expect(calls, hasLength(2));
      expect(renewals, 0);
    },
  );

  test(
    'history rejects over-cap chunked bytes before the response completes',
    () async {
      final release = Completer<void>();
      respond = (r) async {
        r.response.bufferOutput = false;
        r.response.headers.chunkedTransferEncoding = true;
        r.response.add(List<int>.filled(2 * 1024 * 1024 + 1, 32));
        try {
          await r.response.flush();
          await release.future;
          await r.response.close();
        } on HttpException {
          // The client may have closed the response stream.
        }
      };
      try {
        await expectLater(
          read().timeout(const Duration(seconds: 5)),
          throwsFormatException,
        );
        expect(calls, hasLength(1));
      } finally {
        release.complete();
      }
    },
  );

  test(
    'cancels history during a pending body without closing the host session',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      respond = (r) async {
        r.response.bufferOutput = false;
        r.response.headers.chunkedTransferEncoding = true;
        try {
          r.response.write('{');
          await r.response.flush();
          started.complete();
          await release.future;
          await r.response.close();
        } on HttpException {
          // The client may have closed the response stream.
        }
      };
      final token = HostReadCancellation();
      final rejected = expectLater(
        read(cancellation: token).timeout(const Duration(seconds: 5)),
        throwsA(isA<HttpException>()),
      );
      try {
        await started.future.timeout(const Duration(seconds: 5));
        token.cancel();
        await rejected;
      } finally {
        release.complete();
      }
      respond = (r) => json(r, {'changes': [], 'nextAfterVersion': null});
      expect((await read()).entries, isEmpty);
      expect(calls, hasLength(2));
    },
  );
}
