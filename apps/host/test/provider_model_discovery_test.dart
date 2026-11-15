import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/models/models_migrations.dart';
import 'package:jingyu_host/src/models/openai_chat_adapter.dart';
import 'package:jingyu_host/src/models/provider_model_discovery.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/security/guarded_http.dart';
import 'package:jingyu_host/src/security/url_guard.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  const secret = 'sk-fixture-secret-value';
  const baseUrl = 'https://models.example/v1';
  final clock = FakeClock(DateTime.utc(2026, 11, 16));

  ProviderRegistry registry(String owner, {UrlGuard? urlGuard}) =>
      ProviderRegistry.forOwner(
        ownerId: owner,
        db: db,
        cipher: cipher,
        urlGuard:
            urlGuard ??
            UrlGuard(resolver: (_) async => [InternetAddress('8.8.8.8')]),
        clock: clock,
      );

  Future<String> saveProvider(
    ProviderRegistry target, {
    String url = baseUrl,
    String key = secret,
    bool enabled = true,
  }) => target
      .create(
        name: 'Fixture',
        baseUrl: url,
        apiKey: key,
        capabilities: {ProviderCapability.chat},
        enabled: enabled,
      )
      .then((result) => result.value.id);

  ProviderModelDiscovery discovery(
    String owner,
    GuardedChatRequest request, {
    UrlGuard? urlGuard,
  }) => ProviderModelDiscovery.forOwner(
    ownerId: owner,
    db: db,
    cipher: cipher,
    urlGuard:
        urlGuard ??
        UrlGuard(resolver: (_) async => [InternetAddress('8.8.8.8')]),
    clock: clock,
    request: request,
  );

  GuardedChatRequest respond(
    Object? payload, {
    int statusCode = 200,
    List<Map<String, Object?>>? calls,
  }) =>
      (
        String method,
        Uri uri, {
        Map<String, String> headers = const {},
        List<int>? body,
      }) async {
        calls?.add({'method': method, 'uri': uri, 'headers': headers});
        return Ok(
          GuardedResponse(
            statusCode: statusCode,
            headers: const {},
            body: utf8.encode(
              payload is String ? payload : jsonEncode(payload),
            ),
          ),
        );
      };

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('provider-discovery-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...modelsMigrations],
    );
    cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
  });

  tearDown(() async {
    cipher.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'uses saved provider URL and credential for one guarded model catalog request',
    () async {
      final providerId = await saveProvider(registry('owner-a'));
      final calls = <Map<String, Object?>>[];
      final service = discovery('owner-a', respond({'data': []}, calls: calls));

      final models = await service.discover(providerId);
      expect(models.isOk, isTrue);
      expect(models.value, isEmpty);
      expect(calls, hasLength(1));
      expect(calls.single['method'], 'GET');
      expect(
        calls.single['uri'].toString(),
        'https://models.example/v1/models',
      );
      expect(
        (calls.single['headers'] as Map)['authorization'],
        'Bearer $secret',
      );
    },
  );

  test(
    'saved provider base URL path, trailing slash, or bare host joins /models',
    () async {
      for (final pair in <(String, String)>[
        ('https://models.example/v1', 'https://models.example/v1/models'),
        ('https://models.example/v1/', 'https://models.example/v1/models'),
        ('https://models.example', 'https://models.example/models'),
        ('https://models.example/', 'https://models.example/models'),
      ]) {
        final providerId = await saveProvider(
          registry('owner-a'),
          url: pair.$1,
        );
        final calls = <Map<String, Object?>>[];
        final service = discovery(
          'owner-a',
          respond({'data': []}, calls: calls),
        );

        expect(
          (await service.discover(providerId)).isOk,
          isTrue,
          reason: pair.$1,
        );
        expect(calls.single['uri'].toString(), pair.$2, reason: pair.$1);
      }
    },
  );

  test('normalizes ids in first-seen order without duplicates', () async {
    final providerId = await saveProvider(registry('owner-a'));
    final service = discovery(
      'owner-a',
      respond({
        'data': [
          {'id': 'zeta'},
          {'id': 'alpha'},
          {'id': 'zeta'},
        ],
      }),
    );

    expect((await service.discover(providerId)).value, ['zeta', 'alpha']);
  });

  test('requires a bounded OpenAI style data catalog and safe ids', () async {
    final providerId = await saveProvider(registry('owner-a'));
    for (final payload in <Object?>[
      {'data': 'list'},
      <Object?>[],
      {
        'data': [1],
      },
      {
        'data': [
          {'object': 'model'},
        ],
      },
      {
        'data': [
          {'id': '  '},
        ],
      },
      {
        'data': [
          {'id': 7},
        ],
      },
      {
        'data': [
          {'id': ' padded'},
        ],
      },
      {
        'data': [
          {'id': 'x' * 257},
        ],
      },
      {
        'data': [
          {'id': 'bad\u0001id'},
        ],
      },
      {
        'data': List.generate(1001, (i) => {'id': 'model-$i'}),
      },
    ]) {
      final service = discovery('owner-a', respond(payload));
      expect(
        (await service.discover(providerId)).failureOrNull?.code,
        FailureCode.modelUnavailable,
        reason: '$payload',
      );
    }

    final emptyService = discovery(
      'owner-a',
      respond({'data': [], 'object': 'private-upstream-metadata'}),
    );
    expect((await emptyService.discover(providerId)).value, isEmpty);
  });

  test('rejects C1 control characters inside discovered model ids', () async {
    final providerId = await saveProvider(registry('owner-a'));
    final service = discovery('owner-a', respond({
      'data': [
        {'id': 'model\u0085private'},
      ],
    }));
    final result = await service.discover(providerId);
    expect(result.failureOrNull?.code, FailureCode.modelUnavailable);
  });

  test('rejects echoed credential ids including embedded ids', () async {
    final providerId = await saveProvider(registry('owner-a'));
    for (final id in [secret, 'model-$secret-extra']) {
      final service = discovery(
        'owner-a',
        respond({
          'data': [
            {'id': id},
          ],
        }),
      );
      expect(
        (await service.discover(providerId)).failureOrNull?.code,
        FailureCode.modelUnavailable,
        reason: id,
      );
    }
  });

  test(
    'normalizes provider status and transport failures without exposing raw detail',
    () async {
      final providerId = await saveProvider(registry('owner-a'));
      final cases = <(int, FailureCode)>[
        (401, FailureCode.forbidden),
        (403, FailureCode.forbidden),
        (429, FailureCode.rateLimited),
        (400, FailureCode.modelUnavailable),
        (500, FailureCode.modelUnavailable),
        (302, FailureCode.forbidden),
      ];
      for (final entry in cases) {
        final service = discovery(
          'owner-a',
          respond('private-upstream-error-body', statusCode: entry.$1),
        );
        final failure = (await service.discover(providerId)).failureOrNull;
        expect(failure?.code, entry.$2, reason: '${entry.$1}');
        expect(
          failure!.message,
          isNot(contains('private-upstream-error-body')),
        );
      }

      final thrown = discovery(
        'owner-a',
        (
          String method,
          Uri uri, {
          Map<String, String> headers = const {},
          List<int>? body,
        }) async => throw StateError('raw upstream body $secret'),
      );
      final failure = (await thrown.discover(providerId)).failureOrNull;
      expect(failure?.code, FailureCode.modelUnavailable);
      expect(failure!.message, isNot(contains(secret)));
    },
  );

  test(
    'refuses owner-mismatched or disabled provider without any request',
    () async {
      final providerId = await saveProvider(registry('owner-a'));
      final disabledId = await saveProvider(
        registry('owner-a'),
        enabled: false,
      );
      final calls = <Map<String, Object?>>[];
      final foreign = discovery('owner-b', respond({'data': []}, calls: calls));
      final disabled = discovery(
        'owner-a',
        respond({'data': []}, calls: calls),
      );

      expect(
        (await foreign.discover(providerId)).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await disabled.discover(disabledId)).failureOrNull?.code,
        FailureCode.modelUnavailable,
      );
      expect(calls, isEmpty);
    },
  );

  test('unsafe saved URL fails before any provider request', () async {
    final providerId = await saveProvider(registry('owner-a'));
    final calls = <Map<String, Object?>>[];
    final unsafeGuard = UrlGuard(
      resolver: (_) async => [InternetAddress('127.0.0.1')],
    );
    final service = ProviderModelDiscovery.forOwner(
      ownerId: 'owner-a',
      db: db,
      cipher: cipher,
      urlGuard: unsafeGuard,
      clock: clock,
      request: respond({'data': []}, calls: calls),
    );

    final failure = (await service.discover(providerId)).failureOrNull;
    expect(failure?.code, FailureCode.forbidden);
    expect(calls, isEmpty);
  });

  test('corrupt stored credential fails safely without any request', () async {
    final providerId = await saveProvider(registry('owner-a'));
    await db.execute('UPDATE providers SET encrypted_key = ? WHERE id = ?', [
      'v1:not-valid-ciphertext',
      providerId,
    ]);
    final calls = <Map<String, Object?>>[];
    final service = discovery('owner-a', respond({'data': []}, calls: calls));

    final failure = (await service.discover(providerId)).failureOrNull;
    expect(failure?.code, FailureCode.internal);
    expect(failure!.message, isNot(contains('not-valid-ciphertext')));
    expect(calls, isEmpty);
  });

  test(
    'discovery preserves saved provider rows and accepts exact catalog bounds',
    () async {
      final providerId = await saveProvider(registry('owner-a'));
      final before = await db.query('SELECT * FROM providers ORDER BY id');
      final ids = ['x' * 256, for (var i = 1; i < 1000; i++) 'model-$i'];
      final service = discovery(
        'owner-a',
        respond({
          'data': [
            for (final id in ids) {'id': id},
          ],
        }),
      );
      final result = await service.discover(providerId);
      expect(result.isOk, isTrue);
      expect(result.value, ids);
      expect(await db.query('SELECT * FROM providers ORDER BY id'), before);
      expect(await db.query('SELECT * FROM audit_log'), isEmpty);
    },
  );

  test(
    'normalizes returned transport failures without leaking details',
    () async {
      final providerId = await saveProvider(registry('owner-a'));
      for (final code in [FailureCode.forbidden, FailureCode.unavailable]) {
        final service = discovery(
          'owner-a',
          (
            String method,
            Uri uri, {
            Map<String, String> headers = const {},
            List<int>? body,
          }) async =>
              err(code, 'private upstream $secret', {'api_key': secret}),
        );
        final result = await service.discover(providerId);
        expect(
          result.failureOrNull?.code,
          code == FailureCode.forbidden ? code : FailureCode.modelUnavailable,
        );
        expect(result.toString(), isNot(contains(secret)));
        expect(result.failureOrNull?.details, isEmpty);
      }
    },
  );

  test('bounded response body is enforced before parsing', () async {
    final providerId = await saveProvider(registry('owner-a'));
    final huge = 'x' * (4 * 1024 * 1024 + 1);
    final calls = <Map<String, Object?>>[];
    final service = discovery('owner-a', respond(huge, calls: calls));

    final failure = (await service.discover(providerId)).failureOrNull;
    expect(failure?.code, FailureCode.modelUnavailable);
    expect(calls, hasLength(1));
  });
}
