import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

const _profile = 'test-private-profile';
const _otherProfile = 'second-private-profile';
const _base = '/api/v1/ai-profiles';
const _path = '$_base/$_profile/android-private-chat';
const _user = '  Synthetic user text にほんご\n';
const _assistant = 'Synthetic assistant reply 🐋\n  ';
const _append = {
  'exchangeId': 'exchange_1',
  'user': _user,
  'assistant': _assistant,
};
const _emptyPage = {'items': <Object?>[], 'hasMore': false};

void main() {
  late Directory data;
  late Host host;
  late FakeClock clock;
  late Database db;
  late AccountId owner, foreignAdmin, ai;
  late ({String bearer, DeviceId id, String refresh}) ownerDevice;
  late String foreignBearer;
  late HttpClient http;
  late HttpServer server;
  final errorLog = <String>[];
  const secret = 'synthetic-test-account-credentials';

  // Only the authenticator is replaced in stale-principal tests, at the exact
  // seam between the real initial authentication and route handler execution.
  Pipeline checkedAfterAuthentication(Future<void> Function() change) =>
      Pipeline(
        router: host.registry.router,
        authenticate: (request) async {
          final principal = await host.pipeline.authenticate(request);
          if (principal != null) await change();
          return principal;
        },
        onError: (error, _, _) => errorLog.add(error.toString()),
      );

  Future<({int code, Object? json, String? cacheControl})> call(
    String method, {
    String path = _path,
    String? bearer,
    Object? body,
    String? malformedJson,
    HttpServer? through,
    bool anonymous = false,
  }) async {
    final port = (through ?? server).port;
    final request = await http.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    if (!anonymous) {
      request.headers.set(
        'authorization',
        'Bearer ${bearer ?? ownerDevice.bearer}',
      );
    }
    if (body != null || malformedJson != null) {
      request.headers.contentType = ContentType.json;
      request.write(malformedJson ?? jsonEncode(body));
    }
    final response = await request.close();
    return (
      code: response.statusCode,
      json: jsonDecode(await utf8.decoder.bind(response).join()),
      cacheControl: response.headers.value('cache-control'),
    );
  }

  Future<HttpServer> start(Pipeline pipeline) async {
    final fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = serve(fixture, pipeline);
    addTearDown(() async {
      await fixture.close(force: true);
      await serving;
    });
    return fixture;
  }

  setUpAll(() async {
    data = await Directory.systemTemp.createTemp('jingyu-private-chat-');
    clock = FakeClock(DateTime.utc(2026, 11));
    host = await buildHost(
      clock: clock,
      config: HostConfig(dataDir: data.path),
      onError: (error, _) => errorLog.add(error.toString()),
    );
    db = host.registry.services.get<Database>();
    foreignAdmin = (await host.auth.bootstrapAdmin(
      displayName: 'fixture admin',
      password: secret,
    )).value;
    foreignBearer = (await host.auth.login(
      foreignAdmin,
      secret,
      deviceName: 'fixture admin device',
    )).value.accessToken;
    final adminSession = (await host.auth.scope(foreignBearer)).value;
    owner = (await adminSession.accounts.createHuman(
      displayName: 'fixture owner',
      password: secret,
    )).value;
    final device = (await host.auth.login(
      owner,
      secret,
      deviceName: 'fixture owner device',
    )).value;
    ownerDevice = (
      bearer: device.accessToken,
      id: device.deviceId,
      refresh: device.refreshToken,
    );
    final ownerSession = (await host.auth.scope(ownerDevice.bearer)).value;
    Future<AccountId> register(String name, String profileId) async {
      final ai = (await ownerSession.accounts.createAi(
        operator: owner,
        displayName: name,
      )).value;
      await db.execute('INSERT INTO ai_profile(id, account_id) VALUES (?, ?)', [
        profileId,
        ai.value,
      ]);
      return ai;
    }

    ai = await register('fixture AI', _profile);
    await register('other AI', _otherProfile);
    http = HttpClient()..findProxy = (_) => 'DIRECT';
    server = await start(host.pipeline);
  });

  tearDownAll(() async {
    http.close(force: true);
    await host.shutdown();
    await data.delete(recursive: true);
  });

  setUp(() async {
    // Reset only our isolated fixture table; absence is allowed here so red
    // tests see the missing endpoint, not failure in setup.
    if ((await db.query(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name='android_private_chat_exchanges'",
    )).isNotEmpty) {
      await db.execute('DELETE FROM android_private_chat_exchanges');
    }
    errorLog.clear();
  });

  test(
    'owner push atomically stores both exact texts; no ordinary-chat writes',
    () async {
      const sideEffectTables = [
        'direct_conversations',
        'owner_ai_direct_grants',
        'messages',
        'message_heads',
        'message_acks',
        'message_search_tokens',
        'owner_reply_attempts',
        'owner_ai_direct_sources',
        'encrypted_memory',
        'owner_auto_memory_sources',
        'usage_ledger',
      ];
      Future<List<int>> counts() async => [
        for (final table in sideEffectTables)
          (await db.query('SELECT count(*) AS n FROM $table')).single['n']
              as int,
      ];
      final before = await counts();
      final initial = await call('GET');
      expect([initial.code, initial.json], [200, _emptyPage]);
      final posted = await call('POST', body: _append);
      expect(
        [posted.code, posted.json],
        [
          200,
          {'seq': 1},
        ],
      );
      final page = await call('GET');
      expect(page.code, 200);
      expect(page.cacheControl, 'no-store');
      expect(page.json, {
        'items': [
          {'seq': 1, ..._append},
        ],
        'hasMore': false,
      });
      expect(await counts(), before);
      expect(
        (await db.query('SELECT * FROM audit_log')).toString(),
        isNot(contains('Synthetic user text')),
      );
      expect(errorLog, isEmpty);
      final stored = await db.query(
        'SELECT * FROM android_private_chat_exchanges',
      );
      expect(stored, hasLength(1));
      expect(stored.single['owner_id'], owner.value);
      expect(stored.single['encrypted_payload'], startsWith('v1:'));
      for (final suffix in ['', '-wal']) {
        final file = File('${data.path}/host.sqlite$suffix');
        if (!await file.exists()) continue;
        final disk = latin1.decode(await file.readAsBytes());
        expect(disk, isNot(contains('Synthetic user text')));
        expect(disk, isNot(contains('Synthetic assistant reply')));
      }
    },
  );

  test(
    'concurrent exact retries have one stable receipt; changed text conflicts',
    () async {
      final retries = await Future.wait(
        List.generate(3, (_) => call('POST', body: _append)),
      );
      for (final retry in retries) {
        expect(
          [retry.code, retry.json],
          [
            200,
            {'seq': 1},
          ],
        );
      }
      for (final field in ['user', 'assistant']) {
        final conflict = await call(
          'POST',
          body: {..._append, field: ' $field changed '},
        );
        expect(
          [conflict.code, conflict.json],
          [
            409,
            {'error': 'conflict'},
          ],
        );
      }
      final next = await call(
        'POST',
        body: {..._append, 'exchangeId': 'exchange_2'},
      );
      expect(next.json, {'seq': 2});
      expect((await call('GET')).json, {
        'items': [
          {'seq': 1, ..._append},
          {'seq': 2, ..._append, 'exchangeId': 'exchange_2'},
        ],
        'hasMore': false,
      });
    },
  );

  test(
    'bounded cursor pages, distinct local sequence for each profile',
    () async {
      for (var n = 1; n <= 17; n++) {
        final exchange = await call(
          'POST',
          body: {..._append, 'exchangeId': 'exchange_$n'},
        );
        expect(
          [exchange.code, exchange.json],
          [
            200,
            {'seq': n},
          ],
        );
      }
      final otherPath = '$_base/$_otherProfile/android-private-chat';
      final other = await call('POST', path: otherPath, body: _append);
      expect(
        [other.code, other.json],
        [
          200,
          {'seq': 1},
        ],
      );
      final first = await call('GET', path: '$_path?after=0');
      expect(first.json, {
        'items': [
          for (var n = 1; n <= 16; n++)
            {'seq': n, ..._append, 'exchangeId': 'exchange_$n'},
        ],
        'hasMore': true,
      });
      expect((await call('GET', path: '$_path?after=16')).json, {
        'items': [
          {'seq': 17, ..._append, 'exchangeId': 'exchange_17'},
        ],
        'hasMore': false,
      });
      expect((await call('GET', path: '$_path?after=17')).json, _emptyPage);
    },
  );

  test(
    'foreign admin, missing or wrong identity cannot read or push',
    () async {
      expect((await call('POST', body: _append)).code, 200);
      for (final (path, bearer) in [
        (_path, foreignBearer),
        ('$_base/absent/android-private-chat', ownerDevice.bearer),
        ('$_base/${ai.value}/android-private-chat', ownerDevice.bearer),
      ]) {
        final read = await call('GET', path: path, bearer: bearer);
        final write = await call(
          'POST',
          path: path,
          bearer: bearer,
          body: {..._append, 'user': 'not mine'},
        );
        expect(
          [read.code, read.json],
          [
            404,
            {'error': 'not_found'},
          ],
        );
        expect(
          [write.code, write.json],
          [
            404,
            {'error': 'not_found'},
          ],
        );
      }
      expect((await call('GET', anonymous: true)).code, 401);
      expect((await call('DELETE')).code, 404);
    },
  );

  test(
    'active ownership is rechecked after authentication; transfer hides old rows',
    () async {
      expect((await call('POST', body: _append)).code, 200);
      final transferred = await start(
        checkedAfterAuthentication(() async {
          await db.execute(
            'UPDATE ai_operator SET operator_id = ? WHERE ai_id = ?',
            [foreignAdmin.value, ai.value],
          );
        }),
      );
      try {
        final write = await call('POST', through: transferred, body: _append);
        expect(
          [write.code, write.json],
          [
            404,
            {'error': 'not_found'},
          ],
        );
        expect((await call('GET')).code, 404);
        expect((await call('GET', bearer: foreignBearer)).json, _emptyPage);
        final newOwnerPost = await call(
          'POST',
          bearer: foreignBearer,
          body: {..._append, 'user': 'new owner text'},
        );
        expect(
          [newOwnerPost.code, newOwnerPost.json],
          [
            200,
            {'seq': 1},
          ],
        );
        expect((await call('GET', bearer: foreignBearer)).json, {
          'items': [
            {'seq': 1, ..._append, 'user': 'new owner text'},
          ],
          'hasMore': false,
        });
        await db.execute('UPDATE account SET disabled = 1 WHERE id = ?', [
          ai.value,
        ]);
        expect((await call('GET', bearer: foreignBearer)).code, 404);
        expect(
          (await call('POST', bearer: foreignBearer, body: _append)).code,
          404,
        );
      } finally {
        await db.execute('UPDATE account SET disabled = 0 WHERE id = ?', [
          ai.value,
        ]);
        await db.execute(
          'UPDATE ai_operator SET operator_id = ? WHERE ai_id = ?',
          [owner.value, ai.value],
        );
      }
      expect((await call('GET')).json, {
        'items': [
          {'seq': 1, ..._append},
        ],
        'hasMore': false,
      });
    },
  );

  test(
    'revocation and expiry after initial auth stop both read and write',
    () async {
      expect((await call('POST', body: _append)).code, 200);
      // Use another real device so the test can revoke it without disturbing the
      // primary fixture. The mutation occurs after it was authenticated.
      final extra = (await host.auth.login(
        owner,
        secret,
        deviceName: 'revoke fixture',
      )).value;
      final ownerSession = (await host.auth.scope(ownerDevice.bearer)).value;
      final revoked = await start(
        checkedAfterAuthentication(() async {
          expect(
            (await ownerSession.devices.revoke(owner, extra.deviceId)).isOk,
            isTrue,
          );
        }),
      );
      final denied = await call(
        'GET',
        through: revoked,
        bearer: extra.accessToken,
      );
      expect(
        [denied.code, denied.json],
        [
          401,
          {'error': 'unauthenticated'},
        ],
      );
      final expired = await start(
        checkedAfterAuthentication(() async {
          clock.advance(const Duration(hours: 1));
        }),
      );
      try {
        final post = await call(
          'POST',
          through: expired,
          body: {..._append, 'exchangeId': 'expired_write'},
        );
        expect(
          [post.code, post.json],
          [
            401,
            {'error': 'unauthenticated'},
          ],
        );
      } finally {
        clock.set(DateTime.utc(2026, 11));
      }
      expect((await call('GET')).json, {
        'items': [
          {'seq': 1, ..._append},
        ],
        'hasMore': false,
      });
    },
  );

  test(
    'a stale principal cannot use a different live device or account bearer',
    () async {
      final device = (await host.auth.login(
        owner,
        secret,
        deviceName: 'mismatch fixture',
      )).value;
      final cached = await start(
        Pipeline(
          router: host.registry.router,
          authenticate: (_) async =>
              Principal(accountId: owner.value, deviceId: ownerDevice.id.value),
        ),
      );
      for (final wrong in [device.accessToken, foreignBearer]) {
        final post = await call(
          'POST',
          through: cached,
          bearer: wrong,
          body: _append,
        );
        expect(
          [post.code, post.json],
          [
            401,
            {'error': 'unauthenticated'},
          ],
        );
      }
      expect((await call('GET')).json, _emptyPage);
      final session = (await host.auth.scope(ownerDevice.bearer)).value;
      await session.devices.revoke(owner, device.deviceId);
    },
  );

  test(
    'malformed and oversized values are rejected without a partial write',
    () async {
      for (final suffix in [
        '?after=-1',
        '?after=1.0',
        '?after=0x1',
        '?after=',
        '?after=9223372036854775808',
        '?limit=1',
      ]) {
        final invalid = await call('GET', path: '$_path$suffix');
        expect(
          [invalid.code, invalid.json],
          [
            400,
            {'error': 'invalid_argument'},
          ],
        );
      }
      for (final body in <Object?>[
        null,
        [],
        {},
        {..._append, 'exchangeId': 'not/a/valid/id'},
        {..._append, 'user': 7},
        {..._append, 'user': '\t \n'},
        {..._append, 'assistant': ''},
        {..._append, 'user': '中' * 1366},
        {..._append, 'assistant': '🦀' * 2049},
        for (final forbidden in [
          'api_key',
          'base_url',
          'persona',
          'settings',
          'ownerId',
          'messages',
        ])
          {..._append, forbidden: 'unexpected'},
      ]) {
        final invalid = await call('POST', body: body);
        expect(
          [invalid.code, invalid.json],
          [
            400,
            {'error': 'invalid_argument'},
          ],
        );
      }
      expect(
        (await call('POST', path: '$_path?after=0', body: _append)).code,
        400,
      );
      expect(
        (await call(
          'POST',
          malformedJson:
              r'{"exchangeId":"valid","user":"\ud800","assistant":"ok"}',
        )).code,
        400,
      );
      expect((await call('POST', malformedJson: '{"exchangeId":')).code, 400);
      expect(errorLog, isEmpty);
      expect((await call('GET')).json, _emptyPage);
      expect(
        (await call(
          'POST',
          body: {..._append, 'user': 'u' * 4096, 'assistant': '🐋' * 2048},
        )).json,
        {'seq': 1},
      );
    },
  );

  test(
    'swapped ciphertext cannot be listed or acknowledged as a valid replay',
    () async {
      expect((await call('POST', body: _append)).code, 200);
      expect(
        (await call(
          'POST',
          body: {..._append, 'exchangeId': 'another_exchange'},
        )).code,
        200,
      );
      final encrypted = (await db.query(
        'SELECT encrypted_payload FROM android_private_chat_exchanges WHERE seq = 2',
      )).single['encrypted_payload'];
      await db.execute(
        'UPDATE android_private_chat_exchanges SET encrypted_payload = ? WHERE seq = 1',
        [encrypted],
      );
      final page = await call('GET');
      final replay = await call('POST', body: _append);
      expect(
        [page.code, page.json],
        [
          500,
          {'error': 'internal'},
        ],
      );
      expect(
        [replay.code, replay.json],
        [
          500,
          {'error': 'internal'},
        ],
      );
      expect(errorLog, isEmpty);
    },
  );

  test(
    'deleting linked owner/profile/AI cannot silently delete transcripts',
    () async {
      expect((await call('POST', body: _append)).code, 200);
      for (final (sql, id) in [
        ('DELETE FROM ai_profile WHERE id = ?', _profile),
        ('DELETE FROM account WHERE id = ?', ai.value),
        ('DELETE FROM account WHERE id = ?', owner.value),
      ]) {
        await expectLater(
          db.execute(sql, [id]),
          throwsA(
            predicate((Object e) => e.toString().contains('FOREIGN KEY')),
          ),
        );
      }
      expect((await call('GET')).json, {
        'items': [
          {'seq': 1, ..._append},
        ],
        'hasMore': false,
      });
    },
  );
}
