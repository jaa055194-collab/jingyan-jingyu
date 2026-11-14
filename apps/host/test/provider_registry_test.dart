import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/models/models_migrations.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/security/url_guard.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late ProviderRegistry a;
  late ProviderRegistry b;
  final clock = FakeClock(DateTime.utc(2026, 11, 13));
  final guard = UrlGuard(resolver: (_) async => [InternetAddress('8.8.8.8')]);
  final migrations = [...allMigrations, ...modelsMigrations];

  ProviderRegistry registry(String owner) => ProviderRegistry.forOwner(
    ownerId: owner,
    db: db,
    cipher: cipher,
    urlGuard: guard,
    clock: clock,
  );
  Future<Result<ProviderView>> create(
    ProviderRegistry target, {
    String baseUrl = 'https://models.example/v1',
    String apiKey = 'fixture-alpha-1234',
  }) => target.create(
    name: 'Example',
    baseUrl: baseUrl,
    apiKey: apiKey,
    capabilities: {ProviderCapability.chat, ProviderCapability.chatFast},
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('jingyu-provider-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: migrations,
    );
    cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
    a = registry('owner-a');
    b = registry('owner-b');
  });
  tearDown(() async {
    await db.close();
    cipher.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'migration creates only providers and survives restart with masked views',
    () async {
      final view = (await create(a)).value;
      expect(view.keyMask, '****1234');
      expect(view.capabilities, {
        ProviderCapability.chat,
        ProviderCapability.chatFast,
      });
      final encoded = jsonEncode(view.toJson());
      expect(encoded, isNot(contains('fixture-alpha')));
      expect(encoded, isNot(contains('encrypted_key')));
      expect(encoded, isNot(contains('api_key')));
      final stored = (await db.query(
        'SELECT * FROM providers WHERE owner_id = ? AND id = ?',
        ['owner-a', view.id],
      )).single;
      expect(stored['encrypted_key'], startsWith('v1:'));
      expect(stored.values, isNot(contains('fixture-alpha-1234')));
      expect(encoded, isNot(contains(stored['encrypted_key'] as String)));
      expect(
        (await a.credentialForGateway(view.id)).value.apiKey,
        'fixture-alpha-1234',
      );
      expect(
        (await a.credentialForGateway(view.id)).toString(),
        isNot(contains('fixture-alpha')),
      );
      expect(await db.schemaVersion(), 500);
      expect(
        (await db.query(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        )).map((r) => r['name']),
        ['audit_log', 'key_store', 'providers', 'schema_migrations'],
      );
      await db.close();
      cipher.dispose();
      cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
      db = await SqliteDatabase.open(
        '${directory.path}/host.sqlite',
        migrations: migrations,
      );
      a = registry('owner-a');
      expect((await a.get(view.id)).value.keyMask, '****1234');
      expect(
        (await a.credentialForGateway(view.id)).value.apiKey,
        'fixture-alpha-1234',
      );
      expect(
        (await db.query(
          'SELECT version FROM schema_migrations WHERE version = ?',
          [500],
        )).length,
        1,
      );
    },
  );

  test(
    'every CRUD and gateway access isolates owners including hostile IDs',
    () async {
      final av = (await create(a)).value;
      final bv = (await create(b, apiKey: 'fixture-beta-5678')).value;
      expect((await a.list()).value.map((v) => v.id), [av.id]);
      expect((await b.list()).value.map((v) => v.id), [bv.id]);
      for (final id in [av.id, "' OR 1=1 --"]) {
        expect((await b.get(id)).failureOrNull?.code, FailureCode.notFound);
        expect(
          (await b.update(id, name: 'stolen')).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect((await b.delete(id)).failureOrNull?.code, FailureCode.notFound);
        expect(
          (await b.credentialForGateway(id)).failureOrNull?.code,
          FailureCode.notFound,
        );
      }
      expect((await a.get(av.id)).value.name, 'Example');
      expect(
        (await b.credentialForGateway(bv.id)).value.apiKey,
        'fixture-beta-5678',
      );
      expect((await a.delete(av.id)).isOk, isTrue);
      expect((await a.delete(av.id)).failureOrNull?.code, FailureCode.notFound);
      expect((await b.get(bv.id)).isOk, isTrue);
    },
  );

  test(
    'URL rejection never persists or silently strips unsafe URL components',
    () async {
      final view = (await create(a)).value;
      for (final raw in [
        'http://localhost/v1',
        'http://127.0.0.1/v1',
        'http://10.0.0.1/v1',
        'ftp://models.example/v1',
        'https://models.example/v1?key=secret',
        'https://models.example/v1#fragment',
        'https://user:password@models.example/v1',
        'https://models.example/v1?',
        'https://models.example/v1#',
        'https://models.example/v1\n',
      ]) {
        expect((await create(a, baseUrl: raw)).isErr, isTrue, reason: raw);
        expect(
          (await a.update(view.id, baseUrl: raw)).isErr,
          isTrue,
          reason: raw,
        );
        expect(
          (await a.get(view.id)).value.baseUrl,
          'https://models.example/v1',
        );
      }
      expect((await a.list()).value.length, 1);
      final privateDns = ProviderRegistry.forOwner(
        ownerId: 'owner-a',
        db: db,
        cipher: cipher,
        urlGuard: UrlGuard(
          resolver: (_) async => [InternetAddress('10.0.0.2')],
        ),
        clock: clock,
      );
      expect(
        (await create(privateDns)).failureOrNull?.code,
        FailureCode.forbidden,
      );
      expect(
        (await create(a, baseUrl: 'http://models.example/v1')).isOk,
        isTrue,
      );
    },
  );

  test(
    'updates keep omitted key, reject mask input and rotate real credentials',
    () async {
      final view = (await create(a)).value;
      final changed = await a.update(
        view.id,
        name: 'Renamed',
        baseUrl: 'https://next.example/v2',
        capabilities: {
          ProviderCapability.vision,
          ProviderCapability.imageGen,
          ProviderCapability.tts,
          ProviderCapability.asr,
          ProviderCapability.embedding,
        },
      );
      expect(changed.value.name, 'Renamed');
      expect(changed.value.capabilities.length, 5);
      expect(
        (await a.credentialForGateway(view.id)).value.apiKey,
        'fixture-alpha-1234',
      );
      for (final invalid in [
        '',
        '  ',
        view.keyMask,
        '\u2022\u2022\u2022\u20221234',
        'sk-key\r\nheader',
      ]) {
        expect(
          (await a.update(view.id, apiKey: invalid)).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
        expect(
          (await create(a, apiKey: invalid)).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
      final rotated = (await a.update(
        view.id,
        apiKey: 'fixture-rotated-9999',
      )).value;
      expect(rotated.keyMask, '****9999');
      expect(
        (await a.credentialForGateway(view.id)).value.apiKey,
        'fixture-rotated-9999',
      );
      expect(
        jsonEncode((await a.list()).value.map((v) => v.toJson()).toList()),
        isNot(contains('fixture-rotated')),
      );
    },
  );

  test(
    'disable preserves record and refuses gateway use until explicitly enabled',
    () async {
      final view = (await create(a)).value;
      expect((await a.update(view.id, enabled: false)).value.enabled, isFalse);
      expect((await a.get(view.id)).value.id, view.id);
      expect(
        (await a.credentialForGateway(view.id)).failureOrNull?.code,
        FailureCode.modelUnavailable,
      );
      await a.update(view.id, enabled: true);
      expect(
        (await a.credentialForGateway(view.id)).value.apiKey,
        'fixture-alpha-1234',
      );
    },
  );

  test(
    'AAD rejects ciphertext transplanted across provider rows and owners',
    () async {
      final first = (await create(a)).value;
      final second = (await create(a, apiKey: 'fixture-second-5678')).value;
      final otherOwner = (await create(b, apiKey: 'fixture-other-7777')).value;
      final sealed = (await db.query(
        'SELECT encrypted_key FROM providers WHERE owner_id = ? AND id = ?',
        ['owner-a', first.id],
      )).single['encrypted_key'];
      expect(
        cipher
            .decrypt(sealed as String, aad: 'owner-a:${first.id}:api_key')
            .value,
        'fixture-alpha-1234',
      );
      for (final (owner, id, target) in [
        ('owner-a', second.id, a),
        ('owner-b', otherOwner.id, b),
      ]) {
        await db.execute(
          'UPDATE providers SET encrypted_key = ? WHERE owner_id = ? AND id = ?',
          [sealed, owner, id],
        );
        final result = await target.credentialForGateway(id);
        expect(result.isErr, isTrue);
        expect(result.toString(), isNot(contains('fixture-alpha')));
      }
      await db.execute(
        'INSERT INTO providers (owner_id, id, name, base_url, encrypted_key, key_mask, enabled, capabilities) SELECT ?, id, name, base_url, encrypted_key, key_mask, enabled, capabilities FROM providers WHERE owner_id = ? AND id = ?',
        ['owner-b', 'owner-a', first.id],
      );
      expect((await b.get(first.id)).isOk, isTrue);
      expect((await b.credentialForGateway(first.id)).isErr, isTrue);
      expect((await a.credentialForGateway(first.id)).isOk, isTrue);
    },
  );

  test(
    'provider deletion reports a safe conflict while model bindings reference it',
    () async {
      final view = (await create(a)).value;
      await db.execute(
        'CREATE TABLE model_bindings (owner_id TEXT NOT NULL, provider_id TEXT NOT NULL, FOREIGN KEY(owner_id, provider_id) REFERENCES providers(owner_id, id) ON DELETE RESTRICT)',
      );
      await db.execute('INSERT INTO model_bindings VALUES (?, ?)', [
        'owner-a',
        view.id,
      ]);
      final result = await a.delete(view.id);
      expect(result.failureOrNull?.code, FailureCode.conflict);
      expect((await a.get(view.id)).isOk, isTrue);
      expect(
        (await b.delete(view.id)).failureOrNull?.code,
        FailureCode.notFound,
      );
      await db.execute('DELETE FROM model_bindings WHERE owner_id = ?', [
        'owner-a',
      ]);
      expect((await a.delete(view.id)).isOk, isTrue);
    },
  );

  test(
    'invalid empty scope and names fail safely and short keys never echo fully',
    () async {
      expect(() => registry(''), throwsFormatException);
      expect(
        (await a.create(
          name: ' ',
          baseUrl: 'https://models.example/v1',
          apiKey: 'secret-key',
          capabilities: {ProviderCapability.chat},
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      final short = (await create(a, apiKey: 'abc')).value;
      expect(short.keyMask, '****');
      expect(jsonEncode(short.toJson()), isNot(contains('abc')));
    },
  );
}
