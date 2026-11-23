import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/android_private_chat_sync_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';

const _profile = 'reef-ai';
const _path = '/api/v1/ai-profiles/reef-ai/android-private-chat';
const _bearer = 'Bearer synthetic-owner-token';
const _exchange = {
  'exchangeId': 'exchange_test',
  'user': '  A message\n',
  'assistant': 'A reply 🐋',
};
const _happyRow = {'seq': 4, ..._exchange};

void main() {
  late AndroidPrivateChatSyncApi api;
  late String responseBody;
  late int responseStatus;
  late int renewals;
  final calls = <({String method, String path, String body, String? auth})>[];

  setUp(() async {
    calls.clear();
    responseBody = '';
    responseStatus = 200;
    renewals = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      calls.add((
        method: request.method,
        path: request.uri.toString(),
        body: await utf8.decoder.bind(request).join(),
        auth: request.headers.value(HttpHeaders.authorizationHeader),
      ));
      request.response.statusCode = responseStatus;
      request.response.headers.set(HttpHeaders.locationHeader, '/redirect');
      request.response.headers.contentType = ContentType.json;
      request.response.write(responseBody);
      await request.response.close();
    });
    final connection = HttpOverrides.runWithHttpOverrides(
      () => HostConnection(
        Uri.parse('http://127.0.0.1:${server.port}'),
        'synthetic-owner-token',
        onUnauthorized: () async {
          renewals++;
          return true;
        },
      ),
      _LoopbackHttp(server.port),
    );
    addTearDown(connection.close);
    api = AndroidPrivateChatSyncApi(connection);
  });

  test(
    'list sends only the cursor and reads private transcript item records',
    () async {
      responseBody = jsonEncode({
        'items': [_happyRow],
        'hasMore': true,
      });
      final page = await api.list(_profile, 3);
      expect(page.items, [
        (
          seq: 4,
          exchangeId: 'exchange_test',
          user: '  A message\n',
          assistant: 'A reply 🐋',
        ),
      ]);
      expect(page.hasMore, isTrue);
      expect(calls.single, (
        method: 'GET',
        path: '$_path?after=3',
        body: '',
        auth: _bearer,
      ));
    },
  );

  test(
    'push sends only the exchange envelope and returns the exact receipt',
    () async {
      responseBody = '{"seq":9}';
      expect(
        await api.push(
          _profile,
          exchangeId: 'exchange_test',
          user: '  A message\n',
          assistant: 'A reply 🐋',
        ),
        9,
      );
      final call = calls.single;
      expect([call.method, call.path, call.auth], ['POST', _path, _bearer]);
      expect(jsonDecode(call.body), _exchange);
    },
  );

  test('invalid input never sends an HTTP request', () async {
    await expectLater(api.list('profile/other', 0), throwsFormatException);
    await expectLater(api.list(_profile, -1), throwsFormatException);
    for (final (id, user, reply) in [
      ('exchange/other', 'ok', 'ok'),
      ('id', '  \t\n', 'ok'),
      ('id', 'ok', ''),
      ('id', '中' * 1366, 'ok'),
      ('id', 'ok', '🦀' * 2049),
      ('id', String.fromCharCode(0xd800), 'ok'),
    ]) {
      await expectLater(
        api.push(_profile, exchangeId: id, user: user, assistant: reply),
        throwsFormatException,
      );
    }
    expect(calls, isEmpty);
  });

  test('list rejects malformed page envelopes, items and cursors', () async {
    for (final body in <Object?>[
      [],
      {
        'items': [_happyRow],
      },
      {'items': [], 'hasMore': true},
      {
        'items': [_happyRow],
        'hasMore': 'false',
      },
      {
        'items': [_happyRow],
        'hasMore': true,
        'extra': true,
      },
      {
        'items': [
          {..._happyRow, 'persona': 'extra'},
        ],
        'hasMore': false,
      },
      {
        'items': [
          {..._happyRow, 'seq': 4.2},
        ],
        'hasMore': false,
      },
      {
        'items': [
          {..._happyRow, 'seq': 3},
        ],
        'hasMore': false,
      },
      {
        'items': [
          {..._happyRow, 'exchangeId': 'bad/id'},
        ],
        'hasMore': false,
      },
      {
        'items': [
          {..._happyRow, 'assistant': '\n'},
        ],
        'hasMore': false,
      },
      {
        'items': [
          _happyRow,
          {..._happyRow, 'seq': 5},
        ],
        'hasMore': false,
      },
      {
        'items': [
          _happyRow,
          {..._happyRow, 'exchangeId': 'distinct'},
        ],
        'hasMore': false,
      },
      {
        'items': [
          for (var i = 4; i <= 20; i++)
            {..._happyRow, 'seq': i, 'exchangeId': 'id_$i'},
        ],
        'hasMore': false,
      },
    ]) {
      responseBody = jsonEncode(body);
      await expectLater(api.list(_profile, 3), throwsFormatException);
    }
  });

  test(
    'push rejects nonpositive, noninteger or inexact receipts and wrong status',
    () async {
      for (final (status, body) in [
        (200, '{"seq":0}'),
        (200, '{"seq":-1}'),
        (200, '{"seq":1.0}'),
        (200, '{"seq":"1"}'),
        (200, '{"seq":1,"message":"unexpected"}'),
        (201, '{"seq":1}'),
      ]) {
        responseStatus = status;
        responseBody = body;
        await expectLater(
          api.push(_profile, exchangeId: 'exchange', user: 'u', assistant: 'a'),
          throwsFormatException,
        );
      }
      expect(calls, hasLength(6));
    },
  );

  test(
    'read body is bounded; parser errors do not expose response bytes',
    () async {
      const privateText = 'synthetic private response bytes';
      final safe = throwsA(
        isA<FormatException>().having(
          (e) => e.toString(),
          'diagnostic',
          isNot(contains(privateText)),
        ),
      );
      responseBody = '{"items":[$privateText';
      await expectLater(api.list(_profile, 0), safe);
      // Valid JSON with padding: only the wire-body limit should reject it.
      responseBody = '{"items":[],"hasMore":false}${' ' * (2 << 20)}';
      await expectLater(api.list(_profile, 0), safe);
      responseBody = '{"seq":1}${' ' * 4096}';
      await expectLater(
        api.push(_profile, exchangeId: 'exchange', user: 'u', assistant: 'a'),
        safe,
      );
      expect(calls, hasLength(3));
    },
  );

  test('no method follows redirects or renews and replays a 401', () async {
    for (final (status, code) in [
      (307, FailureCode.unavailable),
      (401, FailureCode.unauthenticated),
      (409, FailureCode.conflict),
    ]) {
      responseStatus = status;
      responseBody = '{}';
      final failure = throwsA(
        isA<HostRequestException>().having((e) => e.failure.code, 'code', code),
      );
      await expectLater(api.list(_profile, 0), failure);
      await expectLater(
        api.push(_profile, exchangeId: 'exchange', user: 'u', assistant: 'a'),
        failure,
      );
    }
    expect(renewals, 0);
    expect(calls.map((c) => (c.method, c.path)), [
      for (var i = 0; i < 3; i++) ...[
        ('GET', '$_path?after=0'),
        ('POST', _path),
      ],
    ]);
  });
}

class _LoopbackHttp extends HttpOverrides {
  _LoopbackHttp(this.port);
  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = (uri) {
          if (uri.scheme != 'http' ||
              uri.host != '127.0.0.1' ||
              uri.port != port) {
            throw StateError('Only the test loopback is allowed');
          }
          return 'DIRECT';
        };
}
