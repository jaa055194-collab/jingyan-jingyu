import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/ai/memory/owner_reply_preferences.dart';
import 'package:jingyu_host/src/ai/memory/owner_reply_preferences_module.dart';
import 'package:jingyu_host/src/brain/owner_ai_direct_incoming.dart';
import 'package:jingyu_host/src/brain/owner_ai_direct_reply_observer.dart';
import 'package:jingyu_host/src/messages/accepted_message_observer.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/models/binding_matrix.dart';
import 'package:jingyu_host/src/models/model_runtime.dart';
import 'package:jingyu_host/src/models/openai_chat_adapter.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/models/stateless_owner_chat.dart';
import 'package:jingyu_host/src/security/guarded_http.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

// Literal wire path: catches a broken or missing route at the host boundary.
const _path = '/api/v1/ai-profiles/preference-profile/owner-reply-preferences';
const _direct = '/api/v1/ai-profiles/preference-profile/direct-conversation';
const _owner = 'preference-owner';
const _ai = 'preference-ai';
const _profile = 'preference-profile';
const _other = 'other-owner';

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());

  test(
    'never configured is a read-only default and cannot open consent',
    () async {
      expect(await f.ok('GET', _path), {
        'revision': 0,
        'enabled': false,
        'length': null,
        'format': null,
        'target': null,
      });
      expect(
        await f.db.query('SELECT * FROM owner_reply_preferences'),
        isEmpty,
      );
      expect(await f.db.query('SELECT * FROM owner_ai_direct_grants'), isEmpty);
      expect(await f.db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );

  test(
    'live human owner only; admin and AI have no delegated access',
    () async {
      expect((await f.call('GET', _path, actor: null)).status, 401);
      expect((await f.call('GET', _path, actor: _other)).status, 404);
      expect((await f.call('GET', _path, actor: _ai)).status, 404);
      expect(
        (await f.call('PUT', _path, actor: _other, body: f.payload())).status,
        404,
      );
      await f.db.execute('DELETE FROM device WHERE id=?', ['$_owner-device']);
      expect((await f.call('GET', _path)).status, 401);
    },
  );

  for (final change in ['revoke', 'rotate', 'expire']) {
    test(
      '$change after principal lookup cannot commit preference enable',
      () async {
        await f.openDirect();
        await f.bind();
        final token = await f.targetToken();
        final router = Router();
        final authenticate = DbAuthenticator(f.host.auth).call;
        // Narrow interposition at the old route-auth seam: use the real bearer
        // lookup, then change the live database before it returns the principal.
        OwnerReplyPreferencesModule(
          OwnerReplyPreferences(
            database: f.db,
            cipher: f.host.registry.services.get<ColumnCipher>(),
            clock: f.clock,
          ),
          (request) async {
            final principal = await authenticate(request);
            final device = '$_owner-device';
            switch (change) {
              case 'revoke':
                await f.db.execute('DELETE FROM device WHERE id=?', [device]);
              case 'rotate':
                await f.db.execute(
                  'UPDATE device SET access_hash=? WHERE id=?',
                  ['synthetic-different-access-hash', device],
                );
              case 'expire':
                await f.db.execute(
                  'UPDATE device SET access_expires=? WHERE id=?',
                  [f.clock.now().millisecondsSinceEpoch, device],
                );
            }
            return principal;
          },
        ).mount(router);
        final result =
            await Pipeline(router: router, authenticate: authenticate).handle(
              HostRequest(
                method: 'PUT',
                path: _path,
                headers: {'authorization': 'Bearer ${f.tokens[_owner]}'},
                body: f.payload(enabled: true, token: token),
              ),
            );
        expect(result.status, 401);
        expect(
          await f.db.query('SELECT * FROM owner_reply_preferences'),
          isEmpty,
        );
        expect(
          await f.db.query(
            "SELECT 1 FROM audit_log WHERE action='owner_reply_preferences.configure'",
          ),
          isEmpty,
        );
      },
    );
  }

  test(
    'existing settings routes are not alternative consent or a model trigger',
    () async {
      final directBefore = await f.openDirect();
      final provider = await f.bind();
      final target = (await f.ok('GET', _path))['target']! as Map;
      expect(
        target.keys,
        unorderedEquals(['providerId', 'model', 'origin', 'token']),
      );
      expect(target['providerId'], provider);
      expect(target['model'], 'fixture-model');
      expect(target['origin'], 'https://192.0.2.1');
      final saved = await f.ok(
        'PUT',
        _path,
        body: f.payload(enabled: true, token: target['token'] as String),
      );
      expect(saved, {
        'revision': 1,
        'enabled': true,
        'length': 'brief',
        'format': 'bullets',
        'target': target,
      });
      expect(await f.ok('GET', _direct), directBefore);
      expect(await f.db.query('SELECT * FROM messages'), isEmpty);
      expect(await f.db.query('SELECT * FROM usage_ledger'), isEmpty);
      final rows = await f.db.query('SELECT * FROM owner_reply_preferences');
      expect(rows, hasLength(1));
      final stored = jsonEncode(rows);
      for (final sentinel in ['brief', 'bullets', 'synthetic-fixture-only']) {
        expect(stored, isNot(contains(sentinel)));
      }
      final audit = jsonEncode(
        await f.db.query(
          "SELECT * FROM audit_log WHERE action='owner_reply_preferences.configure'",
        ),
      );
      expect(audit, contains('owner_reply_preferences.configure'));
      for (final sentinel in [
        'brief',
        'bullets',
        'synthetic-fixture-only',
        target['token']! as String,
      ]) {
        expect(audit, isNot(contains(sentinel)));
      }
    },
  );

  test(
    'rejects unknown fields, invalid choice and attempted opt-in without target',
    () async {
      for (final body in [
        {...f.payload(), 'text': 'outside the allowed categories'},
        {...f.payload(), 'length': 'unsafe arbitrary instructions'},
        {...f.payload(), 'format': true},
        {...f.payload(), 'expectedRevision': -1},
        {...f.payload(), 'expectedTargetToken': 'target-while-disabled'},
        {
          ...f.payload(enabled: true, token: 'missing'),
          'length': null,
          'format': null,
        },
      ]) {
        expect((await f.call('PUT', _path, body: body)).status, 400);
      }
      expect(
        (await f.call(
          'PUT',
          _path,
          body: f.payload(enabled: true, token: 'missing'),
        )).status,
        409,
      );
      expect(
        await f.db.query('SELECT * FROM owner_reply_preferences'),
        isEmpty,
      );
    },
  );

  test('CAS, explicit revoke and clearing survive restart', () async {
    await f.openDirect();
    await f.bind();
    await f.enable();
    expect((await f.call('PUT', _path, body: f.payload())).status, 409);
    await f.restart();
    expect((await f.ok('GET', _path))['enabled'], true);
    final off = await f.ok('PUT', _path, body: f.payload(revision: 1));
    expect(off['enabled'], false);
    expect(off['length'], 'brief');
    final cleared = await f.ok(
      'PUT',
      _path,
      body: f.payload(revision: 2, length: null, format: null),
    );
    expect(cleared['enabled'], false);
    expect(cleared['length'], isNull);
    expect(cleared['format'], isNull);
    await f.restart();
    expect(await f.ok('GET', _path), cleared);
  });

  test(
    'target CAS rejects an old offer even without a saved preference row',
    () async {
      await f.openDirect();
      final provider = await f.bind();
      final original = await f.targetToken();
      await f.changeProvider(provider, 'https://192.0.2.2/v2');
      await f.changeProvider(provider, 'https://192.0.2.1/v1');
      expect(await f.targetToken(), isNot(original));
      expect(
        (await f.call(
          'PUT',
          _path,
          body: f.payload(enabled: true, token: original),
        )).status,
        409,
      );
      expect(
        await f.db.query('SELECT * FROM owner_reply_preferences'),
        isEmpty,
      );
    },
  );

  for (final mutation in [
    'provider',
    'provider binding',
    'credential',
    'binding',
    'consent',
    'transfer',
    'block',
  ]) {
    test(
      '$mutation change and restoration do not revive enabled permission',
      () async {
        await f.openDirect();
        final provider = await f.bind();
        final enabled = await f.enable();
        switch (mutation) {
          case 'provider':
            await f.changeProvider(provider, 'https://192.0.2.1/changed-path');
            await f.changeProvider(provider, 'https://192.0.2.1/v1');
          case 'provider binding':
            final alternate = await f.bind();
            expect(alternate, isNot(provider));
            await f.ok(
              'PUT',
              '/api/v1/ai-profiles/$_profile/bindings/chat',
              body: {'providerId': provider, 'model': 'fixture-model'},
            );
          case 'credential':
            final url = '/api/v1/model-providers/$provider';
            final original = (await f.db.query(
              'SELECT encrypted_key FROM providers WHERE id=?',
              [provider],
            )).single['encrypted_key'];
            await f.ok('PUT', url, body: {'api_key': 'fixture-replacement'});
            // Simulate restoring the exact previous credential envelope, not
            // merely another encryption with a new nonce of the same key.
            await f.db.execute(
              'UPDATE providers SET encrypted_key=? WHERE id=?',
              [original, provider],
            );
          case 'binding':
            await f.ok(
              'PUT',
              '/api/v1/ai-profiles/$_profile/bindings/chat',
              body: {'providerId': provider, 'model': 'different-model'},
            );
            await f.ok(
              'PUT',
              '/api/v1/ai-profiles/$_profile/bindings/chat',
              body: {'providerId': provider, 'model': 'fixture-model'},
            );
          case 'consent':
            await f.ok('DELETE', _direct, body: {'expectedRevision': 1});
            await f.ok('POST', _direct, body: {'expectedRevision': 2});
          case 'transfer':
            await f.db.execute(
              'UPDATE ai_operator SET operator_id=? WHERE ai_id=?',
              [_other, _ai],
            );
            await f.db.execute(
              'UPDATE ai_operator SET operator_id=? WHERE ai_id=?',
              [_owner, _ai],
            );
            await f.ok('POST', _direct, body: {'expectedRevision': 2});
          case 'block':
            await f.db.execute('INSERT INTO account_blocks VALUES(?,?,?)', [
              _owner,
              _ai,
              0,
            ]);
            await f.db.execute(
              'DELETE FROM account_blocks WHERE blocker=? AND target=?',
              [_owner, _ai],
            );
            await f.ok('POST', _direct, body: {'expectedRevision': 2});
        }
        await f.restart();
        final disabled = await f.ok('GET', _path);
        expect(disabled['enabled'], false);
        expect(disabled['revision'], 2);
        expect(disabled['length'], 'brief');
        expect(
          (disabled['target']! as Map)['token'],
          isNot((enabled['target']! as Map)['token']),
        );
      },
    );
  }

  group('production B2 with an offline synthetic child', () {
    setUp(() async {
      await f.installWorker();
      await f.bind();
      await f.readyToReply();
    });

    test(
      'ordinary S2 and S1 stay unchanged without eligible preference use',
      () async {
        final conversation = await f.openConversation();
        await f.send(conversation, 'before');
        expect(
          (await f.sync(conversation)).last['body'],
          containsPair('text', 'ordinary at /v1/chat/completions'),
        );
        await f.enable();
        await f.send(conversation, 'greeting', text: '你好');
        expect((await f.sync(conversation)).last['body'], {
          'text': '你好呀',
          'source': 's1',
          'activityRefs': [],
        });
        expect(await f.db.query('SELECT * FROM usage_ledger'), hasLength(1));
      },
    );

    test(
      'only the exact current choices enter the bounded user role, persist after reboot and stop on clear',
      () async {
        final conversation = await f.openConversation();
        await f.enable();
        await f.restart();
        await f.send(conversation, 'enabled');
        expect(
          (await f.sync(conversation)).last['body'],
          containsPair('text', 'brief bullets at /v1/chat/completions'),
        );
        await f.ok(
          'PUT',
          _path,
          body: f.payload(revision: 1, length: null, format: null),
        );
        await f.send(conversation, 'cleared');
        expect(
          (await f.sync(conversation)).last['body'],
          containsPair('text', 'ordinary at /v1/chat/completions'),
        );
        expect(
          (await f.db.query('SELECT layer,total_tokens FROM usage_ledger')),
          everyElement({'layer': 'b2DeepChat', 'total_tokens': '15'}),
        );
      },
    );

    test(
      'text accepted before opt-in and under earlier choices cannot inherit a later grant',
      () async {
        final conversation = await f.openConversation();
        final queued = await f.acceptWithoutObserver(
          conversation,
          'before-opt-in',
        );
        await f.enable();
        final queuedWithChoices = await f.acceptWithoutObserver(
          conversation,
          'prior-choices',
        );
        await f.ok(
          'PUT',
          _path,
          body: f.payload(
            revision: 1,
            enabled: true,
            token: await f.targetToken(),
            length: 'detailed',
            format: 'paragraphs',
          ),
        );
        final observer = f.host.registry.services
            .get<AcceptedMessageObserver>();
        await observer.onAccepted(queued);
        await observer.onAccepted(queuedWithChoices);
        final replies = (await f.sync(
          conversation,
        )).where((m) => m['senderId'] == _ai);
        expect(replies.map((m) => (m['body']! as Map)['text']), [
          'ordinary at /v1/chat/completions',
          'ordinary at /v1/chat/completions',
        ]);
        await f.send(conversation, 'new-choices');
        expect(
          (await f.sync(conversation)).last['body'],
          containsPair('text', 'detailed paragraphs at /v1/chat/completions'),
        );
      },
    );

    test(
      'explicit revoke during awaited URL preflight never dispatches',
      () async {
        final conversation = await f.openConversation();
        // Install a synthetic DNS name without requiring real DNS at config-write
        // time. The model gateway hits a controllable fake resolver below.
        await f.db.execute(
          "UPDATE providers SET base_url='https://fixture.invalid/v1'",
        );
        await f.enable();
        final source = await f.acceptWithoutObserver(
          conversation,
          'guard-await',
        );
        final entered = Completer<void>();
        final resume = Completer<List<InternetAddress>>();
        var requests = 0;
        final messages = f.localMessages();
        final observer = OwnerAiDirectReplyObserver(
          database: f.db,
          cipher: f.cipher,
          messages: messages,
          system: 'Synthetic instructions.',
          maxTokens: 32,
          admitS1: (_) async => false,
          resolveBinding: (grant) => BindingMatrix.forOwner(
            grant.ownerAccountId,
            f.db,
          ).resolve(AiId.parse(grant.aiProfileId), ProviderCapability.chat),
          preferences: OwnerReplyPreferences(
            database: f.db,
            cipher: f.cipher,
            clock: f.clock,
          ),
          chat: StatelessOwnerChat.fromRuntime(
            db: f.db,
            cipher: f.cipher,
            clock: f.clock,
            runtime: ModelRuntime(
              db: f.db,
              cipher: f.cipher,
              clock: f.clock,
              urlGuard: UrlGuard(
                resolver: (_) {
                  entered.complete();
                  return resume.future;
                },
              ),
              adapter: OpenAiCompatibleChatAdapter.withRequest((
                method,
                url, {
                headers = const {},
                body,
              }) async {
                requests++;
                return Ok(
                  GuardedResponse(
                    statusCode: 503,
                    headers: const {},
                    body: const [],
                  ),
                );
              }),
            ),
          ),
        );
        final processing = observer.onAccepted(source);
        try {
          await entered.future.timeout(const Duration(seconds: 5));
          await f.ok('PUT', _path, body: f.payload(revision: 1));
        } finally {
          resume.complete([InternetAddress('192.0.2.1')]);
          await processing;
        }
        expect(requests, 0);
        expect(await f.db.query('SELECT * FROM usage_ledger'), isEmpty);
        expect(await f.sync(conversation), hasLength(1));
      },
    );

    test(
      'unknown B2 usage blocks opt-in dispatch without rewriting ledger',
      () async {
        final conversation = await f.openConversation();
        await f.enable();
        await f.db.execute(
          '''INSERT INTO usage_ledger
(owner_id,ai_id,request_id,budget_day,offset_minutes,layer,capability,source_usage_unknown)
VALUES(?,?,?,?,?,?,?,1)''',
          [
            _owner,
            _profile,
            'older-attempt',
            '2026-01-01',
            0,
            'b2DeepChat',
            'chat',
          ],
        );
        await f.send(conversation, 'unknown-budget');
        expect(f.workerMarker.existsSync(), false);
        expect(await f.sync(conversation), hasLength(1));
        expect(
          await f.db.query(
            'SELECT request_id,source_usage_unknown FROM usage_ledger',
          ),
          [
            {'request_id': 'older-attempt', 'source_usage_unknown': 1},
          ],
        );
      },
    );

    test(
      'a grant revoked during the budget write never reaches the worker',
      () async {
        final conversation = await f.openConversation();
        await f.enable();
        // Deterministic interleaving at the existing usage-admission await, no sleeps.
        await f.db.execute(
          '''CREATE TRIGGER fixture_change_recipient_during_budget AFTER INSERT ON usage_ledger
BEGIN UPDATE providers SET base_url='https://192.0.2.1/other-account'; END''',
        );
        await f.send(conversation, 'stale-budget');
        expect(f.workerMarker.existsSync(), false);
        expect(await f.sync(conversation), hasLength(1));
        expect(await f.db.query('SELECT * FROM usage_ledger'), isEmpty);
        expect((await f.ok('GET', _path))['enabled'], false);
      },
    );

    test(
      'in-flight revocation suppresses publication but preserves measured usage',
      () async {
        final conversation = await f.openConversation();
        await f.enable();
        await f.workerHold.writeAsString('hold');
        final sending = f.send(conversation, 'in-flight');
        try {
          await f.waitForWorker();
          await f.ok('PUT', _path, body: f.payload(revision: 1));
        } finally {
          await f.workerRelease.writeAsString('release');
          await sending;
        }
        expect(await f.sync(conversation), hasLength(1));
        expect(
          (await f.db.query(
            'SELECT total_tokens,source_usage_unknown FROM usage_ledger',
          )).single,
          {'total_tokens': '15', 'source_usage_unknown': 0},
        );
        expect(
          (await f.db.query(
            'SELECT status FROM owner_reply_attempts',
          )).single['status'],
          'discarded',
        );
      },
    );
  });

  test('a write failure cannot commit an unaudited enable', () async {
    await f.openDirect();
    await f.bind();
    final target = await f.targetToken();
    await f.db.execute(
      '''CREATE TRIGGER refuse_preference_audit BEFORE INSERT ON audit_log
WHEN NEW.action='owner_reply_preferences.configure' BEGIN SELECT RAISE(ABORT, 'fixture'); END''',
    );
    expect(
      (await f.call(
        'PUT',
        _path,
        body: f.payload(enabled: true, token: target),
      )).status,
      500,
    );
    expect((await f.ok('GET', _path))['enabled'], false);
    expect(await f.db.query('SELECT * FROM owner_reply_preferences'), isEmpty);
  });
}

class _Fixture {
  _Fixture(this.directory);
  final Directory directory;
  final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
  late Host host;
  Database get db => host.registry.services.get<Database>();
  final tokens = <String, String>{};

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp('owner-style-');
    addTearDown(() => directory.delete(recursive: true));
    final f = _Fixture(directory);
    await f._boot();
    addTearDown(() async => expect(await f.host.shutdown(), isEmpty));
    await f.db.execute(
      "INSERT INTO account VALUES(?,?,'human',0,0,'test-only',0,0)",
      [_owner, 'Owner'],
    );
    await f.db.execute(
      "INSERT INTO account VALUES(?,?,'human',1,0,'test-only',0,0)",
      [_other, 'Other'],
    );
    await f.db.execute("INSERT INTO account VALUES(?,?,'ai',0,0,NULL,0,0)", [
      _ai,
      'AI',
    ]);
    await f.db.execute('INSERT INTO ai_operator VALUES(?,?)', [_ai, _owner]);
    await f.db.execute('INSERT INTO ai_profile VALUES(?,?)', [_profile, _ai]);
    final random = Random.secure();
    for (final actor in [_owner, _other, _ai]) {
      final token = base64UrlEncode(
        List.generate(16, (_) => random.nextInt(256)),
      ).replaceAll('=', '');
      f.tokens[actor] = token;
      final now = f.clock.now().millisecondsSinceEpoch;
      final expiry = now + const Duration(days: 1).inMilliseconds;
      String digest(String value) =>
          sha256.convert(utf8.encode(value)).toString();
      await f.db.execute('INSERT INTO device VALUES(?,?,?,?,?,?)', [
        '$actor-device',
        actor,
        'Fixture',
        digest(token),
        expiry,
        now,
      ]);
      await f.db.execute('INSERT INTO refresh_token VALUES(?,?,?)', [
        '$actor-device',
        digest('refresh-$token'),
        expiry,
      ]);
    }
    return f;
  }

  File get worker => File('${directory.path}/offline_worker.dart');
  File get workerHold => File('${directory.path}/hold');
  File get workerRelease => File('${directory.path}/release');
  File get workerMarker => File('${directory.path}/worker_entered');

  Future<void> _boot() async => host = await buildHost(
    config: HostConfig(
      dataDir: directory.path,
      modelWorkerExecutable: worker.existsSync()
          ? Platform.resolvedExecutable
          : null,
      modelWorkerPath: worker.existsSync() ? worker.path : null,
    ),
    clock: clock,
  );

  Future<void> installWorker() async {
    await worker.writeAsString(_offlineWorker);
    await restart();
  }

  Future<void> waitForWorker() async {
    final elapsed = Stopwatch()..start();
    while (!workerMarker.existsSync()) {
      if (elapsed.elapsed > const Duration(seconds: 10)) {
        fail('synthetic worker handoff not observed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> readyToReply() async {
    await ok(
      'POST',
      '/api/v1/ai-profiles/$_profile/persona/initialize',
      body: {
        'p0': {'name': 'Synthetic'},
        'p1': {'style': 'calm'},
        'p2': {'mood': 'neutral'},
      },
    );
    await ok(
      'PUT',
      '/api/v1/ai-profiles/$_profile/budget',
      body: {
        'dailyTokens': 12000,
        'offsetMinutes': 0,
        'layerLimits': {
          for (final layer in BudgetLayer.values)
            layer.name: layer == BudgetLayer.b2DeepChat
                ? 8000
                : layer == BudgetLayer.b1FastBrain
                ? 1000
                : 0,
        },
        'capabilityLimits': {
          for (final cap in [
            'chat',
            'chatFast',
            'vision',
            'imageGen',
            'tts',
            'asr',
            'embedding',
          ])
            cap: cap == 'chat'
                ? 8000
                : cap == 'chatFast'
                ? 1000
                : 0,
        },
      },
    );
  }

  static const question = '为什么这样？请解释原因。';

  Future<String> openConversation() async =>
      (await openDirect())['conversationId']! as String;

  Future<void> send(
    String conversation,
    String clientId, {
    String text = question,
  }) async {
    await ok(
      'POST',
      Routes.messages.replaceFirst('{conversationId}', conversation),
      body: {
        'clientMsgId': clientId,
        'kind': 'text',
        'body': {'text': text},
      },
    );
  }

  ColumnCipher get cipher => host.registry.services.get<ColumnCipher>();
  SqliteMessageStore localMessages() =>
      SqliteMessageStore(database: db, cipher: cipher, clock: clock);

  Future<StoredMessage> acceptWithoutObserver(
    String conversation,
    String clientId,
  ) async {
    final accepted =
        await OwnerAiDirectIncoming(
          database: db,
          messages: localMessages(),
        ).append(
          conversationId: conversation,
          senderId: _owner,
          clientMsgId: clientId,
          kind: MessageKind.text,
          body: {'text': question},
        );
    expect(accepted.isOk, true);
    return accepted.value.message;
  }

  Future<List<Map<String, Object?>>> sync(String conversation) async =>
      ((await ok(
                'GET',
                Routes.sync.replaceFirst('{conversationId}', conversation),
              ))['messages']!
              as List)
          .cast<Map<String, Object?>>();
  Future<void> restart() async {
    expect(await host.shutdown(), isEmpty);
    await _boot();
  }

  Future<HostResponse> call(
    String method,
    String path, {
    String? actor = _owner,
    Object? body,
  }) => host.pipeline.handle(
    HostRequest(
      method: method,
      path: path,
      body: body,
      headers: {if (actor != null) 'authorization': 'Bearer ${tokens[actor]}'},
    ),
  );

  Future<Map<String, Object?>> ok(
    String method,
    String path, {
    Object? body,
  }) async {
    final response = await call(method, path, body: body);
    expect(response.status, 200, reason: '$method $path');
    return (response.json! as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> openDirect() =>
      ok('POST', _direct, body: {'expectedRevision': 0});

  Future<String> bind() async {
    final view = await ok(
      'POST',
      Routes.modelProviders,
      body: {
        'name': 'Synthetic provider',
        'base_url': 'https://192.0.2.1/v1',
        'api_key': 'synthetic-fixture-only',
        'capabilities': ['chat'],
      },
    );
    final provider = view['id']! as String;
    await ok(
      'PUT',
      '/api/v1/ai-profiles/$_profile/bindings/chat',
      body: {'providerId': provider, 'model': 'fixture-model'},
    );
    return provider;
  }

  Future<void> changeProvider(String provider, String url) async {
    await ok(
      'PUT',
      '/api/v1/model-providers/$provider',
      body: {'base_url': url},
    );
  }

  Future<String> targetToken() async =>
      ((await ok('GET', _path))['target']! as Map)['token']! as String;

  Future<Map<String, Object?>> enable() async => ok(
    'PUT',
    _path,
    body: payload(enabled: true, token: await targetToken()),
  );

  Map<String, Object?> payload({
    int revision = 0,
    bool enabled = false,
    String? token,
    String? length = 'brief',
    String? format = 'bullets',
  }) => {
    'expectedRevision': revision,
    'enabled': enabled,
    'length': length,
    'format': format,
    'expectedTargetToken': token,
  };
}

// A subprocess exercising the actual production IPC seam; no network, no
// provider secrets in observations. The returned text reflects the wire turns.
const _offlineWorker = r'''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final directory = File.fromUri(Platform.script).parent.path;
  final request = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;
  final payload = jsonDecode(utf8.decode(base64Decode(request['body'] as String))) as Map;
  final turns = payload['messages'] as List;
  if (request['method'] != 'POST' || payload['model'] != 'fixture-model' ||
      payload['max_tokens'] != 512 || turns.first['role'] != 'system' ||
      (turns.first['content'] as String).contains('untrusted_owner_reply_preferences') ||
      turns.last['role'] != 'user' || turns.last['content'] != '为什么这样？请解释原因。') {
    stdout.writeln('{"ok":false,"code":"unavailable"}');
    return;
  }
  var style = 'ordinary';
  if (turns.length == 3 && turns[1]['role'] == 'user') {
    final data = jsonDecode(turns[1]['content'] as String) as Map;
    final choices = data['choices'] as Map;
    if (data['kind'] != 'untrusted_owner_reply_preferences' || choices.length != 2 ||
        utf8.encode(turns[1]['content'] as String).length > 512) {
      stdout.writeln('{"ok":false,"code":"unavailable"}');
      return;
    }
    style = '${choices['length']} ${choices['format']}';
  } else if (turns.length != 2) {
    stdout.writeln('{"ok":false,"code":"unavailable"}');
    return;
  }
  final path = Uri.parse(request['url'] as String).path;
  File('$directory/worker_entered').writeAsStringSync('entered');
  if (File('$directory/hold').existsSync()) {
    final elapsed = Stopwatch()..start();
    while (!File('$directory/release').existsSync()) {
      if (elapsed.elapsed > const Duration(seconds: 10)) exit(1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  final response = jsonEncode({
    'choices': [{'message': {'role': 'assistant', 'content': '$style at $path'}}],
    'usage': {'prompt_tokens': 11, 'completion_tokens': 4, 'total_tokens': 15},
  });
  stdout.writeln(jsonEncode({'ok': true, 'statusCode': 200, 'headers': {}, 'body': base64Encode(utf8.encode(response))}));
}
''';
