import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/brain/group_rules_module.dart';
import 'package:jingyu_host/src/messages/accepted_message_observer.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _BeforeObserver extends HostModule implements AcceptedMessageObserver {
  _BeforeObserver(this.delegate, this.before);
  final AcceptedMessageObserver delegate;
  final Future<void> Function(StoredMessage) before;
  @override
  String get name => 'group_rules';
  @override
  List<String> get dependsOn => const [
    'messages',
    'social',
    'models',
    'social_level',
  ];
  @override
  Future<void> configure(HostServices services) async {
    services.provide<AcceptedMessageObserver>(this, owner: name);
  }

  @override
  Future<void> onAccepted(StoredMessage message) async {
    await before(message);
    await delegate.onAccepted(message);
  }
}

void main() {
  late Directory dir;
  late Host host;
  late Database db;
  late HttpServer server;
  late HttpClient http;
  late String origin, token;
  final clock = FakeClock(DateTime.utc(2026, 11, 16, 12));
  Future<void> Function(StoredMessage)? beforeObserver;
  Future<Map<String, Object?>> call(
    String method,
    String path, {
    Map<String, Object?>? body,
    int status = 200,
  }) async {
    final r = await http.openUrl(method, Uri.parse('$origin$path'));
    r.headers.contentType = ContentType.json;
    r.headers.set('authorization', 'Bearer $token');
    if (body != null) r.write(jsonEncode(body));
    final response = await r.close();
    final text = await utf8.decoder.bind(response).join();
    expect(response.statusCode, status, reason: text);
    return text.isEmpty
        ? {}
        : (jsonDecode(text) as Map).cast<String, Object?>();
  }

  Future<void> send(
    String id, {
    String text = '你好',
    Object? mention = const ['ai'],
    bool included = true,
  }) async {
    await call(
      'POST',
      Routes.messages.replaceFirst('{conversationId}', 'group'),
      body: {
        'clientMsgId': id,
        'kind': 'text',
        'body': {'text': text, if (included) 'mentionAccountIds': mention},
      },
    );
  }

  Future<List<dynamic>> sync() async =>
      (await call(
            'GET',
            Routes.sync.replaceFirst('{conversationId}', 'group'),
          ))['messages']
          as List;
  Future<void> level(String? value) async {
    await db.execute('DELETE FROM ai_social_levels');
    if (value != null) {
      await db.execute('INSERT INTO ai_social_levels VALUES(?,?,?,?)', [
        'owner',
        'profile',
        value,
        clock.now().toIso8601String(),
      ]);
    }
  }

  setUp(() async {
    clock.set(DateTime.utc(2026, 11, 16, 12));
    dir = await Directory.systemTemp.createTemp('group-rules-host-');
    beforeObserver = null;
    final modules = defaultModules(HostConfig(dataDir: dir.path), clock);
    final index = modules.indexWhere((m) => m is GroupRulesModule);
    final observer = modules[index] as GroupRulesModule;
    modules[index] = _BeforeObserver(observer, (message) async {
      await beforeObserver?.call(message);
    });
    host = await buildHost(modules: modules, clock: clock);
    db = host.registry.services.get<Database>();
    // Synthetic rows/tokens exercise the real default HTTP authenticator without
    // repeating expensive password hashing in every independent policy case.
    await db.execute(
      "INSERT INTO account VALUES('owner','Synthetic owner','human',1,0,'fixture',0,0)",
    );
    await db.execute(
      "INSERT INTO account VALUES('human','Synthetic human','human',0,0,'fixture',0,0)",
    );
    await db.execute(
      "INSERT INTO account VALUES('ai','Synthetic AI','ai',0,0,NULL,0,0)",
    );
    await db.execute("INSERT INTO ai_operator VALUES('ai','owner')");
    await db.execute("INSERT INTO ai_profile VALUES('profile','ai')");
    token = 'abcdefghijklmnopqrstuv';
    await db.execute('INSERT INTO device VALUES(?,?,?,?,?,?)', [
      'device',
      'human',
      'synthetic',
      sha256.convert(utf8.encode(token)).toString(),
      clock.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      clock.now().millisecondsSinceEpoch,
    ]);
    await db.execute('INSERT INTO refresh_token VALUES(?,?,?)', [
      'device',
      sha256.convert(utf8.encode('synthetic-refresh')).toString(),
      clock.now().add(const Duration(days: 1)).millisecondsSinceEpoch,
    ]);
    await db.execute(
      "INSERT INTO social_conversations VALUES('group','owner','Synthetic group','all',0)",
    );
    for (final member in ['owner', 'human', 'ai']) {
      await db.execute('INSERT INTO social_members VALUES(?,?,0,1)', [
        'group',
        member,
      ]);
    }
    await db.execute(
      "INSERT INTO group_ai_settings VALUES('group',30000,1,10,0,600000,0,0)",
    );
    await level('L1');
    await db.execute(
      'INSERT INTO usage_budget(owner_id,ai_id,daily_tokens,layer_limits,capability_limits,offset_minutes) VALUES(?,?,?,?,?,?)',
      [
        'owner',
        'profile',
        '100',
        jsonEncode({for (final l in BudgetLayer.values) l.name: '0'}),
        jsonEncode({
          for (final c in [
            'chat',
            'chatFast',
            'vision',
            'imageGen',
            'tts',
            'asr',
            'embedding',
          ])
            c: c == 'chatFast' ? '100' : '0',
        }),
        480,
      ],
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    http = HttpClient();
    serve(server, host.pipeline);
  });
  tearDown(() async {
    http.close(force: true);
    await server.close(force: true);
    await host.shutdown();
    await dir.delete(recursive: true);
  });
  test(
    'default HTTP stores one canonical S1 reply and duplicate does not repeat',
    () async {
      await send('one');
      await send('one');
      final messages = await sync();
      expect(messages.length, 2);
      expect(messages.last['senderId'], 'ai');
      expect(messages.last['body'], {
        'text': '你好呀',
        'source': 's1',
        'activityRefs': [],
      });
      expect(await db.query('SELECT * FROM usage_ledger'), isEmpty);
      expect((await db.query('SELECT * FROM group_ai_admissions')).length, 1);
    },
  );
  for (final value in [null, 'L0']) {
    test('missing or L0 social setting stays silent $value', () async {
      await level(value);
      await send('one');
      expect((await sync()).length, 1);
      expect(await db.query('SELECT * FROM group_ai_admissions'), isEmpty);
    });
  }
  for (final text in ['你好，怎么做？', '任意未知长一点内容', '短句']) {
    test('unsupported or complex text is silent $text', () async {
      await send('one', text: text);
      expect((await sync()).length, 1);
    });
  }
  test(
    'no mention and valid foreign target preserve human-only messages',
    () async {
      await send('one', included: false);
      await send('two', mention: ['foreign']);
      expect((await sync()).length, 2);
    },
  );
  for (final change in [
    "UPDATE account SET disabled=1 WHERE id='ai'",
    "UPDATE account SET disabled=1 WHERE id='owner'",
    "DELETE FROM social_members WHERE account_id='ai'",
    "UPDATE social_members SET first_visible_seq=99 WHERE account_id='ai'",
    "UPDATE group_ai_settings SET daily_cap=0",
    "INSERT INTO group_ai_mutes VALUES('group','ai',1)",
    "UPDATE usage_budget SET offset_minutes=NULL",
    "UPDATE usage_budget SET daily_tokens='0'",
    "UPDATE usage_budget SET capability_limits='{\"chat\":\"0\",\"chatFast\":\"0\",\"vision\":\"0\",\"imageGen\":\"0\",\"tts\":\"0\",\"asr\":\"0\",\"embedding\":\"0\"}'",
  ]) {
    test('live policy denies reply: $change', () async {
      await db.execute(change);
      await send('one');
      expect((await sync()).length, 1);
    });
  }
  test(
    'AI append failure preserves human input and conservatively burns admission',
    () async {
      await db.execute(
        "CREATE TRIGGER reject_ai BEFORE INSERT ON messages WHEN NEW.sender_id='ai' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
      );
      await send('one');
      expect((await sync()).length, 1);
      expect((await db.query('SELECT * FROM group_ai_admissions')).length, 1);
      await send('one');
      expect((await db.query('SELECT * FROM group_ai_admissions')).length, 1);
    },
  );
  test('canonical human source is rechecked before a rule reply', () async {
    // A valid device can remain attached to a principal whose kind changed;
    // the dispatch boundary must not respond to an AI source.
    await db.execute(
      "UPDATE account SET kind='ai',password_hash=NULL WHERE id='human'",
    );
    await db.execute("INSERT INTO ai_operator VALUES('human','owner')");
    await send('one');
    expect((await sync()).length, 1);
  });
  test('current owner transfer does not reuse old owner settings', () async {
    await db.execute(
      "UPDATE ai_operator SET operator_id='human' WHERE ai_id='ai'",
    );
    await send('one');
    expect((await sync()).length, 1);
  });
  test(
    'source edited before observer dispatch is conservatively silent',
    () async {
      beforeObserver = (message) async {
        final edited = await host.registry.services.get<MessageStore>().edit(
          conversationId: message.conversationId,
          messageId: message.messageId,
          senderId: message.senderId,
          body: {'text': '新的复杂问题？'},
        );
        expect(edited.isOk, isTrue);
      };
      await send('one');
      final messages = await sync();
      expect(messages.length, 1);
      expect(messages.single['body'], {'text': '新的复杂问题？'});
      expect(await db.query('SELECT * FROM group_ai_admissions'), isEmpty);
    },
  );
  test('direct group ID ambiguity added before observer is silent', () async {
    beforeObserver = (_) async {
      await db.execute(
        "INSERT INTO direct_conversations VALUES('group','human','owner',0)",
      );
    };
    await send('one');
    expect(
      (await host.registry.services.get<MessageStore>().since(
        conversationId: 'group',
        afterSeq: 0,
      )).value.messages.length,
      1,
    );
    expect(await db.query('SELECT * FROM group_ai_admissions'), isEmpty);
  });
  test('unknown provider usage stays fail closed for rules', () async {
    await db.execute(
      "INSERT INTO usage_ledger(owner_id,ai_id,request_id,budget_day,offset_minutes,layer,capability,source_usage_unknown) VALUES('owner','profile','unknown','2026-11-15',480,'b1FastBrain','chatFast',1)",
    );
    await send('one');
    expect((await sync()).length, 1);
  });
  test(
    'concurrent human sends preserve atomic group interval admission',
    () async {
      await Future.wait([send('one'), send('two')]);
      final messages = await sync();
      expect(messages.where((m) => m['senderId'] == 'ai').length, 1);
      expect(messages.length, 3);
    },
  );
}
