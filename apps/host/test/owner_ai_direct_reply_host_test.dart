import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/models/model_runtime.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

/// Real default host composition, authentication, canonical persistence and
/// Pipeline routes. No observer substitution, provider, worker or real model.
void main() {
  late Directory directory;
  late Host host;
  late Database db;
  final clock = FakeClock(DateTime.utc(2026, 11, 17, 4));
  final ownerToken = List<String>.filled(22, 'a').join();
  final otherToken = List<String>.filled(22, 'b').join();
  const owner = 'owner';
  const aiAccount = 'ai-account';
  const profile = 'ai-profile-distinct';
  const consentPath = '/api/v1/ai-profiles/$profile/direct-conversation';

  Future<HostResponse> call(
    String method,
    String path, {
    Object? body,
    String? bearer,
  }) => host.pipeline.handle(
    HostRequest(
      method: method,
      path: path,
      headers: {'authorization': 'Bearer ${bearer ?? ownerToken}'},
      body: body,
    ),
  );

  Map<String, Object?> json(HostResponse response, {int status = 200}) {
    expect(response.status, status, reason: response.encodeBody());
    return (response.json as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> post(
    String conversation,
    String clientId,
    String text, {
    bool mention = false,
  }) async => json(
    await call(
      'POST',
      Routes.messages.replaceFirst('{conversationId}', conversation),
      body: {
        'clientMsgId': clientId,
        'kind': 'text',
        'body': {
          'text': text,
          if (mention) 'mentionAccountIds': [aiAccount],
        },
      },
    ),
  );

  Future<List<Map<String, Object?>>> sync(String conversation) async {
    final page = json(
      await call(
        'GET',
        Routes.sync.replaceFirst('{conversationId}', conversation),
      ),
    );
    return [
      for (final row in page['messages'] as List)
        (row as Map).cast<String, Object?>(),
    ];
  }

  String statusPath(String conversation, String source) => Routes
      .ownerAiReplyStatus
      .replaceFirst('{conversationId}', conversation)
      .replaceFirst('{messageId}', source);

  Future<String> open() async {
    final initial = json(await call('GET', consentPath));
    expect(initial, containsPair('enabled', false));
    expect(initial, containsPair('revision', 0));
    expect(await db.query('SELECT * FROM owner_ai_direct_grants'), isEmpty);
    final opened = json(
      await call('POST', consentPath, body: {'expectedRevision': 0}),
    );
    expect(opened['scope'], 'ownerTextOnly');
    expect(opened['aiProfileId'], profile);
    expect(opened['aiAccountId'], aiAccount);
    return opened['conversationId'] as String;
  }

  setUp(() async {
    clock.set(DateTime.utc(2026, 11, 17, 4));
    directory = await Directory.systemTemp.createTemp(
      'owner-ai-direct-reply-host-',
    );
    host = await buildHost(
      config: HostConfig(dataDir: directory.path),
      clock: clock,
    );
    db = host.registry.services.get<Database>();
    expect(host.registry.services.maybeGet<ModelRuntime>(), isNull);
    for (final human in [owner, 'other']) {
      await db.execute(
        '''INSERT INTO account
(id,display_name,kind,is_admin,disabled,password_hash,failed_passwords,locked_until)
VALUES(?,?,'human',0,0,'synthetic-not-a-login-secret',0,0)''',
        [human, human],
      );
    }
    await db.execute(
      '''INSERT INTO account
(id,display_name,kind,is_admin,disabled,password_hash,failed_passwords,locked_until)
VALUES(?,?,'ai',0,0,NULL,0,0)''',
      [aiAccount, 'Synthetic AI'],
    );
    await db.execute('INSERT INTO ai_operator(ai_id,operator_id) VALUES(?,?)', [
      aiAccount,
      owner,
    ]);
    await db.execute('INSERT INTO ai_profile(id,account_id) VALUES(?,?)', [
      profile,
      aiAccount,
    ]);
    for (final pair in [(owner, ownerToken), ('other', otherToken)]) {
      final device = '${pair.$1}-device';
      await db.execute('INSERT INTO device VALUES(?,?,?,?,?,?)', [
        device,
        pair.$1,
        'synthetic test device',
        sha256.convert(utf8.encode(pair.$2)).toString(),
        clock.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
        clock.now().millisecondsSinceEpoch,
      ]);
      await db.execute('INSERT INTO refresh_token VALUES(?,?,?)', [
        device,
        sha256.convert(utf8.encode('synthetic-refresh-${pair.$1}')).toString(),
        clock.now().add(const Duration(days: 1)).millisecondsSinceEpoch,
      ]);
    }
    // A real persona initialization through owner authentication, no plaintext
    // persona fixture bypass of the encryption/storage contract.
    json(
      await call(
        'POST',
        Routes.aiPersonaInitialize.replaceFirst('{aiId}', profile),
        body: {
          'p0': {'name': 'Synthetic AI', 'boundary': 'Respect private data'},
          'p1': {'style': 'brief and warm'},
          'p2': {'mood': 'calm'},
        },
      ),
    );
    await db.execute('INSERT INTO ai_social_levels VALUES(?,?,?,?)', [
      owner,
      profile,
      'L0',
      clock.now().toIso8601String(),
    ]);
    await db.execute(
      '''INSERT INTO usage_budget
(owner_id,ai_id,daily_tokens,layer_limits,capability_limits,offset_minutes)
VALUES(?,?,?,?,?,?)''',
      [
        owner,
        profile,
        '10000',
        jsonEncode({
          for (final layer in BudgetLayer.values)
            layer.name: layer == BudgetLayer.b1FastBrain
                ? '1000'
                : layer == BudgetLayer.b2DeepChat
                ? '8000'
                : '0',
        }),
        jsonEncode({
          for (final capability in [
            'chat',
            'chatFast',
            'vision',
            'imageGen',
            'tts',
            'asr',
            'embedding',
          ])
            capability: capability == 'chat'
                ? '8000'
                : capability == 'chatFast'
                ? '1000'
                : '0',
        }),
        480,
      ],
    );
  });

  tearDown(() async {
    await host.shutdown();
    await directory.delete(recursive: true);
  });

  test(
    'default host L0 owner text replies canonical S1 exactly once and retains history/status after revoke',
    () async {
      final conversation = await open();
      final accepted = await post(conversation, 'owner-simple-1', '你好');
      expect(accepted['duplicate'], false);
      final sourceId = (accepted['message'] as Map)['messageId'] as String;
      final messages = await sync(conversation);
      expect(
        messages,
        hasLength(2),
        reason:
            'default root must dispatch eligible owner text, not only register consent',
      );
      expect(messages.first['messageId'], sourceId);
      expect(messages.first['senderId'], owner);
      expect(messages.last['senderId'], aiAccount);
      expect(messages.last['body'], {
        'text': '你好呀',
        'source': 's1',
        'activityRefs': [],
      });
      expect(messages.last['seq'], (messages.first['seq'] as int) + 1);
      final status = json(
        await call('GET', statusPath(conversation, sourceId)),
      );
      expect(status['status'], 'completed');
      expect(status['sourceMessageId'], sourceId);
      expect(status['replyMessageId'], messages.last['messageId']);
      expect(status.containsKey('body'), false);
      expect(
        (await post(conversation, 'owner-simple-1', '你好'))['duplicate'],
        true,
      );
      expect(await sync(conversation), hasLength(2));
      expect(
        await db.query(
          'SELECT * FROM owner_reply_attempts WHERE source_message_id=? AND ai_profile_id=?',
          [sourceId, profile],
        ),
        hasLength(1),
      );
      expect(
        await db.query(
          'SELECT * FROM owner_ai_direct_sources WHERE source_message_id=?',
          [sourceId],
        ),
        hasLength(1),
      );
      expect(
        (await call(
          'GET',
          statusPath(conversation, sourceId),
          bearer: otherToken,
        )).status,
        404,
      );
      json(await call('DELETE', consentPath, body: {'expectedRevision': 1}));
      final rejected = await call(
        'POST',
        Routes.messages.replaceFirst('{conversationId}', conversation),
        body: {
          'clientMsgId': 'after-revoke',
          'kind': 'text',
          'body': {'text': '你好'},
        },
      );
      expect(rejected.status, 404);
      expect(await sync(conversation), hasLength(2));
      expect(
        json(await call('GET', statusPath(conversation, sourceId)))['status'],
        'completed',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'complex owner text without runtime remains persisted with failed model_unavailable status and no AI reply',
    () async {
      final conversation = await open();
      const text = '请解释这个复杂问题，并给出详细分析和具体步骤？';
      final accepted = await post(conversation, 'owner-complex-1', text);
      final sourceId = (accepted['message'] as Map)['messageId'] as String;
      final messages = await sync(conversation);
      expect(messages, hasLength(1));
      expect(messages.single['senderId'], owner);
      expect(messages.single['body'], {'text': text});
      final status = json(
        await call('GET', statusPath(conversation, sourceId)),
      );
      expect(status['status'], 'failed');
      expect(status['failureCode'], 'model_unavailable');
      expect(status.containsKey('replyMessageId'), false);
      expect(
        await db.query(
          'SELECT * FROM owner_reply_attempts WHERE source_message_id=?',
          [sourceId],
        ),
        hasLength(1),
      );
      expect(
        (await post(conversation, 'owner-complex-1', text))['duplicate'],
        true,
      );
      expect(await sync(conversation), hasLength(1));
      expect(
        json(await call('GET', statusPath(conversation, sourceId)))['status'],
        'failed',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  for (final gate in [
    'missing budget',
    'daily cap zero',
    'pending chatFast usage',
  ]) {
    test(
      'default host S1 $gate fails closed and preserves human input',
      () async {
        final conversation = await open();
        if (gate == 'missing budget') {
          await db.execute(
            'DELETE FROM usage_budget WHERE owner_id=? AND ai_id=?',
            [owner, profile],
          );
        } else if (gate == 'daily cap zero') {
          await db.execute(
            'UPDATE usage_budget SET daily_tokens=? WHERE owner_id=? AND ai_id=?',
            ['0', owner, profile],
          );
        } else {
          await db.execute(
            '''INSERT INTO usage_ledger
(owner_id,ai_id,request_id,budget_day,offset_minutes,layer,capability,source_usage_unknown)
VALUES(?,?,?,?,?,?,?,1)''',
            [
              owner,
              profile,
              'synthetic-pending-fast',
              '2026-11-17',
              480,
              BudgetLayer.b1FastBrain.name,
              'chatFast',
            ],
          );
        }
        final accepted = await post(conversation, 'budget-gated-source', '你好');
        expect(accepted['duplicate'], false);
        final sourceId = (accepted['message'] as Map)['messageId'] as String;
        final messages = await sync(conversation);
        expect(messages, hasLength(1));
        expect(messages.single['messageId'], sourceId);
        expect(messages.single['senderId'], owner);
        expect(messages.single['body'], {'text': '你好'});
        final status = json(
          await call('GET', statusPath(conversation, sourceId)),
        );
        expect(status['status'], 'failed');
        expect(status['failureCode'], 'budget_exhausted');
        expect(status.containsKey('replyMessageId'), false);
        expect(
          await db.query(
            'SELECT * FROM owner_reply_attempts WHERE source_message_id=?',
            [sourceId],
          ),
          hasLength(1),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  }

  test(
    'default root fanout preserves one positive group S1 reply without owner dispatch',
    () async {
      await open();
      await db.execute(
        'UPDATE ai_social_levels SET level=? WHERE owner_id=? AND ai_profile_id=?',
        ['L1', owner, profile],
      );
      await db.execute(
        "INSERT INTO social_conversations VALUES('positive-group',?,'Synthetic group','all',0)",
        [owner],
      );
      for (final member in [owner, 'other', aiAccount]) {
        await db.execute('INSERT INTO social_members VALUES(?,?,0,1)', [
          'positive-group',
          member,
        ]);
      }
      await db.execute(
        "INSERT INTO group_ai_settings VALUES('positive-group',30000,1,10,0,600000,0,0)",
      );
      final accepted = await post(
        'positive-group',
        'group-simple-source',
        '你好',
        mention: true,
      );
      final sourceId = (accepted['message'] as Map)['messageId'] as String;
      final messages = await sync('positive-group');
      expect(messages, hasLength(2));
      expect(messages.first['senderId'], owner);
      expect(messages.last['senderId'], aiAccount);
      expect(messages.last['body'], {
        'text': '你好呀',
        'source': 's1',
        'activityRefs': [],
      });
      expect(
        (await post(
          'positive-group',
          'group-simple-source',
          '你好',
          mention: true,
        ))['duplicate'],
        true,
      );
      expect(await sync('positive-group'), hasLength(2));
      expect(await db.query('SELECT * FROM group_ai_admissions'), hasLength(1));
      expect(
        await db.query(
          'SELECT * FROM owner_reply_attempts WHERE source_message_id=?',
          [sourceId],
        ),
        isEmpty,
      );
      expect(
        await db.query(
          'SELECT * FROM owner_ai_direct_sources WHERE source_message_id=?',
          [sourceId],
        ),
        isEmpty,
      );
      expect(
        (await call('GET', statusPath('positive-group', sourceId))).status,
        404,
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'group complex text never enters owner direct dispatcher or attempt ledger',
    () async {
      await open(); // Existing consent must not authorize a group source.
      await db.execute(
        "INSERT INTO social_conversations VALUES('group',?,'Synthetic group','all',0)",
        [owner],
      );
      for (final member in [owner, 'other', aiAccount]) {
        await db.execute('INSERT INTO social_members VALUES(?,?,0,1)', [
          'group',
          member,
        ]);
      }
      await db.execute(
        "INSERT INTO group_ai_settings VALUES('group',30000,1,10,0,600000,0,0)",
      );
      const text = '请分析群里的这个复杂问题并给出详细步骤？';
      final accepted = await post(
        'group',
        'group-complex-1',
        text,
        mention: true,
      );
      final sourceId = (accepted['message'] as Map)['messageId'] as String;
      final messages = await sync('group');
      expect(messages, hasLength(1));
      expect(messages.single['senderId'], owner);
      expect(
        await db.query(
          'SELECT * FROM owner_reply_attempts WHERE source_message_id=?',
          [sourceId],
        ),
        isEmpty,
      );
      expect(
        await db.query(
          'SELECT * FROM owner_ai_direct_sources WHERE source_message_id=?',
          [sourceId],
        ),
        isEmpty,
      );
      expect((await call('GET', statusPath('group', sourceId))).status, 404);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
