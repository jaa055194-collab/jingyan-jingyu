import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/owner_ai_direct_api.dart';
import 'package:client_flutter/net/owner_ai_readiness_api.dart';
import 'package:flutter_test/flutter_test.dart';

const _identityJson = {
  'profileId': 'profile',
  'accountId': 'ai-account',
  'ownerAccountId': 'owner',
};
Map<String, Object?> _persona() => {
  'aiId': 'profile',
  'version': 2,
  'locked': true,
  'layers': {
    'p0': {'name': 'private-persona'},
    'p1': {'tone': 'gentle'},
    'p2': {'mood': 'calm'},
  },
};
Map<String, Object?> _binding() => {
  'owner_id': 'owner',
  'ai_profile_id': 'profile',
  'capability': 'chat',
  'provider_id': 'provider',
  'model': 'model-v1',
};
Map<String, Object?> _budget() => {
  'dailyTokens': 100,
  'layerLimits': {
    'b0Life': 10,
    'b1FastBrain': 10,
    'b2DeepChat': 40,
    'b3Proactive': 20,
    'b4Maintenance': 20,
  },
  'capabilityLimits': {
    'chat': 60,
    'chatFast': 10,
    'vision': 10,
    'imageGen': 5,
    'tts': 5,
    'asr': 5,
    'embedding': 5,
  },
  'offsetMinutes': 480,
};
Map<String, Object?> _provider() => {
  'id': 'provider',
  'name': 'My provider',
  'base_url': 'https://provider.example/v1',
  'key_mask': '****abcd',
  'enabled': true,
  'capabilities': ['chat', 'chatFast'],
};

// Substitute only the transport failure boundary; target-stage failures still
// obtain their canonical identity through the real loopback HostConnection.
class _TlsFailureConnection extends HostConnection {
  _TlsFailureConnection(Uri base, this.failure, {required this.failIdentity})
    : super(base, 'fixture-token');
  final TlsException failure;
  final bool failIdentity;

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) {
    if (failIdentity || path.endsWith('/persona')) throw failure;
    return super.request(
      method,
      path,
      body: body,
      query: query,
      retryAuthentication: retryAuthentication,
      allowEmptySuccess: allowEmptySuccess,
    );
  }
}

void main() {
  late HttpServer server;
  late HostConnection connection;
  late OwnerAiReadinessApi api;
  late OwnedAiProfileIdentity identity;
  late List<(String, String, String?, String)> requests;
  late Object? identityPayload;
  late int identityStatus;
  late Object? payload;
  late int status;
  const profilePath = '/api/v1/ai-profiles/profile';

  setUp(() async {
    identity = OwnedAiProfileIdentity.fromJson(
      _identityJson,
      expectedAccountId: 'ai-account',
      expectedOwnerAccountId: 'owner',
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture-token',
    );
    api = OwnerAiReadinessApi(connection);
    requests = [];
    identityPayload = _identityJson;
    identityStatus = 200;
    payload = _persona();
    status = 200;
    server.listen((request) async {
      requests.add((
        request.method,
        request.uri.toString(),
        request.headers.value(HttpHeaders.authorizationHeader),
        await utf8.decoder.bind(request).join(),
      ));
      final checkingIdentity = request.uri.path == profilePath;
      request.response.statusCode = checkingIdentity ? identityStatus : status;
      request.response.write(
        jsonEncode(checkingIdentity ? identityPayload : payload),
      );
      await request.response.close();
    });
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  Future<ConfigurationRead<Object>> read(String item) async => switch (item) {
    'persona' => await api.readPersona(identity),
    'bindings' => await api.readBindings(identity),
    'budget' => await api.readBudget(identity),
    'provider' => await api.readProvider(identity, 'provider'),
    _ => throw StateError('unknown fixture'),
  };

  void expectGetOnly(String target) {
    expect(requests, [
      ('GET', profilePath, 'Bearer fixture-token', ''),
      ('GET', target, 'Bearer fixture-token', ''),
    ]);
  }

  test('persona reads current identity first and returns immutable exact card without status text leakage', () async {
    final result = await api.readPersona(identity);
    expect(result.status, ConfigurationReadStatus.configurationPresent);
    final card = result.value!;
    expect(card.aiProfileId, 'profile');
    expect(card.version, 2);
    expect(card.locked, true);
    expect(card.layers['p0'], {'name': 'private-persona'});
    expect(
      () => card.layers['p0']!['name'] = 'changed',
      throwsUnsupportedError,
    );
    expect(result.toString(), isNot(contains('private-persona')));
    expectGetOnly('$profilePath/persona');
  });
  test('bindings validate profile/owner and preserve no configuration inference beyond present list', () async {
    payload = [_binding()];
    final result = await api.readBindings(identity);
    expect(result.status, ConfigurationReadStatus.configurationPresent);
    expect(result.value!.single.providerId, 'provider');
    expect(result.value!.single.capability, 'chat');
    expect(() => result.value!.clear(), throwsUnsupportedError);
    expectGetOnly('$profilePath/bindings');
  });
  test('complete explicit budget validates limits and user offset without reading usage/admission', () async {
    payload = _budget();
    final result = await api.readBudget(identity);
    expect(result.status, ConfigurationReadStatus.configurationPresent);
    expect(result.value!.dailyTokens, 100);
    expect(result.value!.offsetMinutes, 480);
    expect(result.value!.layerLimits['b2DeepChat'], 40);
    expect(() => result.value!.layerLimits.clear(), throwsUnsupportedError);
    expectGetOnly('$profilePath/budget');
  });
  for (final mask in ['****', '****abcd']) {
    test(
      'provider safe metadata accepts actual host mask $mask and never discovers models',
      () async {
        payload = {..._provider(), 'key_mask': mask};
        final result = await api.readProvider(identity, 'provider');
        expect(result.status, ConfigurationReadStatus.configurationPresent);
        expect(result.value!.id, 'provider');
        expect(result.value!.keyMask, mask);
        expectGetOnly('/api/v1/model-providers/provider');
      },
    );
  }
  test('host-valid multiline persona and unicode key suffix/http metadata remain valid', () async {
    payload = {
      ..._persona(),
      'layers': {
        'p0': {'description': 'first line\nsecond line\tindented'},
        'p1': {'tone': 'gentle'},
        'p2': {'mood': 'calm'},
      },
    };
    expect(
      (await api.readPersona(identity)).status,
      ConfigurationReadStatus.configurationPresent,
    );
    payload = {
      ..._provider(),
      'key_mask': '****甲乙丙丁',
      'base_url': 'http://provider.example/v1',
      'enabled': false,
    };
    final provider = await api.readProvider(identity, 'provider');
    expect(provider.status, ConfigurationReadStatus.configurationPresent);
    expect(provider.value!.enabled, false);
  });

  test('empty bindings and explicit budget configurationRequired stay unconfigured not unknown', () async {
    payload = [];
    expect(
      (await api.readBindings(identity)).status,
      ConfigurationReadStatus.unconfigured,
    );
    payload = {'configurationRequired': true};
    expect(
      (await api.readBudget(identity)).status,
      ConfigurationReadStatus.unconfigured,
    );
  });
  for (final item in ['persona', 'bindings', 'budget', 'provider']) {
    test(
      '$item identity 404 is ownershipUnknown and stops before metadata request',
      () async {
        identityStatus = 404;
        identityPayload = {'error': 'not_found'};
        final result = await read(item);
        expect(result.status, ConfigurationReadStatus.ownershipUnknown);
        expect(result.value, isNull);
        expect(requests.length, 1);
      },
    );
    test(
      '$item foreign or stale resolved identity never reads metadata',
      () async {
        identityPayload = {..._identityJson, 'ownerAccountId': 'foreign-owner'};
        expect(
          (await read(item)).status,
          ConfigurationReadStatus.ownershipUnknown,
        );
        expect(requests.length, 1);
      },
    );
  }
  test('identity account/profile mismatch also fails closed', () async {
    for (final field in ['accountId', 'profileId']) {
      identityPayload = {..._identityJson, field: 'other-id'};
      expect(
        (await api.readPersona(identity)).status,
        ConfigurationReadStatus.ownershipUnknown,
      );
    }
    expect(requests.length, 2);
  });
  test(
    'persona missing only describes target 404, not durable ownership',
    () async {
      status = 404;
      payload = {'error': 'not_found'};
      final result = await api.readPersona(identity);
      expect(result.status, ConfigurationReadStatus.personaMissing);
      expect(result.value, isNull);
      expect(requests.length, 2);
    },
  );
  for (final item in ['bindings', 'budget', 'provider']) {
    test(
      '$item target404 is unknown, never configured/missing-success',
      () async {
        status = 404;
        payload = {'error': 'not_found'};
        expect((await read(item)).status, ConfigurationReadStatus.unknown);
      },
    );
  }
  for (final code in [401, 403, 503]) {
    test(
      'HTTP$code remains denied or unknown without body leakage or extra replay',
      () async {
        status = code;
        payload = {'error': 'private-secret-persona'};
        final result = await api.readPersona(identity);
        expect(
          result.status,
          code == 503
              ? ConfigurationReadStatus.unknown
              : ConfigurationReadStatus.denied,
        );
        expect(result.toString(), isNot(contains('private-secret')));
        expect(result.value, isNull);
        expect(requests.length, 2);
      },
    );
  }
  test(
    'persona requires exact layers/types/version/lock and profile context',
    () async {
      final bad = <Object?>[
        {..._persona(), 'aiId': 'foreign-profile'},
        {..._persona(), 'version': 0},
        {..._persona(), 'version': 1.0},
        {..._persona(), 'locked': 'true'},
        {
          ..._persona(),
          'layers': {
            'p0': {},
            'p1': {'x': 'v'},
            'p2': {'x': 'v'},
          },
        },
        {
          ..._persona(),
          'layers': {
            'p0': {'x': 'v'},
            'p1': {'x': null},
            'p2': {'x': 'v'},
          },
        },
        {
          ..._persona(),
          'layers': {
            'p0': {'x': 'v'},
            'p1': {'x': 'v'},
          },
        },
        {..._persona(), 'body': 'private-secret'},
      ];
      for (final value in bad) {
        payload = value;
        final result = await api.readPersona(identity);
        expect(result.status, ConfigurationReadStatus.unknown);
        expect(result.value, isNull);
        expect(result.toString(), isNot(contains('private-secret')));
      }
    },
  );
  test('bindings reject foreign scope, duplicates, unknown capability and unsafe models', () async {
    for (final value in <Object?>[
      [
        {..._binding(), 'owner_id': 'foreign-owner'},
      ],
      [
        {..._binding(), 'ai_profile_id': 'foreign-profile'},
      ],
      [_binding(), _binding()],
      [
        {..._binding(), 'capability': 'invented'},
      ],
      [
        {..._binding(), 'provider_id': 'bad/id'},
      ],
      [
        {..._binding(), 'model': ' bad '},
      ],
      [
        {..._binding(), 'api_key': 'private-secret'},
      ],
    ]) {
      payload = value;
      expect(
        (await api.readBindings(identity)).status,
        ConfigurationReadStatus.unknown,
      );
    }
  });
  test('budget rejects partial, negative, noninteger, excess sums and invalid offsets', () async {
    for (final value in <Object?>[
      {'configurationRequired': true, 'extra': 1},
      {'configurationRequired': false},
      {..._budget(), 'dailyTokens': -1},
      {..._budget(), 'dailyTokens': 1.0},
      {
        ..._budget(),
        'layerLimits': {'b0Life': 0},
      },
      {
        ..._budget(),
        'layerLimits': {...(_budget()['layerLimits'] as Map), 'b2DeepChat': -1},
      },
      {
        ..._budget(),
        'capabilityLimits': {
          ...(_budget()['capabilityLimits'] as Map),
          'chat': 101,
        },
      },
      {..._budget(), 'offsetMinutes': 841},
      {..._budget(), 'offsetMinutes': null},
    ]) {
      payload = value;
      expect(
        (await api.readBudget(identity)).status,
        ConfigurationReadStatus.unknown,
      );
    }
  });
  test(
    'zero budget is valid configuration metadata, not budget admission',
    () async {
      payload = {
        ..._budget(),
        'dailyTokens': 0,
        'layerLimits': {
          for (final key in (_budget()['layerLimits'] as Map).keys) key: 0,
        },
        'capabilityLimits': {
          for (final key in (_budget()['capabilityLimits'] as Map).keys) key: 0,
        },
        'offsetMinutes': -840,
      };
      expect(
        (await api.readBudget(identity)).status,
        ConfigurationReadStatus.configurationPresent,
      );
    },
  );
  test('provider rejects ID mismatch/raw key/unknown caps/malformed masked metadata', () async {
    for (final value in <Object?>[
      {..._provider(), 'id': 'different-provider'},
      {..._provider(), 'api_key': 'private-secret'},
      {..._provider(), 'key_mask': 'raw-private-secret'},
      {
        ..._provider(),
        'capabilities': ['chat', 'unknown'],
      },
      {
        ..._provider(),
        'capabilities': ['chat', 'chat'],
      },
      {..._provider(), 'enabled': 1},
      {..._provider(), 'base_url': 'https://user:private-secret@example.test'},
    ]) {
      payload = value;
      final result = await api.readProvider(identity, 'provider');
      expect(result.status, ConfigurationReadStatus.unknown);
      expect(result.value, isNull);
      expect(result.toString(), isNot(contains('private-secret')));
    }
  });
  for (final failIdentity in [true, false]) {
    for (final failure in <TlsException>[
      const HandshakeException('private-secret TLS handshake'),
      const CertificateException('private-secret certificate'),
    ]) {
      test(
        'TLS ${failure.runtimeType} at ${failIdentity ? 'identity' : 'target'} becomes safe unknown',
        () async {
          await connection.close();
          connection = _TlsFailureConnection(
            Uri.parse('http://127.0.0.1:${server.port}'),
            failure,
            failIdentity: failIdentity,
          );
          api = OwnerAiReadinessApi(connection);
          final result = await api.readPersona(identity);
          expect(result.status, ConfigurationReadStatus.unknown);
          expect(result.value, isNull);
          expect(result.toString(), isNot(contains('private-secret')));
          expect(requests.length, failIdentity ? 0 : 1);
        },
      );
    }
  }

  test(
    'invalid provider id is rejected before HTTP without reflecting input',
    () async {
      await expectLater(
        api.readProvider(identity, 'private/secret'),
        throwsA(
          predicate(
            (e) =>
                e is FormatException &&
                e.source == null &&
                !e.toString().contains('secret'),
          ),
        ),
      );
      expect(requests, isEmpty);
    },
  );
}
