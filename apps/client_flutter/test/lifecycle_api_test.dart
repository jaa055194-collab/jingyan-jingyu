import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/lifecycle_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';

const _secret = '<redacted-secret>';
const _quotaPath = '/api/v1/lifecycle/quota';
const _surveyPath = '/api/v1/lifecycle/departure/survey';

Map<String, Object?> _quota({
  int used = 5,
  int quota = 100,
  int free = 10,
  int total = 20,
}) => {
  'usedBytes': used,
  'quotaBytes': quota,
  'diskFreeBytes': free,
  'diskTotalBytes': total,
};
Map<String, Object?> _survey() => {
  'objectCounts': {'conversations': 2, 'messages': 3},
  'momentsToAnonymize': 1,
  'totalObjects': 5,
};

void main() {
  late HttpServer server;
  late StreamSubscription<HttpRequest> subscription;
  late HostConnection connection;
  late LifecycleApi api;
  late List<(String, String, String?, String)> requests;
  late Object? payload;
  late int status;
  late Future<void> Function(HttpRequest) handler;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture-token',
    );
    api = LifecycleApi(connection);
    requests = [];
    payload = _quota();
    status = 200;
    handler = (request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add((
        request.method,
        request.uri.path,
        request.headers.value(HttpHeaders.authorizationHeader),
        body,
      ));
      request.response.statusCode = status;
      request.response.write(jsonEncode(payload));
      await request.response.close();
    };
    subscription = server.listen((request) => handler(request));
  });
  tearDown(() async {
    await subscription.cancel();
    await connection.close();
    await server.close(force: true);
  });

  test(
    'readQuota uses exact GET path/bearer with strict immutable DTO',
    () async {
      final result = await api.readQuota();
      expect(result.usedBytes, 5);
      expect(result.quotaBytes, 100);
      expect(result.diskFreeBytes, 10);
      expect(result.diskTotalBytes, 20);
      expect(result.toString(), isNot(contains(_secret)));
      expect(requests, [('GET', _quotaPath, 'Bearer fixture-token', '')]);
    },
  );

  test('readQuota rejects malformed, negative, nonpositive and inconsistent schema safely', () async {
    final bad = <Object?>[
      [],
      {..._quota()}..remove('quotaBytes'),
      {..._quota(), 'extra': _secret},
      _quota(used: -1),
      _quota(quota: 0),
      _quota(free: -1),
      _quota(total: 0),
      _quota(free: 21, total: 20),
      {..._quota(), 'usedBytes': 5.0},
      {..._quota(), 'quotaBytes': '100'},
      {..._quota(), 'usedBytes': _secret},
    ];
    for (final value in bad) {
      payload = value;
      await expectLater(
        api.readQuota(),
        throwsA(
          predicate(
            (e) =>
                e is FormatException &&
                e.source == null &&
                !e.toString().contains(_secret),
          ),
        ),
      );
    }
  });

  test(
    'readDepartureSurvey uses exact GET path and validates counts and total',
    () async {
      payload = _survey();
      final result = await api.readDepartureSurvey();
      expect(result.objectCounts, {'conversations': 2, 'messages': 3});
      expect(result.momentsToAnonymize, 1);
      expect(result.totalObjects, 5);
      expect(
        () => result.objectCounts['conversations'] = 9,
        throwsUnsupportedError,
      );
      expect(requests, [('GET', _surveyPath, 'Bearer fixture-token', '')]);
    },
  );

  test(
    'readDepartureSurvey rejects malformed/negative/sum-mismatch schema safely',
    () async {
      final bad = <Object?>[
        [],
        {..._survey()}..remove('totalObjects'),
        {..._survey(), 'extra': _secret},
        {..._survey(), 'objectCounts': []},
        {
          ..._survey(),
          'objectCounts': {'conversations': -1, 'messages': 6},
        },
        {
          ..._survey(),
          'objectCounts': {'conversations': null},
        },
        {
          ..._survey(),
          'objectCounts': {'conversations': '2', 'messages': 3},
        },
        {..._survey(), 'momentsToAnonymize': -1},
        {..._survey(), 'totalObjects': 4},
        {..._survey(), 'totalObjects': 6},
        {..._survey(), 'totalObjects': 5.0},
      ];
      for (final value in bad) {
        payload = value;
        await expectLater(
          api.readDepartureSurvey(),
          throwsA(
            predicate(
              (e) =>
                  e is FormatException &&
                  e.source == null &&
                  !e.toString().contains(_secret),
            ),
          ),
        );
      }
    },
  );

  for (final (name, path) in [('quota', _quotaPath), ('survey', _surveyPath)]) {
    test(
      '$name bounded 401 renewal replays at most once with updated token',
      () async {
        var renewals = 0, count = 0;
        connection = HostConnection(
          Uri.parse('http://127.0.0.1:${server.port}'),
          'old-token',
          onUnauthorized: () async {
            renewals++;
            connection.updateAccessToken('new-token');
            return true;
          },
        );
        api = LifecycleApi(connection);
        handler = (request) async {
          count++;
          requests.add((
            request.method,
            request.uri.path,
            request.headers.value(HttpHeaders.authorizationHeader),
            await utf8.decoder.bind(request).join(),
          ));
          if (count == 1) {
            request.response.statusCode = 401;
            request.response.write('{"error":"unauthenticated"}');
          } else {
            request.response.write(
              jsonEncode(path == _quotaPath ? _quota() : _survey()),
            );
          }
          await request.response.close();
        };
        if (path == _quotaPath) {
          await api.readQuota();
        } else {
          await api.readDepartureSurvey();
        }
        expect(requests.map((r) => (r.$2, r.$3)), [
          (path, 'Bearer old-token'),
          (path, 'Bearer new-token'),
        ]);
        expect(renewals, 1);
      },
    );

    test(
      '$name permanent 401 is terminal after one replay without leaking details',
      () async {
        var renewals = 0, count = 0;
        connection = HostConnection(
          Uri.parse('http://127.0.0.1:${server.port}'),
          'old-token',
          onUnauthorized: () async {
            renewals++;
            return true;
          },
        );
        api = LifecycleApi(connection);
        handler = (request) async {
          count++;
          await request.drain<void>();
          request.response.statusCode = 401;
          request.response.write(
            '{"error":"unauthenticated","detail":"$_secret"}',
          );
          await request.response.close();
        };
        await expectLater(
          path == _quotaPath ? api.readQuota() : api.readDepartureSurvey(),
          throwsA(
            predicate(
              (e) =>
                  e is HostRequestException &&
                  e.failure.code == FailureCode.unauthenticated &&
                  !e.toString().contains(_secret),
            ),
          ),
        );
        expect(count, 2);
        expect(renewals, 1);
      },
    );

    test('$name service 503 stays typed and is not replayed', () async {
      status = 503;
      payload = {'error': 'unavailable', 'detail': _secret};
      await expectLater(
        path == _quotaPath ? api.readQuota() : api.readDepartureSurvey(),
        throwsA(
          predicate(
            (e) =>
                e is HostRequestException &&
                e.failure.code == FailureCode.unavailable &&
                !e.toString().contains(_secret),
          ),
        ),
      );
      expect(requests.length, 1);
    });

    test('$name malformed success is safe and not replayed', () async {
      var count = 0;
      handler = (request) async {
        count++;
        await request.drain<void>();
        request.response.write('{$_secret not-json');
        await request.response.close();
      };
      await expectLater(
        path == _quotaPath ? api.readQuota() : api.readDepartureSurvey(),
        throwsA(
          predicate(
            (e) =>
                e is FormatException &&
                e.source == null &&
                !e.toString().contains(_secret),
          ),
        ),
      );
      expect(count, 1);
    });
  }

  test(
    'disconnected response is a safe typed failure and is not retried',
    () async {
      var count = 0;
      handler = (request) async {
        count++;
        await request.drain<void>();
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
      };
      await expectLater(api.readQuota(), throwsA(isA<HostRequestException>()));
      expect(count, 1);
    },
  );
}
