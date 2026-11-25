import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/ai_config_write_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

void main() {
  late HttpServer server;
  late HostConnection connection;
  late AiConfigWriteApi api;
  late List<(String, String, Map<String, Object?>?)> requests;
  Map<String, Object?>? responseJson;
  late int status;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture',
    );
    api = AiConfigWriteApi(connection);
    requests = [];
    responseJson = null;
    status = 200;
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      requests.add((
        request.method,
        request.uri.path,
        raw.isEmpty ? null : (jsonDecode(raw) as Map).cast<String, Object?>(),
      ));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      if (responseJson != null) {
        request.response.write(jsonEncode(responseJson));
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  Map<String, Object?> providerJson({String mask = '****abcd'}) => {
    'id': 'prov-1',
    'name': 'P',
    'base_url': 'https://provider.example/v1',
    'key_mask': mask,
    'enabled': true,
    'capabilities': ['chat'],
  };

  test(
    'creates provider with exact POST, body and masked response only',
    () async {
      responseJson = providerJson();
      final view = await api.createProvider(
        name: 'P',
        baseUrl: 'https://provider.example/v1',
        apiKey: 'real-secret-key',
        capabilities: {'chat'},
      );
      expect(view.id, 'prov-1');
      expect(view.keyMask, '****abcd');
      final (method, path, body) = requests.single;
      expect(method, 'POST');
      expect(path, Routes.modelProviders);
      expect(body, {
        'name': 'P',
        'base_url': 'https://provider.example/v1',
        'api_key': 'real-secret-key',
        'capabilities': ['chat'],
        'enabled': true,
      });
      // The parsed view has no api_key field and its string form never contains it.
      expect(view.toString().contains('real-secret-key'), isFalse);
    },
  );

  test('provider response with api_key echo is rejected', () async {
    responseJson = {...providerJson(), 'api_key': 'leaked'};
    await expectLater(
      api.createProvider(
        name: 'P',
        baseUrl: 'https://provider.example/v1',
        apiKey: 'k',
        capabilities: {'chat'},
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'update provider uses PUT path and partial body; empty update is rejected',
    () async {
      responseJson = providerJson();
      await api.updateProvider('prov-1', name: 'New', apiKey: 'k2');
      final (method, path, body) = requests.single;
      expect(method, 'PUT');
      expect(path, Routes.modelProvider.replaceFirst('{providerId}', 'prov-1'));
      expect(body, {'name': 'New', 'api_key': 'k2'});
      await expectLater(
        api.updateProvider('prov-1'),
        throwsA(isA<FormatException>()),
      );
      expect(requests.length, 1);
    },
  );

  test('persona initialize and edit use exact paths and bodies', () async {
    responseJson = {
      'aiId': 'profile',
      'version': 1,
      'locked': false,
      'layers': {'p0': {}, 'p1': {}, 'p2': {}},
    };
    await api.initializePersona(
      'profile',
      p0: {'name': 'Nora'},
      p1: {'style': 'warm'},
      p2: {'mood': 'calm'},
    );
    var request = requests.single;
    expect(request.$1, 'POST');
    expect(
      request.$2,
      Routes.aiPersonaInitialize.replaceFirst('{aiId}', 'profile'),
    );
    expect(request.$3, {
      'p0': {'name': 'Nora'},
      'p1': {'style': 'warm'},
      'p2': {'mood': 'calm'},
    });

    requests.clear();
    responseJson = {
      'aiId': 'profile',
      'version': 2,
      'locked': false,
      'layers': {'p0': {}, 'p1': {}, 'p2': {}},
    };
    await api.editPersona(
      'profile',
      expectedVersion: 1,
      reason: 'update',
      p0: {'name': 'Nora2'},
      p1: {},
      p2: {},
    );
    request = requests.single;
    expect(request.$1, 'PATCH');
    expect(request.$2, Routes.aiPersona.replaceFirst('{aiId}', 'profile'));
    expect(request.$3, {
      'expectedVersion': 1,
      'reason': 'update',
      'diff': {
        'p0': {'name': 'Nora2'},
        'p1': {},
        'p2': {},
      },
    });
  });

  AiConfigWriteApi multilineWriter() => AiConfigWriteApi(
    connection,
    allowMultilinePersona: true,
    retryAuthentication: false,
  );

  test(
    'opt-in persona writes keep whitespace, line breaks and null deletes exact',
    () async {
      const value = '  First line\nSecond line\twith a tab\r\n ';
      responseJson = {
        'aiId': 'profile',
        'version': 2,
        'locked': false,
        'layers': {
          'p0': {'name': 'Nora'},
          'p1': {'style': value},
          'p2': {'mood': 'calm'},
        },
      };
      final writer = multilineWriter();
      await writer.editPersona(
        'profile',
        expectedVersion: 1,
        reason: 'update',
        p0: {},
        p1: {'style': value, 'old': null},
        p2: {},
      );
      final (method, path, body) = requests.single;
      expect(
        (method, path),
        ('PATCH', Routes.aiPersona.replaceFirst('{aiId}', 'profile')),
      );
      expect(body, {
        'expectedVersion': 1,
        'reason': 'update',
        'diff': {
          'p0': {},
          'p1': {'style': value, 'old': null},
          'p2': {},
        },
      });
      requests.clear();
      responseJson = {...responseJson!, 'version': 1};
      await writer.initializePersona(
        'profile',
        p0: {'name': 'Nora'},
        p1: {'style': value},
        p2: {'mood': 'calm'},
      );
      expect(requests.single.$3, {
        'p0': {'name': 'Nora'},
        'p1': {'style': value},
        'p2': {'mood': 'calm'},
      });
    },
  );

  test('persona opt-in still rejects invalid text and leaves legacy validation intact', () async {
    Future<void> patch(AiConfigWriteApi writer, String key, String value) =>
        writer.editPersona(
          'profile',
          expectedVersion: 1,
          reason: 'update',
          p0: {key: value},
          p1: {},
          p2: {},
        );
    final writer = multilineWriter();
    for (final (key, value) in [
      ('style', '\t\n '),
      ('style', 'x\u0085x'),
      ('bad\nkey', 'good'),
      (' key', 'good'),
    ]) {
      await expectLater(
        patch(writer, key, value),
        throwsA(isA<FormatException>()),
      );
    }
    await expectLater(
      patch(api, 'style', 'First\nSecond'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      writer.setChatBinding(
        'profile',
        providerId: 'prov-1',
        model: 'bad\nmodel',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(requests, isEmpty);
  });

  test(
    'chat binding and budget use exact paths and validated bodies',
    () async {
      responseJson = {
        'owner_id': 'owner',
        'ai_profile_id': 'profile',
        'capability': 'chat',
        'provider_id': 'prov-1',
        'model': 'gpt-x',
      };
      await api.setChatBinding('profile', providerId: 'prov-1', model: 'gpt-x');
      var request = requests.single;
      expect(request.$1, 'PUT');
      expect(
        request.$2,
        Routes.aiBinding
            .replaceFirst('{aiId}', 'profile')
            .replaceFirst('{capability}', 'chat'),
      );
      expect(request.$3, {'providerId': 'prov-1', 'model': 'gpt-x'});

      requests.clear();
      responseJson = {
        'dailyTokens': 100,
        'layerLimits': {
          'b0Life': 1,
          'b1FastBrain': 1,
          'b2DeepChat': 1,
          'b3Proactive': 1,
          'b4Maintenance': 1,
        },
        'capabilityLimits': {
          'chat': 1,
          'chatFast': 1,
          'vision': 1,
          'imageGen': 1,
          'tts': 1,
          'asr': 1,
          'embedding': 1,
        },
        'offsetMinutes': 480,
      };
      await api.configureBudget(
        'profile',
        dailyTokens: 100,
        layerLimits: const {
          'b0Life': 1,
          'b1FastBrain': 1,
          'b2DeepChat': 1,
          'b3Proactive': 1,
          'b4Maintenance': 1,
        },
        capabilityLimits: const {
          'chat': 1,
          'chatFast': 1,
          'vision': 1,
          'imageGen': 1,
          'tts': 1,
          'asr': 1,
          'embedding': 1,
        },
        offsetMinutes: 480,
      );
      request = requests.single;
      expect(request.$1, 'PUT');
      expect(request.$2, Routes.aiBudget.replaceFirst('{aiId}', 'profile'));
    },
  );

  test('invalid inputs never issue a request', () async {
    await expectLater(
      api.createProvider(
        name: 'P',
        baseUrl: 'ftp://bad',
        apiKey: 'k',
        capabilities: {'chat'},
      ),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      api.createProvider(
        name: 'P',
        baseUrl: 'https://ok.example',
        apiKey: '',
        capabilities: {'chat'},
      ),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      api.initializePersona('profile', p0: {}, p1: {'a': 'b'}, p2: {'c': 'd'}),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      api.configureBudget(
        'profile',
        dailyTokens: 1,
        layerLimits: const {'b0Life': 1},
        capabilityLimits: const {'chat': 1},
        offsetMinutes: 0,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(requests, isEmpty);
  });

  test(
    'session-pinned chat binding sends one PUT and skips renewal on 401',
    () async {
      status = 401;
      responseJson = {'error': 'unauthenticated'};
      var renewals = 0;
      final pinned = HostConnection(
        connection.base,
        'fixture',
        onUnauthorized: () async {
          renewals++;
          return true;
        },
      );
      addTearDown(pinned.close);
      await expectLater(
        AiConfigWriteApi(pinned, retryAuthentication: false).setChatBinding(
          'profile',
          providerId: 'prov-1',
          model: 'fixture-model',
        ),
        throwsA(
          isA<HostRequestException>().having(
            (error) => error.failure.code,
            'code',
            FailureCode.unauthenticated,
          ),
        ),
      );
      expect(renewals, 0);
      expect(requests, hasLength(1));
      final (method, path, body) = requests.single;
      expect(
        (method, path),
        ('PUT', '/api/v1/ai-profiles/profile/bindings/chat'),
      );
      expect(body, {'providerId': 'prov-1', 'model': 'fixture-model'});
    },
  );

  test('bounded inherited 401 replays at most once', () async {
    final renewServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    renewServer.listen((request) async {
      await request.drain<void>();
      calls++;
      request.response.headers.contentType = ContentType.json;
      request.response.statusCode = calls == 1 ? 401 : 200;
      request.response.write(
        calls == 1 ? '{"error":"unauthenticated"}' : jsonEncode(providerJson()),
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
      final view = await AiConfigWriteApi(renewed).createProvider(
        name: 'P',
        baseUrl: 'https://provider.example/v1',
        apiKey: 'k',
        capabilities: {'chat'},
      );
      expect(view.id, 'prov-1');
      expect(calls, 2);
      expect(renewals, 1);
    } finally {
      await renewed.close();
      await renewServer.close(force: true);
    }
  });
}
