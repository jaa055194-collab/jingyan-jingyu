import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/voice_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';

class _Req {
  _Req(this.method, this.path, this.auth, this.body);
  final String method;
  final String path;
  final String? auth;
  final String body;
}

Map<String, Object?> profileJson({
  String aiId = 'profile',
  int revision = 1,
  bool pending = false,
}) => {
  'aiId': aiId,
  'provider': 'minimax',
  'model': 'speech-01',
  'voiceId': 'v-100',
  'params': {'speed': 1.1, 'emotion': 'happy'},
  'revision': revision,
  'consentRef': 'consent-1',
  'activatedAt': '2026-01-01T00:00:00.000Z',
  if (pending) 'pendingRevision': revision + 1,
  if (pending) 'pendingParams': {'speed': 1.2},
};

Map<String, Object?> ticketJson({String aiId = 'profile'}) => {
  'token': 'fixture-ticket-token',
  'aiId': aiId,
  'expiresAt': '2026-01-01T00:05:00.000Z',
};

void main() {
  late HttpServer server;
  late HostConnection connection;
  late VoiceApi api;
  late List<_Req> requests;
  Map<String, Object?>? responseJson;
  late int status;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture-token',
    );
    api = VoiceApi(connection);
    requests = <_Req>[];
    responseJson = null;
    status = 200;
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add(
        _Req(
          request.method,
          request.uri.toString(),
          request.headers.value(HttpHeaders.authorizationHeader),
          body,
        ),
      );
      request.response.statusCode = status;
      if (responseJson != null) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(responseJson));
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  test(
    'reads profile and issues ticket on exact host path/method/empty body',
    () async {
      responseJson = profileJson();
      final profile = await api.readProfile('profile');
      expect(profile.aiId, 'profile');
      expect(profile.provider, 'minimax');
      expect(profile.model, 'speech-01');
      expect(profile.voiceId, 'v-100');
      expect(profile.params['speed'], 1.1);
      expect(profile.revision, 1);
      expect(profile.consentRef, 'consent-1');
      expect(
        profile.activatedAt.toUtc().toIso8601String(),
        '2026-01-01T00:00:00.000Z',
      );
      expect(profile.pendingRevision, isNull);

      responseJson = ticketJson();
      final ticket = await api.issueTicket('profile');
      expect(ticket.token, 'fixture-ticket-token');
      expect(ticket.aiId, 'profile');
      expect(
        ticket.expiresAt.toUtc().toIso8601String(),
        '2026-01-01T00:05:00.000Z',
      );

      const base = '/api/v1/ai-profiles/profile';
      expect(requests.map((r) => (r.method, r.path, r.auth)).toList(), [
        ('GET', '$base/voice-profile', 'Bearer fixture-token'),
        ('POST', '$base/voice-ticket', 'Bearer fixture-token'),
      ]);
      expect(requests[0].body, isEmpty);
      expect(requests[1].body, isEmpty);
    },
  );

  test('accepts paired pending revision and params', () async {
    responseJson = profileJson(revision: 2, pending: true);
    final profile = await api.readProfile('profile');
    expect(profile.revision, 2);
    expect(profile.pendingRevision, 3);
    expect(profile.pendingParams?['speed'], 1.2);
  });

  test(
    'rejects malformed profile DTOs (unknown/key fields, wrong aiId, types)',
    () async {
      final malformed = <Map<String, Object?>>[
        profileJson(aiId: 'other'), // context mismatch
        profileJson()..remove('voiceId'), // missing required
        profileJson()..['apiKey'] = 'sk-secret-should-never-parse',
        profileJson()..['revision'] = 0,
        profileJson()..['params'] = 'not-a-map',
        profileJson()..['activatedAt'] = 'not-a-date',
        profileJson()..['provider'] = '',
        {
          /* pendingRevision without pendingParams */ ...profileJson(),
          'pendingRevision': 3,
        },
      ];
      for (final bad in malformed) {
        responseJson = bad;
        await expectLater(
          api.readProfile('profile'),
          throwsA(isA<FormatException>()),
          reason: 'must reject $bad',
        );
      }
    },
  );

  test(
    'rejects malformed ticket DTOs including unexpected key fields',
    () async {
      final malformed = <Map<String, Object?>>[
        ticketJson(aiId: 'other'),
        ticketJson()..remove('expiresAt'),
        ticketJson()..['vendorKey'] = 'sk-secret',
        ticketJson()..['token'] = '',
        ticketJson()..['expiresAt'] = 'nope',
      ];
      for (final bad in malformed) {
        responseJson = bad;
        await expectLater(
          api.issueTicket('profile'),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );

  test('rejects invalid aiId before any request', () async {
    await expectLater(
      api.readProfile('bad/id'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(api.issueTicket(''), throwsA(isA<FormatException>()));
    expect(requests, isEmpty);
  });

  test('maps HTTP failures safely without leaking bearer or body', () async {
    status = 404;
    responseJson = {'error': 'not_found'};
    await expectLater(
      api.readProfile('profile'),
      throwsA(
        isA<HostRequestException>().having(
          (e) => e.failure.code,
          'code',
          FailureCode.notFound,
        ),
      ),
    );
    status = 500;
    responseJson = null;
    await expectLater(
      api.issueTicket('profile'),
      throwsA(
        isA<HostRequestException>().having(
          (e) => e.failure.code,
          'code',
          FailureCode.unavailable,
        ),
      ),
    );
    for (final request in requests) {
      expect(request.auth, 'Bearer fixture-token');
    }
  });

  test(
    'bounded 401 stays single-attempt when authentication cannot renew',
    () async {
      status = 401;
      responseJson = {'error': 'unauthenticated'};
      await expectLater(
        api.readProfile('profile', retryAuthentication: false),
        throwsA(
          isA<HostRequestException>().having(
            (e) => e.failure.code,
            'code',
            FailureCode.unauthenticated,
          ),
        ),
      );
      expect(requests.length, 1);

      final unbounded = HostConnection(
        Uri.parse('http://127.0.0.1:${server.port}'),
        'fixture-token',
        onUnauthorized: () async => false,
      );
      final retrying = VoiceApi(unbounded);
      try {
        await expectLater(
          retrying.issueTicket('profile'),
          throwsA(
            isA<HostRequestException>().having(
              (e) => e.failure.details['authenticationRenewalFailed'],
              'renewalFailed',
              true,
            ),
          ),
        );
        expect(requests.length, 2);
      } finally {
        await unbounded.close();
      }
    },
  );
}
