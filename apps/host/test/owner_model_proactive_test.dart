import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/ai/life/owner_model_proactive.dart';
import 'package:jingyu_host/src/ai/life/owner_model_proactive_module.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/models/model_gateway.dart';
import 'package:jingyu_host/src/models/openai_chat_adapter.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/storage/storage_module.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

const _owner = 'proactive-owner';
const _other = 'proactive-other';
const _ai = 'proactive-ai';
const _profile = 'proactive-profile';
const _settings = '/api/v1/ai-profiles/$_profile/owner-model-proactive';
const _global = '/api/v1/accounts/me/owner-model-proactive';
const _baseConsent = '/api/v1/ai-profiles/$_profile/direct-conversation';
const _level = '/api/v1/ai-profiles/$_profile/social-level';
const _budget = '/api/v1/ai-profiles/$_profile/budget';
const _prompt = '给主人发一句简短主动问候，不要编造事实，不要提记忆或历史';

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());

  test(
    'owner settings default off, do not open a pair, and are owner-only',
    () async {
      expect(await f.ok('GET', _settings), {
        'revision': 0,
        'enabled': false,
        'localMinute': 540,
        'offsetMinutes': null,
        'quietStartMinute': 1380,
        'quietEndMinute': 480,
        'intervalMinutes': 1440,
        'globalBlocked': false,
        'globalRevision': 0,
        'socialLevel': null,
        'chatRevision': null,
        'budgetReady': false,
        'lastSentAt': null,
      });
      expect(await f.ok('GET', _global), {'revision': 0, 'blocked': false});
      expect(
        await f.db.query('SELECT conversation_id FROM owner_ai_direct_grants'),
        isEmpty,
      );
      expect(await f.db.query('SELECT * FROM owner_model_proactive'), isEmpty);
      expect(
        await f.db.query('SELECT * FROM owner_model_proactive_stops'),
        isEmpty,
      );
      expect((await f.call('GET', _settings, actor: null)).status, 401);
      expect((await f.call('GET', _settings, actor: _other)).status, 404);
      expect((await f.call('GET', _global, actor: _ai)).status, 404);
    },
  );

  test(
    'only bounded exact schedule data may enable the separate grant',
    () async {
      await f.prerequisites();
      final chat = await f.ok('GET', _baseConsent);
      for (final body in [
        {..._schedule(), 'text': 'not an allowed field'},
        {..._schedule(), 'offsetMinutes': null},
        {..._schedule(), 'offsetMinutes': 841},
        {..._schedule(), 'localMinute': 1440},
        {..._schedule(), 'quietEndMinute': 1380},
        {..._schedule(), 'intervalMinutes': 59},
        {..._schedule(), 'intervalMinutes': 10081},
        {..._schedule(), 'expectedGlobalRevision': null},
        {..._schedule(enabled: false), 'expectedChatRevision': 1},
      ]) {
        expect((await f.call('PUT', _settings, body: body)).status, 400);
      }
      expect(
        (await f.call(
          'PUT',
          _settings,
          body: _schedule(chatRevision: 8),
        )).status,
        409,
      );
      expect(
        (await f.call(
          'PUT',
          _settings,
          body: _schedule(globalRevision: 8),
        )).status,
        409,
      );
      final active = await f.ok('PUT', _settings, body: _schedule());
      expect(active, {
        'revision': 1,
        'enabled': true,
        'localMinute': 540,
        'offsetMinutes': 0,
        'quietStartMinute': 1380,
        'quietEndMinute': 480,
        'intervalMinutes': 1440,
        'globalBlocked': false,
        'globalRevision': 0,
        'socialLevel': 'L3',
        'chatRevision': 1,
        'budgetReady': true,
        'lastSentAt': null,
      });
      expect(await f.ok('GET', _baseConsent), chat);
      expect(await f.db.query('SELECT * FROM messages'), isEmpty);
      expect(await f.db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );

  test(
    'a global stop cycle invalidates a review even without a per-AI row',
    () async {
      await f.prerequisites();
      expect(
        await f.ok(
          'PUT',
          _global,
          body: {'expectedRevision': 0, 'blocked': true},
        ),
        {'revision': 1, 'blocked': true},
      );
      expect(
        (await f.call(
          'PUT',
          _settings,
          body: _schedule(globalRevision: 1),
        )).status,
        409,
      );
      expect(
        await f.ok(
          'PUT',
          _global,
          body: {'expectedRevision': 1, 'blocked': false},
        ),
        {'revision': 2, 'blocked': false},
      );
      expect((await f.call('PUT', _settings, body: _schedule())).status, 409);
      expect(await f.db.query('SELECT * FROM owner_model_proactive'), isEmpty);
      expect(
        (await f.ok(
          'PUT',
          _settings,
          body: _schedule(globalRevision: 2),
        ))['enabled'],
        true,
      );
      await f.ok(
        'PUT',
        _global,
        body: {'expectedRevision': 2, 'blocked': true},
      );
      await f.ok(
        'PUT',
        _global,
        body: {'expectedRevision': 3, 'blocked': false},
      );
      final disabled = await f.ok('GET', _settings);
      expect(
        (disabled['enabled'], disabled['globalRevision'], disabled['revision']),
        (false, 4, 2),
      );
    },
  );

  test(
    'L0, L1, L2 and missing B3 do not allow enabling but off is always available',
    () async {
      await f.prerequisites();
      for (final level in ['L0', 'L1', 'L2']) {
        await f.ok('PUT', _level, body: {'level': level});
        expect((await f.call('PUT', _settings, body: _schedule())).status, 409);
      }
      await f.ok('PUT', _level, body: {'level': 'L3'});
      await f.budget(b3: 0);
      expect((await f.call('PUT', _settings, body: _schedule())).status, 409);
      await f.ok('DELETE', _baseConsent, body: {'expectedRevision': 1});
      final off = await f.ok('PUT', _settings, body: _schedule(enabled: false));
      expect(
        (off['enabled'], off['chatRevision'], off['budgetReady']),
        (false, null, false),
      );
    },
  );

  test(
    'one B3 model greeting is visible by sync, encrypted, and audited once',
    () async {
      final conversation = await f.prerequisites();
      await f.ok('PUT', _settings, body: _schedule());
      expect(await f.pollAt(_utc(1, 8, 59, 50)), 0);
      f.clock.set(_utc(1, 9, 0));
      final simultaneous = await Future.wait([
        f.proactive.poll(),
        f.proactive.poll(),
      ]);
      expect(simultaneous.first, 1);
      expect(await f.pollAt(_utc(1, 9, 0, 3)), 0);
      expect(f.modelCalls, hasLength(1));
      expect(f.modelCalls.single.layer, BudgetLayer.b3Proactive);
      expect(f.modelCalls.single.turns.single.role, 'system');
      expect(f.modelCalls.single.turns.single.content, _prompt);
      final rows = await f.sync(conversation);
      expect(rows.single['senderId'], _ai);
      expect(rows.single['seq'], 1);
      expect(rows.single['kind'], 'text');
      expect(rows.single['body'], {
        'text': f.modelText,
        'source': 'owner_model_proactive',
      });
      expect(rows.single['clientMsgId'], 'mp_$_owner/$_ai/2026-01-01');
      expect(
        (await f.ok('GET', _settings))['lastSentAt'],
        '2026-01-01T09:00:00.000Z',
      );
      // Encrypted at rest: the generated text never appears in the column.
      final stored = (await f.db.query(
        'SELECT body FROM messages WHERE message_id=?',
        [rows.single['messageId']],
      )).single['body'] as String;
      expect(stored, startsWith('v1:'));
      expect(stored, isNot(contains(f.modelText)));
      // No-body audit: only message id/day/revision, never the text.
      final audit = (await f.db.query(
        "SELECT meta FROM audit_log WHERE action='owner_model_proactive.sent'",
      )).single;
      expect(jsonDecode(audit['meta']! as String), {
        'messageId': rows.single['messageId'],
        'day': '2026-01-01',
        'revision': 1,
      });
      expect(await f.db.query('SELECT * FROM usage_ledger'), isEmpty);
    },
  );

  for (final mode in ['enable', 'boot', 'late']) {
    test('$mode during or after a due minute does not catch up', () async {
      final conversation = await f.prerequisites();
      if (mode == 'enable') {
        await f.pollAt(_utc(1, 9, 0, 3));
      }
      await f.ok('PUT', _settings, body: _schedule());
      if (mode == 'boot') {
        f.clock.set(_utc(1, 9, 0, 3));
        await f.restart();
      }
      expect(await f.pollAt(_utc(1, 9, 0, mode == 'late' ? 15 : 10)), 0);
      expect(await f.sync(conversation), isEmpty);
      expect(await f.pollAt(_utc(2, 8, 59, 50)), 0);
      expect(await f.pollAt(_utc(2, 9, 0)), 1);
    });
  }

  test('clock rollback and same-day reschedule cannot duplicate', () async {
    final conversation = await f.prerequisites();
    await f.ok('PUT', _settings, body: _schedule());
    await f.pollAt(_utc(1, 8, 59, 50));
    expect(await f.pollAt(_utc(1, 9, 0)), 1);
    expect(await f.pollAt(_utc(1, 8, 59, 50)), 0);
    expect(await f.pollAt(_utc(1, 9, 0)), 0);
    await f.ok(
      'PUT',
      _settings,
      body: _schedule(revision: 1, localMinute: 541),
    );
    expect(await f.pollAt(_utc(1, 9, 0, 50)), 0);
    expect(await f.pollAt(_utc(1, 9, 1)), 0);
    expect(await f.sync(conversation), hasLength(1));
  });

  for (final reboot in [false, true]) {
    test(
      'cross-midnight quiet deferral requires uninterrupted observation; reboot=$reboot',
      () async {
        await f.pollAt(_utc(1, 23, 58, 50));
        final conversation = await f.prerequisites();
        await f.ok(
          'PUT',
          _settings,
          body: _schedule(localMinute: 1439, quietStart: 1380, quietEnd: 1),
        );
        expect(await f.pollAt(_utc(1, 23, 59)), 0);
        expect(await f.sync(conversation), isEmpty);
        if (reboot) await f.restart();
        var next = _utc(1, 23, 59, 10);
        while (next.isBefore(_utc(2, 0, 1))) {
          expect(await f.pollAt(next), 0);
          next = next.add(const Duration(seconds: 10));
        }
        expect(await f.pollAt(_utc(2, 0, 1)), reboot ? 0 : 1);
        expect(await f.sync(conversation), hasLength(reboot ? 0 : 1));
      },
    );
  }

  test('interval watermark caps frequency across local days', () async {
    final conversation = await f.prerequisites();
    await f.ok('PUT', _settings, body: _schedule(interval: 2880));
    await f.pollAt(_utc(1, 8, 59, 50));
    expect(await f.pollAt(_utc(1, 9, 0)), 1);
    expect(await f.pollAt(_utc(2, 8, 59, 50)), 0);
    expect(await f.pollAt(_utc(2, 9, 0)), 0);
    expect(await f.pollAt(_utc(3, 8, 59, 50)), 0);
    expect(await f.pollAt(_utc(3, 9, 0)), 1);
    expect(await f.sync(conversation), hasLength(2));
  });

  test('budget exhausted stays silent with no model call and no send', () async {
    final conversation = await f.prerequisites();
    await f.ok('PUT', _settings, body: _schedule());
    await f.pollAt(_utc(1, 8, 59, 50));
    await f.budget(b3: 0);
    expect(await f.pollAt(_utc(1, 9, 0)), 0);
    expect(f.modelCalls, isEmpty);
    expect(await f.sync(conversation), isEmpty);
    final state = await f.ok('GET', _settings);
    expect(state['enabled'], true);
    expect(state['budgetReady'], false);
  });

  test('model failure stays silent with no send and no replay', () async {
    final conversation = await f.prerequisites();
    await f.ok('PUT', _settings, body: _schedule());
    await f.pollAt(_utc(1, 8, 59, 50));
    f.modelFail = true;
    expect(await f.pollAt(_utc(1, 9, 0)), 0);
    expect(f.modelCalls, hasLength(1));
    expect(await f.sync(conversation), isEmpty);
    expect(await f.pollAt(_utc(1, 9, 0, 3)), 0);
    expect(f.modelCalls, hasLength(1));
    expect(await f.sync(conversation), isEmpty);
  });

  test('failed delivery is not replayed after clock rollback and restart', () async {
    final conversation = await f.prerequisites();
    await f.ok('PUT', _settings, body: _schedule());
    await f.pollAt(_utc(1, 8, 59, 50));
    await f.db.execute(
      '''CREATE TRIGGER proactive_audit_fail_before_restart BEFORE INSERT ON audit_log
WHEN NEW.action='owner_model_proactive.sent' BEGIN SELECT RAISE(ABORT,'test'); END''',
    );
    expect(await f.pollAt(_utc(1, 9, 0)), 0);
    expect(await f.sync(conversation), isEmpty);
    await f.db.execute('DROP TRIGGER proactive_audit_fail_before_restart');
    f.clock.set(_utc(1, 8, 59, 45));
    await f.restart();
    expect(await f.pollAt(_utc(1, 8, 59, 55)), 0);
    expect(await f.pollAt(_utc(1, 9, 0)), 0);
    expect(await f.sync(conversation), isEmpty);
  });

  test(
    'uncommittable audit rolls back text, sequence, and watermark without replay',
    () async {
      final conversation = await f.prerequisites();
      await f.ok('PUT', _settings, body: _schedule());
      await f.pollAt(_utc(1, 8, 59, 50));
      await f.db.execute(
        '''CREATE TRIGGER proactive_audit_fail BEFORE INSERT ON audit_log
WHEN NEW.action='owner_model_proactive.sent' BEGIN SELECT RAISE(ABORT,'test'); END''',
      );
      expect(await f.pollAt(_utc(1, 9, 0)), 0);
      expect(await f.sync(conversation), isEmpty);
      expect(
        await f.db.query('SELECT * FROM owner_model_proactive_delivery'),
        isEmpty,
      );
      await f.db.execute('DROP TRIGGER proactive_audit_fail');
      expect(await f.pollAt(_utc(1, 9, 0, 8)), 0);
      expect(await f.sync(conversation), isEmpty);
      await f.pollAt(_utc(2, 8, 59, 50));
      expect(await f.pollAt(_utc(2, 9, 0)), 1);
      expect((await f.sync(conversation)).single['seq'], 1);
    },
  );

  test('provider and binding changes revoke an enabled grant', () async {
    await f.prerequisites();
    await f.db.execute(
      "INSERT INTO providers(owner_id,id,name,base_url,encrypted_key,key_mask,enabled,capabilities) VALUES(?,?,?,?,?,?,?,?)",
      [_owner, 'fixture-provider', 'Fixture', 'https://models.example/v1', 'v1:AAAA', '****', 1, '["chat"]'],
    );
    await f.db.execute(
      "INSERT INTO model_bindings(owner_id,ai_profile_id,capability,provider_id,model) VALUES(?,?,?,?,?)",
      [_owner, _profile, 'chat', 'fixture-provider', 'model-a'],
    );
    await f.ok('PUT', _settings, body: _schedule());
    expect((await f.ok('GET', _settings))['enabled'], true);
    await f.db.execute(
      "UPDATE model_bindings SET model='model-b' WHERE owner_id=? AND ai_profile_id=? AND capability='chat'",
      [_owner, _profile],
    );
    var state = await f.ok('GET', _settings);
    expect((state['enabled'], state['chatRevision']), (false, null));
    await f.ok(
      'PUT',
      _settings,
      body: _schedule(revision: state['revision']! as int),
    );
    expect((await f.ok('GET', _settings))['enabled'], true);
    await f.db.execute(
      "UPDATE providers SET enabled=0 WHERE id='fixture-provider'",
    );
    state = await f.ok('GET', _settings);
    expect((state['enabled'], state['chatRevision']), (false, null));
  });

  test('consent change revokes and never revives without a fresh review', () async {
    await f.prerequisites();
    await f.ok('PUT', _settings, body: _schedule());
    expect((await f.ok('GET', _settings))['enabled'], true);
    await f.ok('DELETE', _baseConsent, body: {'expectedRevision': 1});
    await f.ok('POST', _baseConsent, body: {'expectedRevision': 2});
    final state = await f.ok('GET', _settings);
    expect((state['enabled'], state['chatRevision']), (false, null));
  });
}

DateTime _utc(int day, int hour, int minute, [int second = 0]) =>
    DateTime.utc(2026, 1, day, hour, minute, second);

Map<String, Object?> _schedule({
  int revision = 0,
  bool enabled = true,
  int chatRevision = 1,
  int globalRevision = 0,
  int localMinute = 540,
  int offset = 0,
  int quietStart = 1380,
  int quietEnd = 480,
  int interval = 1440,
}) => {
  'expectedRevision': revision,
  'enabled': enabled,
  'localMinute': localMinute,
  'offsetMinutes': offset,
  'quietStartMinute': quietStart,
  'quietEndMinute': quietEnd,
  'intervalMinutes': interval,
  'expectedChatRevision': enabled ? chatRevision : null,
  'expectedGlobalRevision': enabled ? globalRevision : null,
};

final class _Fixture {
  _Fixture(this.directory);
  final Directory directory;
  final clock = FakeClock(DateTime.utc(2026, 1, 1, 8, 59, 40));
  final tokens = <String, String>{};
  final modelCalls =
      <({String owner, String ai, List<ChatTurn> turns, String requestId, BudgetLayer layer})>[];
  String modelText = '早安，主人，愿你今天顺利。';
  bool modelFail = false;
  late Host host;

  Database get db => host.registry.services.get<Database>();

  OwnerModelProactive get proactive =>
      host.registry.services.get<OwnerModelProactive>();

  Future<Result<ChatCompletion>> _chat({
    required String ownerId,
    required AiId ai,
    required List<ChatTurn> turns,
    required String requestId,
    required BudgetLayer layer,
    required TrustedChatContext context,
    int? maxTokens,
    String? expectedProviderId,
    String? expectedModel,
  }) async {
    modelCalls.add((
      owner: ownerId,
      ai: ai.value,
      turns: turns,
      requestId: requestId,
      layer: layer,
    ));
    if (modelFail) {
      return err(FailureCode.modelUnavailable, 'Provider chat unavailable');
    }
    return Ok(
      ChatCompletion(
        text: modelText,
        inputTokens: 3,
        outputTokens: 2,
        totalTokens: 5,
      ),
    );
  }

  Future<void> boot() async {
    final config = HostConfig(dataDir: directory.path);
    final base = defaultModules(config, clock);
    final storage = base.whereType<StorageModule>().single;
    final messages = SqliteMessageStore(
      database: storage.database,
      cipher: storage.cipher,
      clock: clock,
    );
    final proactive = OwnerModelProactive(
      database: storage.database,
      messages: messages,
      clock: clock,
      chat: _chat,
    );
    host = await buildHost(
      config: config,
      clock: clock,
      modules: [...base, OwnerModelProactiveModule(proactive, enableTimer: false)],
      onError: (error, stack) => print('HOST-ERR: $error\n$stack'),
    );
  }

  Future<void> restart() async {
    expect(await host.shutdown(), isEmpty);
    await boot();
  }

  Future<int> pollAt(DateTime now) {
    clock.set(now);
    return proactive.poll();
  }

  Future<List<Map<String, Object?>>> sync(String id) async =>
      ((await ok(
                'GET',
                Routes.sync.replaceFirst('{conversationId}', id),
              ))['messages']!
              as List)
          .cast<Map<String, Object?>>();

  static Future<_Fixture> create() async {
    final dir = await Directory.systemTemp.createTemp('owner-model-proactive-');
    addTearDown(() => dir.delete(recursive: true));
    final f = _Fixture(dir);
    await f.boot();
    addTearDown(() async => expect(await f.host.shutdown(), isEmpty));
    for (final human in [_owner, _other]) {
      await f.db.execute(
        "INSERT INTO account VALUES(?,?,'human',?,0,'test-only',0,0)",
        [human, human, human == _other ? 1 : 0],
      );
    }
    await f.db.execute("INSERT INTO account VALUES(?,?,'ai',0,0,NULL,0,0)", [
      _ai,
      'Fixture',
    ]);
    await f.db.execute('INSERT INTO ai_operator VALUES(?,?)', [_ai, _owner]);
    await f.db.execute('INSERT INTO ai_profile VALUES(?,?)', [_profile, _ai]);
    final random = Random.secure();
    String hash(String raw) => sha256.convert(utf8.encode(raw)).toString();
    for (final actor in [_owner, _other, _ai]) {
      final token = base64UrlEncode(
        List.generate(16, (_) => random.nextInt(256)),
      ).replaceAll('=', '');
      f.tokens[actor] = token;
      final now = f.clock.now();
      final expires = now.add(const Duration(days: 30)).millisecondsSinceEpoch;
      await f.db.execute('INSERT INTO device VALUES(?,?,?,?,?,?)', [
        '$actor-device',
        actor,
        'Test device',
        hash(token),
        expires,
        now.millisecondsSinceEpoch,
      ]);
      await f.db.execute('INSERT INTO refresh_token VALUES(?,?,?)', [
        '$actor-device',
        hash('refresh-$token'),
        expires,
      ]);
    }
    return f;
  }

  Future<HostResponse> call(
    String method,
    String path, {
    Object? body,
    String? actor = _owner,
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

  Future<String> prerequisites() async {
    final chat = await ok('POST', _baseConsent, body: {'expectedRevision': 0});
    await ok('PUT', _level, body: {'level': 'L3'});
    await budget();
    return chat['conversationId']! as String;
  }

  Future<void> budget({
    int b3 = 100,
    int daily = 500,
    int chat = 400,
    int offset = 0,
  }) async {
    await ok(
      'PUT',
      _budget,
      body: {
        'dailyTokens': daily,
        'offsetMinutes': offset,
        'layerLimits': {
          for (final layer in BudgetLayer.values)
            layer.name: layer == BudgetLayer.b3Proactive ? b3 : 0,
        },
        'capabilityLimits': {
          for (final name in [
            'chat',
            'chatFast',
            'tts',
            'asr',
            'vision',
            'imageGen',
            'embedding',
          ])
            name: name == 'chat' ? chat : 0,
        },
      },
    );
  }
}
