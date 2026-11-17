import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/owner_ai_direct_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

Map<String, Object?> _view({
  String profile = 'profile',
  String account = 'ai-account',
  String? conversation = 'direct-chat',
  bool enabled = true,
  int revision = 1,
}) => {
  'scope': 'ownerTextOnly',
  'aiProfileId': profile,
  'aiAccountId': account,
  'conversationId': conversation,
  'enabled': enabled,
  'revision': revision,
};

void main() {
  late HttpServer server;
  late HostConnection connection;
  late OwnerAiDirectApi api;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture-token',
    );
    api = OwnerAiDirectApi(connection);
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  Future<OwnerAiDirectConsentState> invoke(String method, {int revision = 0}) =>
      switch (method) {
        'GET' => api.read('profile'),
        'POST' => api.open('profile', expectedRevision: revision),
        'DELETE' => api.revoke('profile', expectedRevision: revision),
        _ => throw StateError('unknown test operation'),
      };

  test('read, explicit open and revoke use exact host path, CAS-only body and bearer', () async {
    final requests = <(String, String, String?, Object?)>[];
    final views = [
      _view(conversation: null, enabled: false, revision: 0),
      _view(),
      _view(enabled: false, revision: 2),
    ];
    server.listen((request) async {
      final text = await utf8.decoder.bind(request).join();
      requests.add((
        request.method,
        request.uri.toString(),
        request.headers.value(HttpHeaders.authorizationHeader),
        text.isEmpty ? null : jsonDecode(text),
      ));
      request.response.write(jsonEncode(views[requests.length - 1]));
      await request.response.close();
    });
    final initial = await api.read('profile');
    expect(initial.scope, 'ownerTextOnly');
    expect(initial.aiProfileId, 'profile');
    expect(initial.aiAccountId, 'ai-account');
    expect(initial.conversationId, isNull);
    expect(initial.enabled, isFalse);
    expect(initial.revision, 0);
    final opened = await api.open('profile', expectedRevision: 0);
    expect(opened.conversationId, 'direct-chat');
    expect(opened.enabled, isTrue);
    expect(opened.revision, 1);
    final revoked = await api.revoke('profile', expectedRevision: 1);
    expect(revoked.enabled, isFalse);
    expect(revoked.conversationId, 'direct-chat');
    expect(revoked.revision, 2);
    const path = '/api/v1/ai-profiles/profile/direct-conversation';
    expect(Routes.ownerAiDirectConsent.replaceFirst('{aiId}', 'profile'), path);
    expect(requests.map((r) => (r.$1, r.$2, r.$3)), [
      ('GET', path, 'Bearer fixture-token'),
      ('POST', path, 'Bearer fixture-token'),
      ('DELETE', path, 'Bearer fixture-token'),
    ]);
    expect(requests.map((r) => r.$4), [
      null,
      {'expectedRevision': 0},
      {'expectedRevision': 1},
    ]);
  });

  test(
    'revoking never-opened consent permits canonical revision-zero no-op',
    () async {
      server.listen((request) async {
        await request.drain<void>();
        request.response.write(
          jsonEncode(_view(conversation: null, enabled: false, revision: 0)),
        );
        await request.response.close();
      });
      final result = await api.revoke('profile', expectedRevision: 0);
      expect(result.revision, 0);
      expect(result.conversationId, isNull);
      expect(result.enabled, isFalse);
    },
  );

  test('read preserves disabled historical conversation and current nonzero revision', () async {
    server.listen((request) async {
      await request.drain<void>();
      request.response.write(jsonEncode(_view(enabled: false, revision: 7)));
      await request.response.close();
    });
    final result = await api.read('profile');
    expect(result.revision, 7);
    expect(result.conversationId, 'direct-chat');
    expect(result.enabled, isFalse);
  });

  test('profile and AI account are distinct concepts but valid equal values are accepted', () async {
    server.listen((request) async {
      await request.drain<void>();
      request.response.write(jsonEncode(_view(account: 'profile')));
      await request.response.close();
    });
    final result = await api.read('profile');
    expect(result.aiProfileId, 'profile');
    expect(result.aiAccountId, 'profile');
  });

  test('strict response DTO rejects malformed identities, fields and inconsistent states safely', () async {
    final invalid = <Object?>[
      [],
      {..._view()}..remove('scope'),
      {..._view()}..remove('conversationId'),
      {..._view(), 'extra': 'private-secret'},
      {..._view(), 'scope': 'allMessages'},
      {..._view(), 'aiProfileId': 'wrong-profile'},
      {..._view(), 'aiProfileId': 'bad/private-secret'},
      {..._view(), 'aiAccountId': null},
      {..._view(), 'aiAccountId': 'bad/private-secret'},
      {..._view(), 'conversationId': 'bad/private-secret'},
      {..._view(), 'conversationId': null},
      {..._view(), 'enabled': 'true'},
      {..._view(), 'revision': 1.0},
      {..._view(), 'revision': -1},
      {..._view(), 'revision': 'private-secret'},
      _view(conversation: null, enabled: false, revision: 1),
      _view(enabled: false, revision: 0),
    ];
    var count = 0;
    server.listen((request) async {
      await request.drain<void>();
      request.response.write(jsonEncode(invalid[count++]));
      await request.response.close();
    });
    for (var i = 0; i < invalid.length; i++) {
      await expectLater(
        api.read('profile'),
        throwsA(
          predicate(
            (error) =>
                error is FormatException &&
                error.source == null &&
                !error.toString().contains('private-secret'),
          ),
        ),
        reason: 'response $i',
      );
    }
    expect(count, invalid.length);
  });

  test('mutation response must reflect requested operation and exact next CAS revision', () async {
    final cases = <(String, int, Map<String, Object?>)>[
      ('POST', 0, _view(enabled: false)),
      ('POST', 1, _view(revision: 1)),
      ('POST', 1, _view(revision: 3)),
      ('DELETE', 1, _view(enabled: true, revision: 2)),
      ('DELETE', 1, _view(enabled: false, revision: 1)),
      ('DELETE', 1, _view(conversation: null, enabled: false, revision: 0)),
    ];
    var count = 0;
    server.listen((request) async {
      await request.drain<void>();
      request.response.write(jsonEncode(cases[count++].$3));
      await request.response.close();
    });
    for (final (method, revision, _) in cases) {
      await expectLater(
        invoke(method, revision: revision),
        throwsFormatException,
      );
    }
    expect(count, cases.length);
  });

  test(
    'invalid profile/CAS arguments never issue HTTP or expose supplied ids',
    () async {
      var count = 0;
      server.listen((request) async {
        count++;
        await request.drain<void>();
        request.response.statusCode = 500;
        await request.response.close();
      });
      for (final profile in ['', 'bad/private-secret', ' profile', 'x' * 65]) {
        for (final call in <Future<Object?> Function()>[
          () => api.read(profile),
          () => api.open(profile, expectedRevision: 0),
          () => api.revoke(profile, expectedRevision: 0),
        ]) {
          await expectLater(
            call(),
            throwsA(
              predicate(
                (error) =>
                    error is FormatException &&
                    error.source == null &&
                    !error.toString().contains('private-secret'),
              ),
            ),
          );
        }
      }
      await expectLater(
        api.open('profile', expectedRevision: -1),
        throwsFormatException,
      );
      await expectLater(
        api.revoke('profile', expectedRevision: -1),
        throwsFormatException,
      );
      expect(count, 0);
    },
  );

  test('registerOrResolve maps explicit account to canonical profile idempotently without consent calls', () async {
    final requests = <(String, String, String?, Object?)>[];
    server.listen((request) async {
      final text = await utf8.decoder.bind(request).join();
      requests.add((
        request.method,
        request.uri.toString(),
        request.headers.value(HttpHeaders.authorizationHeader),
        jsonDecode(text),
      ));
      request.response.write(
        jsonEncode({
          'profileId': 'different-profile',
          'accountId': 'ai-account',
          'ownerAccountId': 'owner',
        }),
      );
      await request.response.close();
    });
    for (var i = 0; i < 2; i++) {
      final OwnedAiProfileIdentity identity = await api.registerOrResolve(
        'ai-account',
        expectedOwnerAccountId: 'owner',
      );
      expect(identity.profileId, 'different-profile');
      expect(identity.accountId, 'ai-account');
      expect(identity.ownerAccountId, 'owner');
    }
    expect(requests.map((r) => (r.$1, r.$2, r.$3)), [
      ('POST', '/api/v1/ai-profiles/register', 'Bearer fixture-token'),
      ('POST', '/api/v1/ai-profiles/register', 'Bearer fixture-token'),
    ]);
    expect(requests.map((r) => r.$4), [
      {'accountId': 'ai-account'},
      {'accountId': 'ai-account'},
    ]);
  });

  test('register identity strictly validates account/owner context and safe profile identity', () async {
    final valid = <String, Object?>{
      'profileId': 'profile',
      'accountId': 'ai-account',
      'ownerAccountId': 'owner',
    };
    final invalid = <Object?>[
      [],
      {...valid}..remove('profileId'),
      {...valid, 'profileId': 'private/secret'},
      {...valid, 'profileId': null},
      {...valid, 'accountId': 'other-account'},
      {...valid, 'ownerAccountId': 'other-owner'},
      {...valid, 'accountId': 'private/secret'},
      {...valid, 'ownerAccountId': 1},
      {...valid, 'extra': 'private-secret'},
    ];
    var count = 0;
    server.listen((request) async {
      await request.drain<void>();
      request.response.write(jsonEncode(invalid[count++]));
      await request.response.close();
    });
    for (var i = 0; i < invalid.length; i++) {
      await expectLater(
        api.registerOrResolve('ai-account', expectedOwnerAccountId: 'owner'),
        throwsA(
          predicate(
            (e) =>
                e is FormatException &&
                e.source == null &&
                !e.toString().contains('private') &&
                !e.toString().contains('secret'),
          ),
        ),
      );
    }
    expect(count, invalid.length);
  });

  test('register validates input identities before any request', () async {
    var count = 0;
    server.listen((request) async {
      count++;
      await request.response.close();
    });
    for (final (account, owner) in [
      ('', 'owner'),
      ('ai-account', ''),
      ('bad/private-secret', 'owner'),
      ('ai-account', 'bad/private-secret'),
    ]) {
      await expectLater(
        api.registerOrResolve(account, expectedOwnerAccountId: owner),
        throwsA(
          predicate(
            (e) =>
                e is FormatException &&
                e.source == null &&
                !e.toString().contains('private-secret'),
          ),
        ),
      );
    }
    expect(count, 0);
  });

  test('register 401 uses bounded existing renewal and preserves explicit account body', () async {
    var count = 0, renewals = 0;
    final bodies = <Object?>[];
    await connection.close();
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'old-token',
      onUnauthorized: () async {
        renewals++;
        connection.updateAccessToken('new-token');
        return true;
      },
    );
    api = OwnerAiDirectApi(connection);
    server.listen((request) async {
      bodies.add(jsonDecode(await utf8.decoder.bind(request).join()));
      count++;
      if (count == 1) {
        request.response.statusCode = 401;
        request.response.write('{"error":"unauthenticated"}');
      } else {
        request.response.write(
          jsonEncode({
            'profileId': 'profile',
            'accountId': 'ai-account',
            'ownerAccountId': 'owner',
          }),
        );
      }
      await request.response.close();
    });
    await api.registerOrResolve('ai-account', expectedOwnerAccountId: 'owner');
    expect(count, 2);
    expect(renewals, 1);
    expect(bodies, [
      {'accountId': 'ai-account'},
      {'accountId': 'ai-account'},
    ]);
  });

  for (final malformed in [false, true]) {
    test(
      'register ${malformed ? 'malformed success' : '503'} is not implicitly replayed',
      () async {
        var count = 0;
        server.listen((request) async {
          count++;
          await request.drain<void>();
          request.response.statusCode = malformed ? 200 : 503;
          request.response.write('private-secret malformed');
          await request.response.close();
        });
        await expectLater(
          api.registerOrResolve('ai-account', expectedOwnerAccountId: 'owner'),
          throwsA(
            predicate(
              (e) =>
                  (e is FormatException || e is HostRequestException) &&
                  !e.toString().contains('private-secret'),
            ),
          ),
        );
        expect(count, 1);
      },
    );
  }

  for (final method in ['POST', 'DELETE']) {
    test(
      '$method retryAuthentication=false never renews or replays a 401 mutation',
      () async {
        var count = 0, renewals = 0;
        await connection.close();
        connection = HostConnection(
          Uri.parse('http://127.0.0.1:${server.port}'),
          'old-token',
          onUnauthorized: () async {
            renewals++;
            return true;
          },
        );
        api = OwnerAiDirectApi(connection);
        server.listen((request) async {
          count++;
          await request.drain<void>();
          request.response.statusCode = 401;
          request.response.write('{"error":"unauthenticated"}');
          await request.response.close();
        });
        final call = method == 'POST'
            ? api.open(
                'profile',
                expectedRevision: 0,
                retryAuthentication: false,
              )
            : api.revoke(
                'profile',
                expectedRevision: 0,
                retryAuthentication: false,
              );
        await expectLater(
          call,
          throwsA(
            isA<HostRequestException>().having(
              (e) => e.failure.code,
              'code',
              FailureCode.unauthenticated,
            ),
          ),
        );
        expect(count, 1);
        expect(renewals, 0);
      },
    );
  }

  for (final method in ['GET', 'POST', 'DELETE']) {
    test(
      '$method renews 401 once through existing HostConnection with identical CAS body',
      () async {
        final seen = <(String, String?, Object?)>[];
        var renewals = 0;
        await connection.close();
        connection = HostConnection(
          Uri.parse('http://127.0.0.1:${server.port}'),
          'old-token',
          onUnauthorized: () async {
            renewals++;
            connection.updateAccessToken('new-token');
            return true;
          },
        );
        api = OwnerAiDirectApi(connection);
        server.listen((request) async {
          final text = await utf8.decoder.bind(request).join();
          seen.add((
            request.method,
            request.headers.value(HttpHeaders.authorizationHeader),
            text.isEmpty ? null : jsonDecode(text),
          ));
          if (seen.length == 1) {
            request.response.statusCode = 401;
            request.response.write('{"error":"unauthenticated"}');
          } else {
            request.response.write(
              jsonEncode(_view(enabled: method != 'DELETE')),
            );
          }
          await request.response.close();
        });
        await invoke(method);
        final expectedBody = method == 'GET' ? null : {'expectedRevision': 0};
        expect(seen.map((r) => (r.$1, r.$2)), [
          (method, 'Bearer old-token'),
          (method, 'Bearer new-token'),
        ]);
        expect(seen.map((r) => r.$3), [expectedBody, expectedBody]);
        expect(renewals, 1);
      },
    );

    test(
      '$method permanent 401 is terminal after one authentication replay',
      () async {
        var count = 0, renewals = 0;
        await connection.close();
        connection = HostConnection(
          Uri.parse('http://127.0.0.1:${server.port}'),
          'old-token',
          onUnauthorized: () async {
            renewals++;
            return true;
          },
        );
        api = OwnerAiDirectApi(connection);
        server.listen((request) async {
          count++;
          await request.drain<void>();
          request.response.statusCode = 401;
          request.response.write('{"error":"unauthenticated"}');
          await request.response.close();
        });
        await expectLater(
          invoke(method),
          throwsA(
            isA<HostRequestException>().having(
              (e) => e.failure.code,
              'code',
              FailureCode.unauthenticated,
            ),
          ),
        );
        expect(count, 2);
        expect(renewals, 1);
      },
    );
  }

  for (final method in ['POST', 'DELETE']) {
    for (final status in [404, 409, 503]) {
      test(
        '$method $status never automatically retries uncertain/terminal mutation',
        () async {
          var count = 0;
          server.listen((request) async {
            count++;
            await request.drain<void>();
            request.response.statusCode = status;
            request.response.write('private-secret proxy body');
            await request.response.close();
          });
          final code = switch (status) {
            404 => FailureCode.notFound,
            409 => FailureCode.conflict,
            _ => FailureCode.unavailable,
          };
          await expectLater(
            invoke(method),
            throwsA(
              predicate(
                (error) =>
                    error is HostRequestException &&
                    error.failure.code == code &&
                    !error.toString().contains('private-secret'),
              ),
            ),
          );
          expect(count, 1);
        },
      );
    }

    test(
      '$method malformed success is safe and is not automatically replayed',
      () async {
        var count = 0;
        server.listen((request) async {
          count++;
          await request.drain<void>();
          request.response.write('{ private-secret malformed JSON');
          await request.response.close();
        });
        await expectLater(
          invoke(method),
          throwsA(
            predicate(
              (error) =>
                  error is FormatException &&
                  error.source == null &&
                  !error.toString().contains('private-secret'),
            ),
          ),
        );
        expect(count, 1);
      },
    );

    test(
      '$method disconnected response is sanitized and never automatically replayed',
      () async {
        var count = 0;
        server.listen((request) async {
          count++;
          await request.drain<void>();
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.destroy();
        });
        await expectLater(
          invoke(method),
          throwsA(
            predicate(
              (error) =>
                  error is HostRequestException &&
                  error.failure.code == FailureCode.unavailable &&
                  !error.toString().contains('127.0.0.1') &&
                  !error.toString().contains('fixture-token'),
            ),
          ),
        );
        expect(count, 1);
      },
    );

    test(
      '$method redirect does not forward bearer or replay mutation',
      () async {
        var count = 0;
        server.listen((request) async {
          count++;
          await request.drain<void>();
          request.response.statusCode = 307;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/redirect-target',
          );
          request.response.write('private-secret');
          await request.response.close();
        });
        await expectLater(invoke(method), throwsA(isA<HostRequestException>()));
        expect(count, 1);
      },
    );
  }
}
