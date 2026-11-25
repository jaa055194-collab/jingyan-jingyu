import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/search_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

/// Transport double for the two failure modes a loopback server cannot produce
/// deterministically (connection refused / read timeout).
class _ThrowingConnection extends HostConnection {
  _ThrowingConnection(this.error) : super(Uri.parse('http://fixture.invalid'), 'x');

  final Object error;

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async => throw error;
}

void main() {
  late HttpServer server;
  late HostConnection connection;
  late SearchApi api;
  late List<(String, String, Map<String, List<String>>)> requests;
  Object? responseBody;
  late int status;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture',
    );
    api = SearchApi(connection);
    requests = [];
    responseBody = null;
    status = 200;
    server.listen((request) async {
      await request.drain<void>();
      requests.add((
        request.method,
        request.uri.path,
        request.uri.queryParametersAll,
      ));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      if (responseBody != null) {
        request.response.write(jsonEncode(responseBody));
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  Map<String, Object?> hit({
    String conversationId = 'conv-1',
    String messageId = 'msg-1',
    int seq = 12,
    String senderId = 'acc-2',
    String kind = 'text',
    Map<String, Object?> body = const {'text': '项目代号鲸落'},
    String sentAt = '2026-11-14T09:00:00.000Z',
    String mode = 'blind',
  }) => {
    'conversationId': conversationId,
    'messageId': messageId,
    'seq': seq,
    'senderId': senderId,
    'kind': kind,
    'body': body,
    'sentAt': sentAt,
    'mode': mode,
  };

  List<SearchHit> loaded(SearchOutcome outcome) {
    expect(outcome, isA<SearchLoaded>());
    return (outcome as SearchLoaded).hits;
  }

  test('builds the exact GET query and parses every hit field', () async {
    responseBody = {
      'hits': [
        hit(),
        hit(
          conversationId: 'conv-2',
          messageId: 'msg-2',
          seq: 3,
          senderId: 'acc-9',
          kind: 'image',
          body: const {'attachmentId': 'att-1'},
          sentAt: '2026-11-15T00:30:00.000Z',
          mode: 'scan',
        ),
      ],
    };
    final outcome = await api.searchMessages(
      '  鲸落  ',
      senderId: 'acc-2',
      kind: MessageKind.text,
      from: DateTime.utc(2026, 11, 1),
      to: DateTime.utc(2026, 11, 30, 23, 59),
      limit: 10,
    );
    final hits = loaded(outcome);
    expect(hits, hasLength(2));
    expect(hits.first.conversationId, 'conv-1');
    expect(hits.first.messageId, 'msg-1');
    expect(hits.first.seq, 12);
    expect(hits.first.senderId, 'acc-2');
    expect(hits.first.kind, MessageKind.text);
    expect(hits.first.body, {'text': '项目代号鲸落'});
    expect(hits.first.sentAt, DateTime.utc(2026, 11, 14, 9));
    expect(hits.first.sentAt.isUtc, isTrue);
    expect(hits.first.mode, SearchHitMode.blind);
    expect(hits.last.mode, SearchHitMode.scan);

    final (method, path, query) = requests.single;
    expect(method, 'GET');
    expect(path, Routes.search);
    // The trimmed query is what leaves the client; no local re-search happens.
    expect(query['q'], ['鲸落']);
    expect(query['type'], ['message']);
    expect(query['limit'], ['10']);
    expect(query['senderId'], ['acc-2']);
    expect(query['kind'], ['text']);
    expect(query['from'], [DateTime.utc(2026, 11, 1).toIso8601String()]);
    expect(query['to'], [DateTime.utc(2026, 11, 30, 23, 59).toIso8601String()]);
  });

  test('defaults to limit 50 and omits every optional filter', () async {
    responseBody = const {'hits': <Object?>[]};
    final hits = loaded(await api.searchMessages('x'));
    expect(hits, isEmpty);
    expect(requests.single.$3, {
      'q': ['x'],
      'type': ['message'],
      'limit': ['50'],
    });
  });

  test('empty hits is loaded, never an invented match or mode claim', () async {
    responseBody = const {'hits': <Object?>[]};
    final outcome = await api.searchMessages('nothing-matches');
    expect(outcome, isA<SearchLoaded>());
    expect((outcome as SearchLoaded).hits, isEmpty);
  });

  test('rejects invalid request parameters before any transport call', () async {
    for (final call in <Future<SearchOutcome> Function()>[
      () => api.searchMessages(''),
      () => api.searchMessages('   '),
      () => api.searchMessages('x' * 201),
      () => api.searchMessages('x', limit: 0),
      () => api.searchMessages('x', limit: 101),
      () => api.searchMessages('x', senderId: 'bad id!'),
      () => api.searchMessages('x', type: 'favorite'),
      () => api.searchMessages('x', type: 'file'),
    ]) {
      await expectLater(call(), throwsFormatException);
    }
    expect(requests, isEmpty);
  });

  test('maps 401 and 403 to unauthenticated, not to an empty result', () async {
    for (final code in [401, 403]) {
      status = code;
      responseBody = {
        'error': code == 401 ? 'unauthenticated' : 'forbidden',
      };
      expect(
        await api.searchMessages('x'),
        isA<SearchUnauthenticated>(),
        reason: '$code',
      );
    }
    expect(requests, hasLength(2));
  });

  test('maps server failures and transport errors to unavailable', () async {
    for (final code in [400, 429, 500, 503]) {
      status = code;
      responseBody = const {'error': 'internal'};
      expect(
        await api.searchMessages('x'),
        isA<SearchUnavailable>(),
        reason: '$code',
      );
    }
    expect(
      await SearchApi(
        _ThrowingConnection(const SocketException('refused')),
      ).searchMessages('x'),
      isA<SearchUnavailable>(),
    );
    expect(
      await SearchApi(
        _ThrowingConnection(TimeoutException('slow')),
      ).searchMessages('x'),
      isA<SearchUnavailable>(),
    );
    expect(
      await SearchApi(
        _ThrowingConnection(const HttpException('broken')),
      ).searchMessages('x'),
      isA<SearchUnavailable>(),
    );
  });

  test('malformed payloads are reported as malformed, never partially used', () async {
    final payloads = <Object?>[
      {'hits': <Object?>[], 'mode': 'blind'}, // unknown top-level key
      {'hits': 'nope'},
      {'hits': [hit(), 'nope']},
      {'hits': [{...hit(), 'score': 0.9}]}, // unknown hit key
      {'hits': [{...hit()}..remove('sentAt')]}, // missing field
      {'hits': [{...hit(), 'conversationId': 7}]}, // non-string id
      {'hits': [{...hit(), 'conversationId': 'bad id!'}]}, // malformed id
      {'hits': [{...hit(), 'messageId': ''}]},
      {'hits': [{...hit(), 'senderId': null}]},
      {'hits': [{...hit(), 'seq': '12'}]},
      {'hits': [{...hit(), 'seq': 0}]},
      {'hits': [{...hit(), 'kind': 'nope'}]},
      {'hits': [{...hit(), 'kind': 'TEXT'}]},
      {'hits': [{...hit(), 'body': 'text'}]},
      {'hits': [{...hit(), 'body': null}]},
      {'hits': [{...hit(), 'sentAt': 'not-a-date'}]},
      {'hits': [{...hit(), 'sentAt': '2026-11-14T09:00:00'}]}, // not UTC
      {'hits': [{...hit(), 'sentAt': 1700000000}]},
      {'hits': [{...hit(), 'mode': 'fuzzy'}]},
      {'hits': [{...hit(), 'mode': null}]},
      <Object?>[], // envelope is not an object
      'nope',
    ];
    for (final payload in payloads) {
      responseBody = payload;
      final outcome = await api.searchMessages('x');
      expect(outcome, isA<SearchMalformed>(), reason: '$payload');
      expect(outcome.toString(), isNot(contains('项目代号鲸落')));
    }
  });

  test('bounded inherited 401 renewal replays at most once', () async {
    var calls = 0;
    final renewServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    renewServer.listen((request) async {
      await request.drain<void>();
      calls++;
      request.response.statusCode = calls == 1 ? 401 : 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        calls == 1
            ? '{"error":"unauthenticated"}'
            : jsonEncode({
                'hits': [hit()],
              }),
      );
      await request.response.close();
    });
    var renewals = 0;
    final renewed = HostConnection(
      Uri.parse('http://127.0.0.1:${renewServer.port}'),
      'stale',
      onUnauthorized: () async {
        renewals++;
        return true;
      },
    );
    try {
      final hits = loaded(await SearchApi(renewed).searchMessages('x'));
      expect(hits.single.messageId, 'msg-1');
      expect(calls, 2);
      expect(renewals, 1);
    } finally {
      await renewed.close();
      await renewServer.close(force: true);
    }
  });

  test('a failed renewal is reported as unauthenticated, not retried', () async {
    var calls = 0;
    final renewServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    renewServer.listen((request) async {
      await request.drain<void>();
      calls++;
      request.response.statusCode = 401;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"error":"unauthenticated"}');
      await request.response.close();
    });
    var renewals = 0;
    final renewed = HostConnection(
      Uri.parse('http://127.0.0.1:${renewServer.port}'),
      'stale',
      onUnauthorized: () async {
        renewals++;
        return false;
      },
    );
    try {
      expect(
        await SearchApi(renewed).searchMessages('x'),
        isA<SearchUnauthenticated>(),
      );
      expect(calls, 1);
      expect(renewals, 1);
    } finally {
      await renewed.close();
      await renewServer.close(force: true);
    }
  });
}
