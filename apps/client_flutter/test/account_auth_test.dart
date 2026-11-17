import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/account_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

Map<String, Object?> _credentials() => {
  'host': 'https://EXAMPLE.com:443/',
  'accountId': 'account-1',
  'deviceId': 'device_1',
  'accessToken': 'access-secret',
  'refreshToken': 'refresh-secret',
};

const _session = <String, Object?>{
  'deviceId': 'device_1',
  'accessToken': 'access-secret',
  'refreshToken': 'refresh-secret',
};

void main() {
  group('ClientCredentials', () {
    test(
      'round trips only validated credentials with canonical host origin',
      () {
        final credentials = ClientCredentials.fromJson(_credentials());
        expect(credentials.host.toString(), 'https://example.com');
        expect(credentials.accountId, 'account-1');
        expect(credentials.deviceId, 'device_1');
        expect(credentials.accessToken, 'access-secret');
        expect(credentials.refreshToken, 'refresh-secret');
        expect(credentials.toJson(), {
          'host': 'https://example.com',
          'accountId': 'account-1',
          'deviceId': 'device_1',
          'accessToken': 'access-secret',
          'refreshToken': 'refresh-secret',
        });
      },
    );

    for (final fixture in [
      (input: 'https://EXAMPLE.com:8443/', origin: 'https://example.com:8443'),
      (input: 'http://127.0.0.2:8080/', origin: 'http://127.0.0.2:8080'),
      (input: 'http://localhost:80/', origin: 'http://localhost'),
      (input: 'http://[::1]:8080/', origin: 'http://[::1]:8080'),
    ]) {
      test('accepts secure or loopback origin ${fixture.input}', () {
        final credentials = ClientCredentials.fromJson(
          _credentials()..['host'] = fixture.input,
        );
        expect(credentials.host.toString(), fixture.origin);
      });
    }

    for (final host in [
      'https://example.com:0',
      'https://example.com:65536',
      'https://@example.com',
      'https://example.com/a/..',
      'https://example.com/./',
      'https://example.com\\',
      ' https://example.com',
    ]) {
      test('rejects non-origin syntax before URI normalization: $host', () {
        expect(
          () => ClientCredentials.fromJson(_credentials()..['host'] = host),
          throwsFormatException,
        );
      });
    }

    for (final field in _credentials().keys) {
      for (final invalid in <Object?>[null, '', '   ', 12]) {
        test('rejects invalid $field (${invalid.runtimeType})', () {
          final json = _credentials()..[field] = invalid;
          expect(() => ClientCredentials.fromJson(json), throwsFormatException);
        });
      }
      test('rejects missing $field', () {
        final json = _credentials()..remove(field);
        expect(() => ClientCredentials.fromJson(json), throwsFormatException);
      });
    }

    for (final field in ['accountId', 'deviceId']) {
      for (final invalid in ['a.b', 'a/b', 'a b', 'x' * 65]) {
        test('validates core constraints for $field: $invalid', () {
          expect(
            () => ClientCredentials.fromJson(_credentials()..[field] = invalid),
            throwsFormatException,
          );
        });
      }
    }
  });

  group('AccountAuthenticator real HTTP', () {
    late HttpServer server;
    late String host;
    late AccountAuthenticator auth;
    late List<
      ({
        String method,
        String path,
        Object? body,
        String? contentType,
        String? authorization,
      })
    >
    received;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      host = 'http://127.0.0.1:${server.port}';
      auth = AccountAuthenticator();
      received = [];
    });
    tearDown(() async => server.close(force: true));

    void respond(Object? Function(HttpRequest request) reply) {
      server.listen((request) async {
        final text = await utf8.decoder.bind(request).join();
        received.add((
          method: request.method,
          path: request.uri.path,
          body: text.isEmpty ? null : jsonDecode(text),
          contentType: request.headers.contentType?.mimeType,
          authorization: request.headers.value(
            'author'
            'ization',
          ),
        ));
        final body = reply(request);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(body));
        await request.response.close();
      });
    }

    test(
      'redeems then logs in with exact host payloads and device tokens',
      () async {
        respond(
          (request) => request.uri.path == Routes.authInviteRedeem
              ? {'accountId': 'account-1'}
              : _session,
        );
        final credentials = await auth.connect(
          hostAddress: '$host/',
          password: 'password-secret',
          deviceName: 'My device',
          invite: 'invite-secret',
          displayName: 'Alice',
        );
        expect(received.map((r) => r.path), [
          '/api/v1/auth/invites/redeem',
          '/api/v1/auth/login',
        ]);
        expect(received.map((r) => r.method), ['POST', 'POST']);
        expect(received.map((r) => r.contentType), [
          'application/json',
          'application/json',
        ]);
        expect(received.map((r) => r.authorization), [null, null]);
        expect(received[0].body, {
          'code': 'invite-secret',
          'displayName': 'Alice',
          'password': 'password-secret',
        });
        expect(received[1].body, {
          'accountId': 'account-1',
          'password': 'password-secret',
          'deviceName': 'My device',
        });
        expect(credentials.toJson(), {
          'host': host,
          'accountId': 'account-1',
          ..._session,
        });
        expect(auth.redeemedAccountId, 'account-1');
      },
    );

    test(
      'refresh rotates tokens without changing host account or device',
      () async {
        final current = ClientCredentials.fromJson(
          _credentials()..['host'] = host,
        );
        respond(
          (_) => {
            'host': 'https://untrusted.example',
            'accountId': 'untrusted-account',
            'deviceId': 'device_1',
            'accessToken': 'rotated-access',
            'refreshToken': 'rotated-refresh',
          },
        );
        final refreshed = await auth.refresh(current);
        expect(received.single.path, '/api/v1/auth/refresh');
        expect(received.single.method, 'POST');
        expect(received.single.contentType, 'application/json');
        expect(received.single.authorization, isNull);
        expect(received.single.body, {'refreshToken': 'refresh-secret'});
        expect(refreshed.toJson(), {
          'host': host,
          'accountId': 'account-1',
          'deviceId': 'device_1',
          'accessToken': 'rotated-access',
          'refreshToken': 'rotated-refresh',
        });
        expect(current.accessToken, 'access-secret');
        expect(current.refreshToken, 'refresh-secret');
        expect(auth.redeemedAccountId, isNull);
      },
    );

    for (final fixture in <String, Object?>{
      'changed device': {..._session, 'deviceId': 'different_device'},
      'invalid device': {..._session, 'deviceId': 'refresh-secret/invalid'},
      'missing device': {
        'accessToken': 'access-secret',
        'refreshToken': 'refresh-secret',
      },
      'empty access': {..._session, 'accessToken': ''},
      'missing access': {
        'deviceId': 'device_1',
        'refreshToken': 'refresh-secret',
      },
      'blank refresh': {..._session, 'refreshToken': '  '},
      'wrong refresh type': {..._session, 'refreshToken': 12},
      'not an object': ['access-secret', 'refresh-secret'],
    }.entries) {
      test('refresh rejects ${fixture.key} without exposing tokens', () async {
        final current = ClientCredentials.fromJson(
          _credentials()..['host'] = host,
        );
        respond((_) => fixture.value);
        await expectLater(
          auth.refresh(current),
          throwsA(
            isA<FormatException>().having(
              (e) => e.toString(),
              'safe message',
              allOf(
                isNot(contains('access-secret')),
                isNot(contains('refresh-secret')),
              ),
            ),
          ),
        );
        expect(received.single.path, '/api/v1/auth/refresh');
        expect(current.deviceId, 'device_1');
      });
    }

    test('refresh sanitizes HTTP failure bodies', () async {
      final current = ClientCredentials.fromJson(
        _credentials()..['host'] = host,
      );
      respond((request) {
        request.response.statusCode = 401;
        return {'message': 'access-secret refresh-secret password-secret'};
      });
      await expectLater(
        auth.refresh(current),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'safe message',
            allOf(
              isNot(contains('access-secret')),
              isNot(contains('refresh-secret')),
              isNot(contains('password-secret')),
            ),
          ),
        ),
      );
      expect(received.single.path, '/api/v1/auth/refresh');
    });

    test('refresh sanitizes malformed JSON including parser source', () async {
      final current = ClientCredentials.fromJson(
        _credentials()..['host'] = host,
      );
      server.listen((request) async {
        await request.drain<void>();
        request.response.write('{access-secret refresh-secret');
        await request.response.close();
      });
      await expectLater(
        auth.refresh(current),
        throwsA(
          isA<FormatException>()
              .having((e) => e.source, 'no parser source', isNull)
              .having(
                (e) => e.toString(),
                'safe message',
                allOf(
                  isNot(contains('access-secret')),
                  isNot(contains('refresh-secret')),
                ),
              ),
        ),
      );
    });

    test('refresh never forwards its secret to a redirect target', () async {
      final current = ClientCredentials.fromJson(
        _credentials()..['host'] = host,
      );
      final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var forwarded = 0;
      other.listen((request) async {
        forwarded++;
        await request.drain<void>();
        request.response.write(jsonEncode(_session));
        await request.response.close();
      });
      try {
        respond((request) {
          request.response.statusCode = 307;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${other.port}/stolen',
          );
          return {};
        });
        await expectLater(auth.refresh(current), throwsException);
        expect(forwarded, 0);
      } finally {
        await other.close(force: true);
      }
    });

    test('refresh sanitizes transport failures', () async {
      final unavailable = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final current = ClientCredentials.fromJson(
        _credentials()..['host'] = 'http://127.0.0.1:${unavailable.port}',
      );
      await unavailable.close(force: true);
      await expectLater(
        auth.refresh(current),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'safe message',
            allOf(
              isNot(contains('access-secret')),
              isNot(contains('refresh-secret')),
            ),
          ),
        ),
      );
    });

    test('existing account logs in without redeeming an invite', () async {
      respond((_) => _session);
      final credentials = await auth.connect(
        hostAddress: host,
        password: 'password-secret',
        deviceName: 'Desktop',
        accountId: 'existing_1',
        invite: 'must-not-redeem',
        displayName: 'Ignored',
      );
      expect(received.single.path, '/api/v1/auth/login');
      expect(received.single.body, {
        'accountId': 'existing_1',
        'password': 'password-secret',
        'deviceName': 'Desktop',
      });
      expect(credentials.accountId, 'existing_1');
      expect(auth.redeemedAccountId, isNull);
    });

    test(
      'retry after login failure reuses redemption but uses current password',
      () async {
        var logins = 0;
        respond((request) {
          if (request.uri.path == Routes.authInviteRedeem) {
            return {'accountId': 'account-1'};
          }
          if (++logins == 1) {
            request.response.statusCode = 503;
            return {
              'error': 'unavailable',
              'message': 'password-secret access-secret',
            };
          }
          return _session;
        });
        await expectLater(
          auth.connect(
            hostAddress: host,
            password: 'password-secret',
            deviceName: 'Old device',
            invite: 'invite-secret',
            displayName: 'Alice',
          ),
          throwsException,
        );
        expect(auth.redeemedAccountId, 'account-1');
        final credentials = await auth.connect(
          hostAddress: '$host/',
          password: 'new-password',
          deviceName: 'New device',
          invite: 'invite-secret',
          displayName: 'Alice',
        );
        expect(received.map((r) => r.path), [
          '/api/v1/auth/invites/redeem',
          '/api/v1/auth/login',
          '/api/v1/auth/login',
        ]);
        expect(received.last.body, {
          'accountId': 'account-1',
          'password': 'new-password',
          'deviceName': 'New device',
        });
        expect(credentials.accountId, 'account-1');
      },
    );

    for (final changed in ['host', 'invite', 'displayName']) {
      test('redemption retry is scoped to $changed', () async {
        var redemptions = 0;
        respond((request) {
          if (request.uri.path == Routes.authInviteRedeem) {
            return {'accountId': 'account-${++redemptions}'};
          }
          request.response.statusCode = 503;
          return {'error': 'unavailable'};
        });
        await expectLater(
          auth.connect(
            hostAddress: host,
            password: 'password-secret',
            deviceName: 'Desktop',
            invite: 'invite-secret',
            displayName: 'Alice',
          ),
          throwsException,
        );
        // 127/8 addresses are all loopback, but distinct host origins.
        await expectLater(
          auth.connect(
            hostAddress: changed == 'host'
                ? host.replaceFirst('127.0.0.1', 'localhost')
                : host,
            password: 'password-secret',
            deviceName: 'Desktop',
            invite: changed == 'invite' ? 'different-invite' : 'invite-secret',
            displayName: changed == 'displayName' ? 'Bob' : 'Alice',
          ),
          throwsException,
        );
        expect(redemptions, 2);
        expect(auth.redeemedAccountId, 'account-2');
      });
    }

    final malformedSessions = <String, Object?>{
      'not an object': ['access-secret'],
      'empty': <String, Object?>{},
      'missing device': {
        'accessToken': 'access-secret',
        'refreshToken': 'refresh-secret',
      },
      'invalid device': {..._session, 'deviceId': 'access-secret/invalid'},
      'empty access': {..._session, 'accessToken': ''},
      'wrong access type': {..._session, 'accessToken': 12},
      'missing refresh': {
        'deviceId': 'device_1',
        'accessToken': 'access-secret',
      },
      'blank refresh': {..._session, 'refreshToken': '  '},
    };
    for (final entry in malformedSessions.entries) {
      test(
        'rejects malformed session ${entry.key} without leaking tokens',
        () async {
          respond((_) => entry.value);
          try {
            await auth.connect(
              hostAddress: host,
              password: 'password-secret',
              deviceName: 'Desktop',
              accountId: 'account-1',
            );
            fail('Accepted malformed session');
          } on Exception catch (error) {
            expect(error.toString(), isNot(contains('password-secret')));
            expect(error.toString(), isNot(contains('access-secret')));
            expect(error.toString(), isNot(contains('refresh-secret')));
          }
        },
      );
    }

    test('rejects malformed redemption without attempting login', () async {
      respond((_) => {'accountId': 'password-secret/invalid'});
      await expectLater(
        auth.connect(
          hostAddress: host,
          password: 'password-secret',
          deviceName: 'Desktop',
          invite: 'invite-secret',
          displayName: 'Alice',
        ),
        throwsFormatException,
      );
      expect(received, hasLength(1));
      expect(auth.redeemedAccountId, isNull);
    });

    test(
      'HTTP errors never expose upstream body, password or tokens',
      () async {
        respond((request) {
          request.response.statusCode = 401;
          return {
            'message':
                'password-secret access-secret refresh-secret invite-secret',
          };
        });
        try {
          await auth.connect(
            hostAddress: host,
            password: 'password-secret',
            deviceName: 'Desktop',
            accountId: 'account-1',
          );
          fail('Accepted HTTP failure');
        } on Exception catch (error) {
          expect(error.toString(), isNot(contains('password-secret')));
          expect(error.toString(), isNot(contains('access-secret')));
          expect(error.toString(), isNot(contains('refresh-secret')));
          expect(error.toString(), isNot(contains('invite-secret')));
        }
      },
    );

    test(
      'does not follow a redirect carrying credentials to another host',
      () async {
        final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var forwarded = 0;
        other.listen((request) async {
          forwarded++;
          await request.drain<void>();
          request.response.write(jsonEncode(_session));
          await request.response.close();
        });
        try {
          respond((request) {
            request.response.statusCode = 307;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              'http://127.0.0.1:${other.port}/stolen',
            );
            return {};
          });
          await expectLater(
            auth.connect(
              hostAddress: host,
              password: 'password-secret',
              deviceName: 'Desktop',
              accountId: 'account-1',
            ),
            throwsException,
          );
          expect(forwarded, 0);
        } finally {
          await other.close(force: true);
        }
      },
    );

    test(
      'invalid host URLs make no request and never echo supplied credentials',
      () async {
        respond((_) => _session);
        for (final (index, address) in [
          '',
          'not-a-url',
          '$host/path',
          '$host/?query=secret',
          '$host/?',
          '$host/#secret',
          '$host/#',
          host.replaceFirst('://', '://user:password-secret@'),
          host.replaceFirst('://', '://@'),
          'ftp://127.0.0.1:${server.port}',
          'http://192.168.1.2',
          'http://example.com',
          'http://localhost.example.com',
          'http://0.0.0.0',
          'https:///missing-host',
        ].indexed) {
          try {
            await auth.connect(
              hostAddress: address,
              password: 'password-secret',
              deviceName: 'Desktop',
              accountId: 'account-1',
            );
            fail('Accepted invalid host URL fixture $index');
          } on FormatException catch (error) {
            expect(error.toString(), isNot(contains('password-secret')));
          }
        }
        expect(received, isEmpty);
      },
    );
  });
}
