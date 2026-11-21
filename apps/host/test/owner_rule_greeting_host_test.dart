import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/ai/life/owner_rule_greeting.dart';
import 'package:jingyu_host/src/ai/life/owner_rule_greeting_module.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

const _owner = 'greeting-owner';
const _other = 'greeting-other';
const _ai = 'greeting-ai';
const _profile = 'greeting-profile';
const _settings = '/api/v1/ai-profiles/$_profile/owner-rule-greeting';
const _global = '/api/v1/accounts/me/owner-rule-greetings';
const _baseConsent = '/api/v1/ai-profiles/$_profile/direct-conversation';
const _level = '/api/v1/ai-profiles/$_profile/social-level';
const _budget = '/api/v1/ai-profiles/$_profile/budget';

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
      expect(await f.db.query('SELECT * FROM owner_rule_greetings'), isEmpty);
      expect(
        await f.db.query('SELECT * FROM owner_rule_greeting_stops'),
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
      expect(await f.db.query('SELECT * FROM owner_rule_greetings'), isEmpty);
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
    'L0 and missing B3 do not allow enabling but off is always available',
    () async {
      await f.prerequisites();
      await f.ok('PUT', _level, body: {'level': 'L0'});
      expect((await f.call('PUT', _settings, body: _schedule())).status, 409);
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
    'one offline-model greeting is visible by normal sync and audited once',
    () async {
      final conversation = await f.prerequisites();
      await f.ok('PUT', _settings, body: _schedule());
      expect(await f.pollAt(_utc(1, 8, 59, 50)), 0);
      f.clock.set(_utc(1, 9, 0));
      final simultaneous = await Future.wait([
        f.greeting.poll(),
        f.greeting.poll(),
      ]);
      expect(simultaneous.first, 1);
      expect(await f.pollAt(_utc(1, 9, 0, 3)), 0);
      final rows = await f.sync(conversation);
      expect(rows.single['senderId'], _ai);
      expect(rows.single['seq'], 1);
      expect(rows.single['kind'], 'text');
      expect(rows.single['body'], {
        'text': '【规则问候】你好，愿你今天顺利。',
        'source': 'owner_rule_greeting',
      });
      expect(
        (await f.ok('GET', _settings))['lastSentAt'],
        '2026-01-01T09:00:00.000Z',
      );
      expect(await f.db.query('SELECT * FROM usage_ledger'), isEmpty);
      expect(
        await f.db.query('SELECT * FROM owner_ai_direct_sources'),
        isEmpty,
      );
      expect(await f.db.query('SELECT * FROM owner_reply_attempts'), isEmpty);
      final audit = (await f.db.query(
        "SELECT meta FROM audit_log WHERE action='owner_rule_greeting.sent'",
      )).single;
      expect(jsonDecode(audit['meta']! as String), {
        'messageId': rows.single['messageId'],
        'day': '2026-01-01',
      });
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

  for (final change in ['level', 'pair', 'block', 'budget', 'unknown']) {
    test('$change between opt-in and dispatch blocks the slot', () async {
      final conversation = await f.prerequisites();
      await f.ok('PUT', _settings, body: _schedule());
      await f.pollAt(_utc(1, 8, 59, 50));
      switch (change) {
        case 'level':
          await f.ok('PUT', _level, body: {'level': 'L0'});
          await f.ok('PUT', _level, body: {'level': 'L3'});
        case 'pair':
          await f.ok('DELETE', _baseConsent, body: {'expectedRevision': 1});
          await f.ok('POST', _baseConsent, body: {'expectedRevision': 2});
        case 'block':
          await f.ok(
            'PUT',
            _global,
            body: {'expectedRevision': 0, 'blocked': true},
          );
          await f.ok(
            'PUT',
            _global,
            body: {'expectedRevision': 1, 'blocked': false},
          );
        case 'budget':
          await f.budget(b3: 0);
        case 'unknown':
          await f.db.execute(
            '''INSERT INTO usage_ledger
(owner_id,ai_id,request_id,budget_day,offset_minutes,layer,capability,source_usage_unknown)
VALUES(?,?,?,?,?,?,?,1)''',
            [
              _owner,
              _profile,
              'old-other-capability',
              '2025-12-31',
              0,
              'b2DeepChat',
              'vision',
            ],
          );
      }
      expect(await f.pollAt(_utc(1, 9, 0)), 0);
      expect(await f.sync(conversation), isEmpty);
      final state = await f.ok('GET', _settings);
      expect(state['enabled'], change == 'budget' || change == 'unknown');
      if (change == 'budget' || change == 'unknown') {
        expect(state['budgetReady'], false);
      }
    });
  }

  test(
    'failed delivery is not replayed after clock rollback and restart',
    () async {
      final conversation = await f.prerequisites();
      await f.ok('PUT', _settings, body: _schedule());
      await f.pollAt(_utc(1, 8, 59, 50));
      await f.db.execute(
        '''CREATE TRIGGER greet_audit_fail_before_restart BEFORE INSERT ON audit_log
WHEN NEW.action='owner_rule_greeting.sent' BEGIN SELECT RAISE(ABORT,'test'); END''',
      );
      expect(await f.pollAt(_utc(1, 9, 0)), 0);
      expect(await f.sync(conversation), isEmpty);
      await f.db.execute('DROP TRIGGER greet_audit_fail_before_restart');
      f.clock.set(_utc(1, 8, 59, 45));
      await f.restart();
      expect(await f.pollAt(_utc(1, 8, 59, 55)), 0);
      expect(await f.pollAt(_utc(1, 9, 0)), 0);
      expect(await f.sync(conversation), isEmpty);
    },
  );

  test(
    'uncommittable audit rolls back text, sequence, and daily watermark without replay',
    () async {
      final conversation = await f.prerequisites();
      await f.ok('PUT', _settings, body: _schedule());
      await f.pollAt(_utc(1, 8, 59, 50));
      await f.db.execute(
        '''CREATE TRIGGER greet_audit_fail BEFORE INSERT ON audit_log
WHEN NEW.action='owner_rule_greeting.sent' BEGIN SELECT RAISE(ABORT,'test'); END''',
      );
      expect(await f.pollAt(_utc(1, 9, 0)), 0);
      expect(await f.sync(conversation), isEmpty);
      expect(
        await f.db.query('SELECT * FROM owner_rule_greeting_delivery'),
        isEmpty,
      );
      await f.db.execute('DROP TRIGGER greet_audit_fail');
      expect(await f.pollAt(_utc(1, 9, 0, 8)), 0);
      expect(await f.sync(conversation), isEmpty);
      await f.pollAt(_utc(2, 8, 59, 50));
      expect(await f.pollAt(_utc(2, 9, 0)), 1);
      expect((await f.sync(conversation)).single['seq'], 1);
    },
  );
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
}) => {
  'expectedRevision': revision,
  'enabled': enabled,
  'localMinute': localMinute,
  'offsetMinutes': offset,
  'quietStartMinute': quietStart,
  'quietEndMinute': quietEnd,
  'expectedChatRevision': enabled ? chatRevision : null,
  'expectedGlobalRevision': enabled ? globalRevision : null,
};

final class _Fixture {
  _Fixture(this.directory);
  final Directory directory;
  final clock = FakeClock(DateTime.utc(2026, 1, 1, 8, 59, 40));
  final tokens = <String, String>{};
  late Host host;
  Database get db => host.registry.services.get<Database>();

  OwnerRuleGreeting get greeting =>
      host.registry.services.get<OwnerRuleGreeting>();

  Future<void> boot({bool timer = false}) async {
    final config = HostConfig(dataDir: directory.path);
    final modules = defaultModules(config, clock)
        .map(
          (module) => !timer && module is OwnerRuleGreetingModule
              ? OwnerRuleGreetingModule(module.greetings, enableTimer: false)
              : module,
        )
        .toList();
    host = await buildHost(config: config, clock: clock, modules: modules);
  }

  Future<void> restart() async {
    expect(await host.shutdown(), isEmpty);
    await boot();
  }

  Future<int> pollAt(DateTime now) {
    clock.set(now);
    return greeting.poll();
  }

  Future<List<Map<String, Object?>>> sync(String id) async =>
      ((await ok(
                'GET',
                Routes.sync.replaceFirst('{conversationId}', id),
              ))['messages']!
              as List)
          .cast<Map<String, Object?>>();

  static Future<_Fixture> create() async {
    final dir = await Directory.systemTemp.createTemp('owner-rule-greeting-');
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
