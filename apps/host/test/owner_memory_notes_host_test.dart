import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/messages/accepted_message_observer.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/brain/owner_ai_direct_incoming.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

const _owner = 'memory-owner';
const _other = 'memory-other';
const _ai = 'memory-ai';
const _profile = 'memory-profile';
const _notes = '/api/v1/ai-profiles/$_profile/owner-memory-notes';
const _settings = '$_notes/settings';
const _consent = '/api/v1/ai-profiles/$_profile/direct-conversation';
const _budget = '/api/v1/ai-profiles/$_profile/budget';

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() async {
    await f.close();
    await f.directory.delete(recursive: true);
  });

  test('default is read-only, owner-only and has no implicit grant', () async {
    expect(await f.ok('GET', _notes), {
      'revision': 0,
      'enabled': false,
      'maxNotes': 20,
      'maxNoteBytes': 512,
      'notes': <Object?>[],
      'target': null,
    });
    expect(await f.db.query('SELECT * FROM owner_memory_notes'), isEmpty);
    expect(
      await f.db.query('SELECT * FROM owner_memory_note_settings'),
      isEmpty,
    );
    expect((await f.call('GET', _notes, actor: null)).status, 401);
    expect((await f.call('GET', _notes, actor: _other)).status, 404);
    expect((await f.call('GET', _notes, actor: _ai)).status, 404);
    expect(
      (await f.call(
        'POST',
        _notes,
        actor: _other,
        body: {'text': 'x', 'expectedRevision': 0},
      )).status,
      404,
    );
    expect(
      (await f.call(
        'PUT',
        _settings,
        body: {
          'expectedRevision': 0,
          'enabled': true,
          'expectedTargetToken': 'missing',
        },
      )).status,
      409,
    );
    expect((await f.ok('GET', _notes))['enabled'], false);
  });

  test(
    'notes are strict, encrypted, bounded, editable, clearable and audited without body',
    () async {
      await f.prerequisites();
      for (final body in [
        {'text': ' ', 'expectedRevision': 0},
        {'text': List.filled(171, '花').join(), 'expectedRevision': 0},
        {'text': 'x\ny', 'expectedRevision': 0},
        {'text': 'x', 'expectedRevision': 0, 'tier': 't2'},
      ]) {
        expect((await f.call('POST', _notes, body: body)).status, 400);
      }
      expect(
        (await f.call(
          'POST',
          _notes,
          body: {'text': '你好', 'expectedRevision': 9},
        )).status,
        409,
      );
      final created = await f.ok(
        'POST',
        _notes,
        body: {'text': ' 喜欢桂花 ', 'expectedRevision': 0},
      );
      final note = (created['notes'] as List).single as Map;
      expect(note['text'], '喜欢桂花');
      expect(
        note.keys,
        unorderedEquals(['id', 'text', 'createdAt', 'updatedAt']),
      );
      expect(created['revision'], 1);
      final row = (await f.db.query('SELECT * FROM owner_memory_notes')).single;
      final sealed = row['encrypted_body']! as String;
      expect(sealed, startsWith('v1:'));
      expect(
        jsonEncode(await f.db.query('SELECT * FROM owner_memory_notes')),
        isNot(contains('喜欢桂花')),
      );
      final id = note['id']! as String;
      final edited = await f.ok(
        'PATCH',
        '$_notes/$id',
        body: {'text': '喜欢白色', 'expectedRevision': 1},
      );
      expect((edited['notes'] as List).single['text'], '喜欢白色');
      expect(edited['revision'], 2);
      expect(
        (await f.call(
          'PATCH',
          '$_notes/$id',
          body: {'text': 'bad', 'expectedRevision': 1},
        )).status,
        409,
      );
      final cleared = await f.ok(
        'DELETE',
        _notes,
        body: {'expectedRevision': 2},
      );
      expect(cleared['notes'], isEmpty);
      expect(cleared['revision'], 3);
      expect(await f.db.query('SELECT * FROM owner_memory_notes'), isEmpty);
      final audit = jsonEncode(await f.db.query('SELECT * FROM audit_log'));
      for (final sentinel in ['喜欢桂花', '喜欢白色', 'bad']) {
        expect(audit, isNot(contains(sentinel)));
      }
      expect(audit, contains('owner_memory_note.add'));
      expect(audit, contains('owner_memory_note.edit'));
      expect(audit, contains('owner_memory_note.clear'));
      expect(
        await f.db.query('SELECT * FROM owner_memory_note_sources'),
        isEmpty,
      );
    },
  );

  test('old accepted message cannot obtain notes enabled later', () async {
    final conversation = await f.prerequisites();
    final provider = await f.bind();
    final accepted = await f.acceptWithoutObserver(conversation, 'old-source');
    final offered = (await f.ok('GET', _notes))['target']! as Map;
    expect(
      offered.keys,
      unorderedEquals(['providerId', 'model', 'origin', 'token']),
    );
    expect(offered['providerId'], provider);
    expect(offered['model'], 'fixture-model');
    expect(offered['origin'], 'https://192.0.2.1');
    await f.ok(
      'PUT',
      _settings,
      body: {
        'expectedRevision': 0,
        'enabled': true,
        'expectedTargetToken': offered['token'],
      },
    );
    await f.ok('POST', _notes, body: {'text': '喜欢桂花', 'expectedRevision': 1});
    final observer = f.host.registry.services.get<AcceptedMessageObserver>();
    await observer.onAccepted(accepted);
    expect(f.workerSeen, hasLength(2));
    expect(
      (await f.sync(conversation)).last['body'],
      containsPair('text', 'ordinary'),
    );
  });

  test(
    'B2 worker receives only bounded labeled notes and never system/history',
    () async {
      final conversation = await f.prerequisites();
      await f.bind();
      final target = (await f.ok('GET', _notes))['target']! as Map;
      await f.ok(
        'PUT',
        _settings,
        body: {
          'expectedRevision': 0,
          'enabled': true,
          'expectedTargetToken': target['token'],
        },
      );
      await f.ok('POST', _notes, body: {'text': '喜欢桂花', 'expectedRevision': 1});
      await f.send(conversation, 'with-memory', question: '为什么？请解释。');
      final messages = await f.sync(conversation);
      expect(messages.last['senderId'], _ai);
      expect((messages.last['body'] as Map)['text'], 'memory:喜欢桂花');
      expect(f.workerSeen, isNotNull);
      final turns = f.workerSeen!;
      expect(turns.first['role'], 'system');
      expect((turns.first['content'] as String).contains('喜欢桂花'), isFalse);
      expect(turns, hasLength(3));
      final recall = jsonDecode(turns[1]['content'] as String) as Map;
      expect(recall['kind'], 'untrusted_owner_memory_notes');
      expect(recall['notes'], ['喜欢桂花']);
      expect(turns.last, {'role': 'user', 'content': '为什么？请解释。'});
      // Clear notes and prove the next B2 call has no memory turn.
      await f.ok('DELETE', _notes, body: {'expectedRevision': 2});
      await f.send(conversation, 'without-memory', question: '为什么？请解释。');
      final plain = await f.sync(conversation);
      expect((plain.last['body'] as Map)['text'], 'ordinary');
      expect(f.workerSeen, hasLength(2));
    },
  );

  test(
    'retains at most twenty notes and clear removes the complete set',
    () async {
      await f.prerequisites();
      for (var i = 0; i < 20; i++) {
        await f.ok(
          'POST',
          _notes,
          body: {'text': 'note$i', 'expectedRevision': i},
        );
      }
      expect(
        (await f.call(
          'POST',
          _notes,
          body: {'text': 'overflow', 'expectedRevision': 20},
        )).status,
        400,
      );
      final full = await f.ok('GET', _notes);
      expect(full['notes'] as List, hasLength(20));
      final cleared = await f.ok(
        'DELETE',
        _notes,
        body: {'expectedRevision': 20},
      );
      expect(cleared['notes'], isEmpty);
      expect(await f.db.query('SELECT * FROM owner_memory_notes'), isEmpty);
    },
  );

  test(
    'editing a note after acceptance blocks the old source snapshot',
    () async {
      final conversation = await f.prerequisites();
      await f.bind();
      final target = (await f.ok('GET', _notes))['target']! as Map;
      await f.ok(
        'PUT',
        _settings,
        body: {
          'expectedRevision': 0,
          'enabled': true,
          'expectedTargetToken': target['token'],
        },
      );
      final added = await f.ok(
        'POST',
        _notes,
        body: {'text': '旧便签', 'expectedRevision': 1},
      );
      final accepted = await f.acceptWithoutObserver(
        conversation,
        'edited-source',
      );
      await f.ok(
        'PATCH',
        '$_notes/${((added['notes'] as List).single as Map)['id']}',
        body: {'text': '新便签', 'expectedRevision': 2},
      );
      final observer = f.host.registry.services.get<AcceptedMessageObserver>();
      await observer.onAccepted(accepted);
      expect(
        (await f.sync(conversation)).last['body'],
        containsPair('text', 'ordinary'),
      );
      expect(f.workerSeen, hasLength(2));
    },
  );

  test(
    'more than five saved notes are deterministically capped at five',
    () async {
      final conversation = await f.prerequisites();
      await f.bind();
      final target = (await f.ok('GET', _notes))['target']! as Map;
      await f.ok(
        'PUT',
        _settings,
        body: {
          'expectedRevision': 0,
          'enabled': true,
          'expectedTargetToken': target['token'],
        },
      );
      for (var i = 1; i <= 6; i++) {
        f.clock.advance(const Duration(seconds: 1));
        await f.ok(
          'POST',
          _notes,
          body: {'text': 'note$i', 'expectedRevision': i},
        );
      }
      await f.send(conversation, 'five-notes', question: '为什么？请解释。');
      expect(
        (await f.sync(conversation)).last['body'],
        containsPair('text', 'memory:5'),
      );
      final turns = f.workerSeen!;
      expect(turns, hasLength(3));
      final recall = jsonDecode(turns[1]['content'] as String) as Map;
      expect(recall['notes'], ['note6', 'note5', 'note4', 'note3', 'note2']);
    },
  );

  test(
    'target changes and a restart do not revive a remembered target',
    () async {
      await f.prerequisites();
      final provider = await f.bind();
      final initial = (await f.ok('GET', _notes))['target']! as Map;
      await f.ok(
        'PUT',
        _settings,
        body: {
          'expectedRevision': 0,
          'enabled': true,
          'expectedTargetToken': initial['token'],
        },
      );
      await f.changeProvider(provider, 'https://192.0.2.1/changed');
      final changed = await f.ok('GET', _notes);
      expect(changed['enabled'], false);
      expect(changed['target'], isNotNull);
      expect((changed['target'] as Map)['token'], isNot(initial['token']));
      expect(
        (await f.call(
          'PUT',
          _settings,
          body: {
            'expectedRevision': 1,
            'enabled': true,
            'expectedTargetToken': initial['token'],
          },
        )).status,
        409,
      );
      await f.restart();
      expect((await f.ok('GET', _notes))['enabled'], false);
      await f.ok(
        'PUT',
        _settings,
        body: {
          'expectedRevision': 2,
          'enabled': false,
          'expectedTargetToken': null,
        },
      );
      expect((await f.ok('GET', _notes))['enabled'], false);
    },
  );
}

final class _Fixture {
  _Fixture(this.directory);
  final Directory directory;
  final clock = FakeClock(DateTime.utc(2026, 1, 1, 9));
  final tokens = <String, String>{};
  late Host host;
  List<Map<String, Object?>>? get workerSeen {
    final file = File('${directory.path}/worker_seen.json');
    if (!file.existsSync()) return null;
    return (jsonDecode(file.readAsStringSync()) as List)
        .cast<Map<String, Object?>>();
  }

  Database get db => host.registry.services.get<Database>();
  String get workerPath => '${directory.path}/fixture_worker.dart';

  static Future<_Fixture> create() async {
    final dir = await Directory.systemTemp.createTemp('owner-memory-notes-');
    final f = _Fixture(dir);
    await File(f.workerPath).writeAsString(_worker);
    await f.boot();
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

  Future<void> boot() async => host = await buildHost(
    config: HostConfig(
      dataDir: directory.path,
      modelWorkerExecutable: Platform.resolvedExecutable,
      modelWorkerPath: workerPath,
    ),
    clock: clock,
  );
  Future<void> restart() async {
    expect(await host.shutdown(), isEmpty);
    await boot();
  }

  Future<void> close() async {
    expect(await host.shutdown(), isEmpty);
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
    final r = await call(method, path, body: body);
    expect(r.status, 200, reason: '$method $path');
    return (r.json! as Map).cast<String, Object?>();
  }

  Future<String> prerequisites() async {
    final chat = await ok('POST', _consent, body: {'expectedRevision': 0});
    await ok(
      'POST',
      Routes.aiPersonaInitialize.replaceFirst('{aiId}', _profile),
      body: {
        'p0': {'name': '小鲸'},
        'p1': {'style': '简洁'},
        'p2': {'mood': '平静'},
      },
    );
    await ok(
      'PUT',
      _budget,
      body: {
        'dailyTokens': 12000,
        'offsetMinutes': 0,
        'layerLimits': {
          for (final l in BudgetLayer.values)
            l.name: l == BudgetLayer.b2DeepChat
                ? 8000
                : l == BudgetLayer.b1FastBrain
                ? 1000
                : 0,
        },
        'capabilityLimits': {
          for (final c in [
            'chat',
            'chatFast',
            'tts',
            'asr',
            'vision',
            'imageGen',
            'embedding',
          ])
            c: c == 'chat'
                ? 8000
                : c == 'chatFast'
                ? 1000
                : 0,
        },
      },
    );
    return chat['conversationId']! as String;
  }

  Future<String> bind() async {
    final p = await ok(
      'POST',
      Routes.modelProviders,
      body: {
        'name': 'Synthetic',
        'base_url': 'https://192.0.2.1/v1',
        'api_key': 'synthetic-only',
        'capabilities': ['chat'],
      },
    );
    final id = p['id']! as String;
    await ok(
      'PUT',
      Routes.aiBinding
          .replaceFirst('{aiId}', _profile)
          .replaceFirst('{capability}', 'chat'),
      body: {'providerId': id, 'model': 'fixture-model'},
    );
    return id;
  }

  Future<void> changeProvider(String id, String url) async => ok(
    'PUT',
    Routes.modelProvider.replaceFirst('{providerId}', id),
    body: {'base_url': url},
  );

  Future<void> send(
    String conversation,
    String clientId, {
    required String question,
  }) async => ok(
    'POST',
    Routes.messages.replaceFirst('{conversationId}', conversation),
    body: {
      'clientMsgId': clientId,
      'kind': 'text',
      'body': {'text': question},
    },
  );
  Future<List<Map<String, Object?>>> sync(String id) async =>
      ((await ok(
                'GET',
                Routes.sync.replaceFirst('{conversationId}', id),
              ))['messages']!
              as List)
          .cast<Map<String, Object?>>();

  Future<StoredMessage> acceptWithoutObserver(
    String conversation,
    String clientId,
  ) async {
    final messages = SqliteMessageStore(
      database: db,
      cipher: host.registry.services.get<ColumnCipher>(),
      clock: clock,
    );
    final accepted =
        await OwnerAiDirectIncoming(database: db, messages: messages).append(
          conversationId: conversation,
          senderId: _owner,
          clientMsgId: clientId,
          kind: MessageKind.text,
          body: {'text': '为什么？请解释。'},
        );
    expect(accepted.isOk, true);
    return accepted.value.message;
  }
}

// Kept exact: a real subprocess sees the production adapter turns. It never
// opens a socket; the configured endpoint is TEST-NET and parsed only.
const _worker = r'''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final req = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;
  final payload = jsonDecode(utf8.decode(base64Decode(req['body'] as String))) as Map;
  final turns = payload['messages'] as List;
  File('${File.fromUri(Platform.script).parent.path}/worker_seen.json').writeAsStringSync(jsonEncode(turns));
  if (req['method'] != 'POST' || payload['model'] != 'fixture-model' || payload['max_tokens'] != 512 || payload['stream'] != false) {
    stdout.writeln('{"ok":false,"code":"unavailable"}'); return;
  }
  var text = 'ordinary';
  if (turns.length == 3) {
    final data = jsonDecode(turns[1]['content'] as String) as Map;
    final notes = data['notes'] as List;
    final one = notes.length == 1 && notes.single == '喜欢桂花';
    final five = notes.length == 5 &&
        notes.every((note) => note is String && note.startsWith('note'));
    if (data['kind'] != 'untrusted_owner_memory_notes' || !(one || five)) {
      stdout.writeln('{"ok":false,"code":"unavailable"}'); return;
    }
    text = five ? 'memory:5' : 'memory:喜欢桂花';
  } else if (turns.length != 2) {
    stdout.writeln('{"ok":false,"code":"unavailable"}'); return;
  }
  final response = jsonEncode({'choices': [{'message': {'role': 'assistant', 'content': text}}], 'usage': {'prompt_tokens': 7, 'completion_tokens': 3, 'total_tokens': 10}});
  stdout.writeln(jsonEncode({'ok': true, 'statusCode': 200, 'headers': {}, 'body': base64Encode(utf8.encode(response))}));
}
''';
