import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/audit/audit_log.dart';
import 'package:jingyu_host/src/models/models_migrations.dart';
import 'package:jingyu_host/src/models/models_module.dart';
import 'package:jingyu_host/src/security/url_guard.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_audit_log.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late FakeClock clock;
  late Pipeline pipeline;
  const secret = 'route-test-key-9876';
  const url = 'https://provider.example/v1';

  Map<String, Object?> validBody() => {
    'name': 'Provider',
    'base_url': url,
    'api_key': secret,
    'capabilities': ['chat', 'chatFast', 'vision'],
  };
  String path(String id) =>
      Routes.modelProvider.replaceFirst('{providerId}', id);
  Future<HostResponse> request(
    String method, {
    String? account = 'alice',
    String? at,
    Object? body,
  }) => pipeline.handle(
    HostRequest(
      method: method,
      path: at ?? Routes.modelProviders,
      headers: {'test-account': ?account},
      body: body,
    ),
  );
  Future<String> create() async {
    final response = await request('POST', body: validBody());
    expect(response.status, 200);
    return (response.json as Map)['id'] as String;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('jingyu-model-routes-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...modelsMigrations],
    );
    cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
    clock = FakeClock(DateTime.utc(2026, 11, 13));
    final module = ModelsModule(
      db: db,
      cipher: cipher,
      urlGuard: UrlGuard(resolver: (_) async => [InternetAddress('8.8.8.8')]),
      clock: clock,
    );
    final services = HostServices()
      ..provide<AuditLog>(SqliteAuditLog(db), owner: 'system');
    await module.configure(services);
    final router = Router();
    module.mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: (request) async {
        final account = request.headers['test-account'];
        return account == null
            ? null
            : Principal(accountId: account, deviceId: 'test-device');
      },
    );
  });
  tearDown(() async {
    cipher.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  test('all provider routes require authentication before writing', () async {
    for (final method in ['GET', 'POST', 'PUT', 'DELETE']) {
      final at = method == 'PUT' || method == 'DELETE'
          ? path('missing')
          : Routes.modelProviders;
      expect(
        (await request(
          method,
          account: null,
          at: at,
          body: validBody(),
        )).status,
        401,
      );
    }
    expect(
      (await request('GET', account: null, at: path('missing'))).status,
      401,
    );
    expect(await db.query('SELECT * FROM providers'), isEmpty);
    expect(await db.query('SELECT * FROM audit_log'), isEmpty);
  });

  test(
    'CRUD returns safe views and writes only metadata audit entries',
    () async {
      final created = await request('POST', body: validBody());
      expect(created.status, 200);
      final view = created.json as Map;
      final id = view['id'] as String;
      expect(view, {
        'id': id,
        'name': 'Provider',
        'base_url': url,
        'key_mask': '****9876',
        'enabled': true,
        'capabilities': ['chat', 'chatFast', 'vision'],
      });
      expect((await request('GET')).json, [view]);
      expect((await request('GET', at: path(id))).json, view);
      final encrypted =
          (await db.query(
                'SELECT encrypted_key FROM providers',
              )).single['encrypted_key']
              as String;
      expect(encrypted, startsWith('v1:'));
      expect(encrypted, isNot(contains(secret)));
      expect(cipher.decrypt(encrypted, aad: 'alice:$id:api_key').value, secret);

      final update = await request(
        'PUT',
        at: path(id),
        body: {
          'name': 'Updated',
          'enabled': false,
          'capabilities': ['tts', 'asr'],
        },
      );
      expect(update.status, 200);
      expect(update.json, {
        'id': id,
        'name': 'Updated',
        'base_url': url,
        'key_mask': '****9876',
        'enabled': false,
        'capabilities': ['tts', 'asr'],
      });
      expect(
        (await db.query(
          'SELECT encrypted_key FROM providers',
        )).single['encrypted_key'],
        encrypted,
      );
      final rotated = await request(
        'PUT',
        at: path(id),
        body: {
          'api_key': 'route-rotated-1234',
          'base_url': 'https://other.example/v1',
        },
      );
      expect(rotated.status, 200);
      expect((rotated.json as Map)['key_mask'], '****1234');
      final deleted = await request('DELETE', at: path(id));
      expect(deleted.status, 200);
      expect(deleted.json, isNull);
      expect((await request('GET', at: path(id))).status, 404);
      expect((await request('GET')).json, isEmpty);
      final entries = await db.query('SELECT * FROM audit_log ORDER BY id');
      expect(entries.map((e) => e['action']).toList(), [
        'provider.create',
        'provider.update',
        'provider.update',
        'provider.delete',
      ]);
      for (final entry in entries) {
        expect(entry['actor_id'], 'alice');
        expect(entry['target_kind'], 'provider');
        expect(entry['target_id'], id);
        expect(entry['at'], '2026-11-13T00:00:00.000Z');
        expect(jsonDecode(entry['meta'] as String), isEmpty);
      }
      final audit = jsonEncode(entries);
      for (final forbidden in [
        secret,
        'route-rotated-1234',
        url,
        'api_key',
        'encrypted_key',
      ]) {
        expect(audit, isNot(contains(forbidden)));
      }
      expect(
        jsonEncode([created.json, update.json, rotated.json]),
        isNot(contains(secret)),
      );
      expect(jsonEncode(rotated.json), isNot(contains('route-rotated-1234')));
    },
  );

  test(
    'other accounts see 404 and cannot alter or delete owner rows',
    () async {
      final id = await create();
      expect((await request('GET', account: 'bob')).json, isEmpty);
      for (final method in ['GET', 'PUT', 'DELETE']) {
        expect(
          (await request(
            method,
            account: 'bob',
            at: path(id),
            body: {'name': 'Stolen'},
          )).status,
          404,
        );
      }
      expect(
        ((await request('GET', at: path(id))).json as Map)['name'],
        'Provider',
      );
      expect((await db.query('SELECT * FROM audit_log')).length, 1);
      for (final method in ['GET', 'PUT', 'DELETE']) {
        expect(
          (await request(
            method,
            at: path('missing'),
            body: {'name': 'Changed'},
          )).status,
          404,
        );
      }
    },
  );

  test(
    'create rejects owner injection unknown fields and invalid JSON types',
    () async {
      final invalid = <Object?>[
        null,
        [],
        'provider',
        {},
        {...validBody(), 'ownerId': 'bob'},
        {...validBody(), 'owner_id': 'bob'},
        {...validBody(), 'unknown': true},
        for (final field in ['name', 'base_url', 'api_key'])
          for (final value in [null, 7, true, []])
            {...validBody(), field: value},
        {...validBody(), 'enabled': null},
        {...validBody(), 'enabled': 1},
        {...validBody(), 'capabilities': null},
        {...validBody(), 'capabilities': 'chat'},
        {
          ...validBody(),
          'capabilities': ['unknown'],
        },
        {
          ...validBody(),
          'capabilities': ['chat.fast'],
        },
        {
          ...validBody(),
          'capabilities': [1],
        },
        {...validBody(), 'api_key': '****9876'},
        {...validBody(), 'name': ' '},
      ];
      for (final body in invalid) {
        expect(
          (await request('POST', body: body)).status,
          400,
          reason: 'invalid create input: $body',
        );
      }
      expect(await db.query('SELECT * FROM providers'), isEmpty);
      expect(await db.query('SELECT * FROM audit_log'), isEmpty);
    },
  );

  test(
    'update rejects owner injection and explicit null without success audit',
    () async {
      final id = await create();
      for (final body in <Object?>[
        null,
        [],
        'provider',
        {'ownerId': 'bob'},
        {'owner_id': 'bob'},
        {'unexpected': true},
        for (final field in [
          'name',
          'base_url',
          'api_key',
          'capabilities',
          'enabled',
        ])
          {field: null},
        {'name': 4},
        {'base_url': false},
        {'api_key': []},
        {'enabled': 'false'},
        {
          'capabilities': [false],
        },
        {
          'capabilities': ['bogus'],
        },
        {'api_key': '****9876'},
      ]) {
        expect(
          (await request('PUT', at: path(id), body: body)).status,
          400,
          reason: 'invalid update input: $body',
        );
      }
      expect((await db.query('SELECT * FROM audit_log')).length, 1);
      expect(
        ((await request('GET', at: path(id))).json as Map)['name'],
        'Provider',
      );
    },
  );

  test(
    'unsafe URL failures do not persist providers or successful audit',
    () async {
      for (final unsafe in ['http://localhost/v1', 'http://127.0.0.1/v1']) {
        expect(
          (await request(
            'POST',
            body: {...validBody(), 'base_url': unsafe},
          )).status,
          403,
        );
      }
      expect(await db.query('SELECT * FROM providers'), isEmpty);
      expect(await db.query('SELECT * FROM audit_log'), isEmpty);
      final id = await create();
      expect(
        (await request(
          'PUT',
          at: path(id),
          body: {'base_url': 'http://10.0.0.1/v1'},
        )).status,
        403,
      );
      expect((await db.query('SELECT * FROM audit_log')).length, 1);
      expect(
        ((await request('GET', at: path(id))).json as Map)['base_url'],
        url,
      );
    },
  );
}
