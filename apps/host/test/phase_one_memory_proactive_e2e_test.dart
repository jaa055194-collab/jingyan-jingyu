import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/ai/life/owner_model_proactive.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

/// End-to-end acceptance for the two phase-one hard gates over a real host:
///
/// 1. chat-history auto-memory: default off, opt-in, owner-private only,
///    list/delete/clear, injected into the B2 own-DM reply;
/// 2. model proactive contact: default off, quiet window, interval cap, a
///    generated (never rule-greeting) message, no duplicate send.
///
/// Everything runs against real SQLite, the real default module graph, a real
/// loopback HTTP listener and a real child model worker process. No user data,
/// no external provider, no device.
const _owner = 'e2e-owner';
const _other = 'e2e-other';
const _aiAccount = 'e2e-ai';
const _profile = 'e2e-profile';
const _offlineBase = 'https://192.0.2.1/v1';
const _maxDuration = Duration(minutes: 4);

const _autoSettings =
    '/api/v1/ai-profiles/$_profile/owner-auto-memory/settings';
const _autoEntries = '/api/v1/ai-profiles/$_profile/owner-auto-memory';
const _proactive = '/api/v1/ai-profiles/$_profile/owner-model-proactive';
const _proactiveStop = '/api/v1/accounts/me/owner-model-proactive';
const _consent = '/api/v1/ai-profiles/$_profile/direct-conversation';

const _remember = '请记住我喜欢桂花。';
const _casual = '今天有点累。';
const _ask = '为什么？请解释一下。';
const _afterRevoke = '请记住我讨厌下雨。';
const _flower = '桂花';
const _tired = '有点累';

void main() {
  test(
    'real host: opt-in auto memory and model proactive contact end to end',
    () async {
      final elapsed = Stopwatch()..start();
      Duration remaining() {
        final left = _maxDuration - elapsed.elapsed;
        if (left <= Duration.zero) fail('Acceptance deadline exceeded');
        return left;
      }

      final directory = await Directory.systemTemp.createTemp(
        'phase-one-e2e-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final worker = File('${directory.path}/worker.dart');
      await worker.writeAsString(_worker);
      final clock = FakeClock(DateTime.utc(2026, 11, 22, 0, 30));
      final config = HostConfig(
        dataDir: directory.path,
        modelWorkerExecutable: File(Platform.resolvedExecutable).absolute.path,
        modelWorkerPath: worker.path,
      );
      final random = Random.secure();
      String token() => base64UrlEncode(
        List.generate(16, (_) => random.nextInt(256)),
      ).replaceAll('=', '');
      final ownerToken = token();
      final otherToken = token();

      final host = await buildHost(config: config, clock: clock);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serving = serve(server, host.pipeline);
      final client = _Client(
        server.port,
        remaining,
        File('${directory.path}/turns.json'),
      );
      addTearDown(() async {
        client.close();
        await server.close(force: true);
        await serving;
        final errors = await host.shutdown();
        expect(errors, isEmpty);
      });
      await _seed(host, clock, {_owner: ownerToken, _other: otherToken});

      // ---- Both features default off: no rows, no permission ----
      expect(await client.call('GET', _autoSettings, token: ownerToken), {
        'revision': 0,
        'enabled': false,
        'target': null,
      });
      expect(await client.call('GET', _autoEntries, token: ownerToken), {
        'revision': 0,
        'maxEntries': 50,
        'entries': <Object?>[],
      });
      final initialProactive = await client.call(
        'GET',
        _proactive,
        token: ownerToken,
      );
      expect(initialProactive['enabled'], false);
      expect(initialProactive['globalBlocked'], false);
      expect(initialProactive['intervalMinutes'], 1440);
      expect(initialProactive['quietStartMinute'], 1380);
      expect(initialProactive['quietEndMinute'], 480);
      final db = host.registry.services.get<Database>();
      expect(
        await db.query('SELECT * FROM owner_auto_memory_settings'),
        isEmpty,
      );
      expect(await db.query('SELECT * FROM owner_model_proactive'), isEmpty);
      expect(await db.query('SELECT * FROM encrypted_memory'), isEmpty);
      // Anonymous and non-owner are refused, never silently granted.
      await client.call('GET', _autoSettings, expectedStatus: 401);
      await client.call(
        'GET',
        _autoEntries,
        token: otherToken,
        expectedStatus: 404,
      );
      await client.call(
        'GET',
        _proactive,
        token: otherToken,
        expectedStatus: 404,
      );

      // ---- Prerequisites: own-DM consent, persona, budget, chat binding ----
      final grant = await client.call(
        'POST',
        _consent,
        token: ownerToken,
        body: {'expectedRevision': 0},
      );
      final conversation = grant['conversationId']! as String;
      final syncPath = Routes.sync.replaceFirst(
        '{conversationId}',
        conversation,
      );
      await client.call(
        'POST',
        Routes.aiPersonaInitialize.replaceFirst('{aiId}', _profile),
        token: ownerToken,
        body: {
          'p0': {'name': '小鲸'},
          'p1': {'style': '简洁'},
          'p2': {'mood': '平静'},
        },
      );
      await client.call(
        'PUT',
        Routes.aiBudget.replaceFirst('{aiId}', _profile),
        token: ownerToken,
        body: {
          'dailyTokens': 20000,
          'offsetMinutes': 480,
          'layerLimits': {
            for (final layer in BudgetLayer.values)
              layer.name: switch (layer) {
                BudgetLayer.b2DeepChat => 8000,
                BudgetLayer.b3Proactive => 8000,
                BudgetLayer.b1FastBrain => 2000,
                _ => 0,
              },
          },
          'capabilityLimits': {
            for (final cap in ProviderCapability.values)
              cap.name: cap == ProviderCapability.chat ? 18000 : 0,
          },
        },
      );
      final provider = await client.call(
        'POST',
        Routes.modelProviders,
        token: ownerToken,
        body: {
          'name': 'Acceptance fixture',
          'base_url': _offlineBase,
          'api_key': 'synthetic-acceptance-key',
          'capabilities': ['chat'],
        },
      );
      await client.call(
        'PUT',
        Routes.aiBinding
            .replaceFirst('{aiId}', _profile)
            .replaceFirst('{capability}', 'chat'),
        token: ownerToken,
        body: {'providerId': provider['id'], 'model': 'auto'},
      );
      // L3 is required for model proactive contact; L2 must not enable.
      await client.call(
        'PUT',
        Routes.aiSocialLevel.replaceFirst('{aiId}', _profile),
        token: ownerToken,
        body: {'level': 'L2'},
      );
      final atL2 = await client.call('GET', _proactive, token: ownerToken);
      expect(atL2['socialLevel'], 'L2');
      await client.call(
        'PUT',
        _proactive,
        token: ownerToken,
        body: {
          'expectedRevision': atL2['revision'],
          'enabled': true,
          'localMinute': 540,
          'offsetMinutes': 480,
          'quietStartMinute': 1380,
          'quietEndMinute': 480,
          'intervalMinutes': 1440,
          'expectedChatRevision': atL2['chatRevision'],
          'expectedGlobalRevision': atL2['globalRevision'],
        },
        expectedStatus: 409,
      );
      await client.call(
        'PUT',
        Routes.aiSocialLevel.replaceFirst('{aiId}', _profile),
        token: ownerToken,
        body: {'level': 'L3'},
      );

      // ---- Gate 1: chat-history auto memory ----
      final offered = await client.call('GET', _autoSettings, token: ownerToken);
      expect(offered['enabled'], false);
      final target = offered['target']! as Map<Object?, Object?>;
      expect(target['providerId'], provider['id']);
      expect(target['model'], 'auto');
      // Enabling requires the exact reviewed target token.
      await client.call(
        'PUT',
        _autoSettings,
        token: ownerToken,
        body: {
          'expectedRevision': 0,
          'enabled': true,
          'expectedTargetToken': 'not-the-current-token',
        },
        expectedStatus: 400,
      );
      final enabled = await client.call(
        'PUT',
        _autoSettings,
        token: ownerToken,
        body: {
          'expectedRevision': 0,
          'enabled': true,
          'expectedTargetToken': target['token'],
        },
      );
      expect(enabled['enabled'], true);
      expect(enabled['revision'], 1);

      // An explicit memory instruction becomes active T0; other owner text is
      // pending T1 and is never injected.
      await _send(client, conversation, ownerToken, 'm1', _remember);
      await _send(client, conversation, ownerToken, 'm2', _casual);
      final captured = await client.call(
        'GET',
        _autoEntries,
        token: ownerToken,
      );
      final entries = (captured['entries']! as List)
          .cast<Map<Object?, Object?>>();
      expect(entries, hasLength(2));
      final remembered = entries.firstWhere(
        (e) => (e['text']! as String).contains(_flower),
      );
      final pending = entries.firstWhere(
        (e) => (e['text']! as String).contains(_tired),
      );
      expect(remembered['tier'], 't0');
      expect(remembered['status'], 'active');
      expect(pending['tier'], 't1');
      expect(pending['status'], 'pending');
      // Every stored row is owner-private and belongs to this AI only.
      final scopes = await db.query(
        'SELECT scope_key,encrypted_body FROM encrypted_memory',
      );
      expect(scopes, hasLength(2));
      for (final row in scopes) {
        expect(row['scope_key'], 'private:$_profile:$_owner');
        expect(row['encrypted_body']! as String, startsWith('v1:'));
      }
      final raw = jsonEncode(await db.query('SELECT * FROM encrypted_memory'));
      for (final secret in [_flower, _tired]) {
        expect(raw, isNot(contains(secret)), reason: 'ciphertext at rest');
      }
      final audit = jsonEncode(await db.query('SELECT * FROM audit_log'));
      for (final secret in [_flower, _tired]) {
        expect(audit, isNot(contains(secret)), reason: 'no body in audit');
      }

      // The next B2 reply carries the active memory as its own labeled segment
      // and never the pending one.
      await _send(client, conversation, ownerToken, 'm3', _ask);
      final memoryTurns = client.readChatTurns();
      expect(memoryTurns.first['role'], 'system');
      expect(
        (memoryTurns.first['content']! as String).contains(_flower),
        isFalse,
        reason: 'never promoted into the system prompt',
      );
      final injected = memoryTurns
          .map((turn) => turn['content']! as String)
          .where((text) => text.contains('untrusted_owner_memory'))
          .toList();
      expect(injected, hasLength(1), reason: 'one auto-memory segment');
      final segment = jsonDecode(injected.single) as Map<Object?, Object?>;
      expect(segment['kind'], 'untrusted_owner_memory');
      expect((segment['entries']! as List).single, contains(_flower));
      expect(
        (segment['entries']! as List).join(),
        isNot(contains(_tired)),
        reason: 'pending is never injected',
      );
      expect(memoryTurns.last, {'role': 'user', 'content': _ask});
      // The reply really is the model's, published as a normal s2 message.
      final afterMemory = await client.call('GET', syncPath, token: ownerToken);
      final memoryReply = (afterMemory['messages']! as List).last as Map;
      expect(memoryReply['senderId'], _aiAccount);
      expect((memoryReply['body']! as Map)['source'], 's2');

      // Revoking the grant stops capture immediately; delete and clear work.
      final revoke = await client.call(
        'PUT',
        _autoSettings,
        token: ownerToken,
        body: {
          'expectedRevision': 1,
          'enabled': false,
          'expectedTargetToken': null,
        },
      );
      expect(revoke['enabled'], false);
      await _send(client, conversation, ownerToken, 'm4', _afterRevoke);
      final afterRevokeRead = await client.call(
        'GET',
        _autoEntries,
        token: ownerToken,
      );
      expect(
        (afterRevokeRead['entries']! as List),
        hasLength(3),
        reason: 'revoked grant captures nothing new (m1-m3 only)',
      );
      final deleted = await client.call(
        'DELETE',
        '$_autoEntries/${remembered['id']}',
        token: ownerToken,
        body: {'expectedRevision': revoke['revision']},
      );
      expect(
        (deleted['entries']! as List)
            .cast<Map<Object?, Object?>>()
            .any((e) => e['id'] == remembered['id']),
        isFalse,
      );
      final cleared = await client.call(
        'DELETE',
        _autoEntries,
        token: ownerToken,
        body: {'expectedRevision': deleted['revision']},
      );
      expect(cleared['entries'], isEmpty);

      // ---- Gate 2: model proactive contact ----
      final ready = await client.call('GET', _proactive, token: ownerToken);
      expect(ready['socialLevel'], 'L3');
      expect(ready['budgetReady'], true);
      expect(ready['chatRevision'], isNotNull);
      final opened = await client.call(
        'PUT',
        _proactive,
        token: ownerToken,
        body: {
          'expectedRevision': ready['revision'],
          'enabled': true,
          'localMinute': 540,
          'offsetMinutes': 480,
          'quietStartMinute': 1380,
          'quietEndMinute': 480,
          'intervalMinutes': 1440,
          'expectedChatRevision': ready['chatRevision'],
          'expectedGlobalRevision': ready['globalRevision'],
        },
      );
      expect(opened['enabled'], true);
      expect(opened['intervalMinutes'], 1440);

      // Drive the scheduler with the injected FakeClock: 09:00 local (01:00Z)
      // is the nominal slot; the quiet window is 23:00-08:00 local.
      final proactive = host.registry.services.get<OwnerModelProactive>();
      clock.set(DateTime.utc(2026, 11, 22, 0, 59, 50));
      await proactive.poll();
      clock.set(DateTime.utc(2026, 11, 22, 1, 0, 5));
      expect(await proactive.poll(), 1, reason: 'one proactive message sent');
      final afterProactive = await client.call(
        'GET',
        syncPath,
        token: ownerToken,
      );
      final messages = (afterProactive['messages']! as List).cast<Map<Object?, Object?>>();
      final proactiveMessage = messages.last;
      expect(proactiveMessage['senderId'], _aiAccount);
      final proactiveBody = proactiveMessage['body']! as Map;
      expect(proactiveBody['source'], 'owner_model_proactive');
      expect(proactiveBody['text'], 'proactive-model-reply');
      expect(
        proactiveBody['text'],
        isNot(contains('规则问候')),
        reason: 'never passed off as the fixed rule greeting',
      );
      // It cost B3/chat tokens and created no rule-greeting row.
      final usage = await client.call(
        'GET',
        Routes.aiUsage.replaceFirst('{aiId}', _profile),
        token: ownerToken,
      );
      final byLayer = (usage['byLayer']! as Map).cast<String, Object?>();
      expect(int.parse(byLayer['b3Proactive']! as String), greaterThan(0));
      expect(await db.query('SELECT * FROM owner_rule_greetings'), isEmpty);
      // No duplicate: the same slot cannot send twice, and the interval
      // watermark blocks a second send on the same local day.
      clock.set(DateTime.utc(2026, 11, 22, 1, 0, 15));
      expect(await proactive.poll(), 0);
      clock.set(DateTime.utc(2026, 11, 22, 2, 0, 5));
      expect(await proactive.poll(), 0);
      final once = await client.call('GET', syncPath, token: ownerToken);
      expect(
        (once['messages']! as List)
            .cast<Map<Object?, Object?>>()
            .where(
              (m) =>
                  (m['body']! as Map)['source'] == 'owner_model_proactive',
            ),
        hasLength(1),
        reason: 'exactly one proactive message',
      );

      // Quiet window defers; it never sends inside 23:00-08:00 local.
      final quiet = await client.call('GET', _proactive, token: ownerToken);
      final quieted = await client.call(
        'PUT',
        _proactive,
        token: ownerToken,
        body: {
          'expectedRevision': quiet['revision'],
          'enabled': true,
          'localMinute': 1400, // 23:20 local, inside the quiet window
          'offsetMinutes': 480,
          'quietStartMinute': 1380,
          'quietEndMinute': 480,
          'intervalMinutes': 60,
          'expectedChatRevision': quiet['chatRevision'],
          'expectedGlobalRevision': quiet['globalRevision'],
        },
      );
      expect(quieted['enabled'], true);
      clock.set(DateTime.utc(2026, 11, 23, 15, 19, 50)); // 23:19:50 local
      await proactive.poll();
      clock.set(DateTime.utc(2026, 11, 23, 15, 21, 0)); // 23:21 local, quiet
      expect(await proactive.poll(), 0, reason: 'quiet window sends nothing');
      final quietCheck = await client.call(
        'GET',
        syncPath,
        token: ownerToken,
      );
      expect(
        (quietCheck['messages']! as List)
            .cast<Map<Object?, Object?>>()
            .where(
              (m) =>
                  (m['body']! as Map)['source'] == 'owner_model_proactive',
            ),
        hasLength(1),
      );

      // Account-wide stop revokes and does not revive on release.
      expect(await client.call('GET', _proactiveStop, token: ownerToken), {
        'revision': 0,
        'blocked': false,
      });
      expect(
        await client.call(
          'PUT',
          _proactiveStop,
          token: ownerToken,
          body: {'expectedRevision': 0, 'blocked': true},
        ),
        {'revision': 1, 'blocked': true},
      );
      final afterStop = await client.call('GET', _proactive, token: ownerToken);
      expect(afterStop['globalBlocked'], true);
      expect(afterStop['enabled'], false);
      expect(
        await client.call(
          'PUT',
          _proactiveStop,
          token: ownerToken,
          body: {'expectedRevision': 1, 'blocked': false},
        ),
        {'revision': 2, 'blocked': false},
      );
      final afterRelease = await client.call(
        'GET',
        _proactive,
        token: ownerToken,
      );
      expect(afterRelease['globalBlocked'], false);
      expect(
        afterRelease['enabled'],
        false,
        reason: 'lifting the stop never revives the old permit',
      );

      // State persists across the read-back; nothing was replayed.
      expect(
        (await client.call('GET', _autoEntries, token: ownerToken))['entries'],
        isEmpty,
      );
      final finalSync = await client.call('GET', syncPath, token: ownerToken);
      print(
        'E2E_OK autoMemory=enabled,captured2,activeInjected,revoked,deleted,cleared '
        'proactive=sent1,deduped,quietDeferred,stopped,noRevive '
        'messages=${(finalSync['messages']! as List).length}',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _send(
  _Client client,
  String conversation,
  String token,
  String clientId,
  String text,
) async {
  final accepted = await client.call(
    'POST',
    Routes.messages.replaceFirst('{conversationId}', conversation),
    token: token,
    body: {
      'clientMsgId': clientId,
      'kind': 'text',
      'body': {'text': text},
    },
  );
  expect(accepted['duplicate'], false);
}

Future<void> _seed(Host host, Clock clock, Map<String, String> tokens) async {
  final now = clock.now().millisecondsSinceEpoch;
  String digest(String value) => sha256.convert(utf8.encode(value)).toString();
  await host.auth.store.transaction((state) {
    for (final entry in tokens.entries) {
      state.accounts[entry.key] = {
        'id': entry.key,
        'displayName': 'Synthetic ${entry.key}',
        'kind': 'human',
        'isAdmin': false,
        'disabled': false,
        'passwordHash': 'unused-fixture',
        'failedPasswords': 0,
        'lockedUntil': 0,
      };
      state.devices['${entry.key}-device'] = {
        'id': '${entry.key}-device',
        'account': entry.key,
        'deviceName': 'synthetic-device',
        'accessHash': digest(entry.value),
        'refreshHash': digest('refresh-${entry.value}'),
        // The test advances a FakeClock across two local days, so keep the
        // synthetic device valid for the whole run.
        'accessExpires': now + const Duration(days: 30).inMilliseconds,
        'refreshExpires': now + const Duration(days: 60).inMilliseconds,
        'lastUsedAt': now,
      };
    }
    return null;
  });
  final db = host.registry.services.get<Database>();
  await db.transaction((tx) async {
    await tx.execute(
      "INSERT INTO account VALUES (?, 'Synthetic AI', 'ai', 0, 0, NULL, 0, 0)",
      [_aiAccount],
    );
    await tx.execute('INSERT INTO ai_operator VALUES (?, ?)', [
      _aiAccount,
      _owner,
    ]);
    await tx.execute('INSERT INTO ai_profile VALUES (?, ?)', [
      _profile,
      _aiAccount,
    ]);
  });
}

class _Client {
  _Client(this.port, this.remaining, this.turnsFile);
  final int port;
  final Duration Function() remaining;

  /// Where the fixture child worker records the turns of its last request.
  final File turnsFile;
  final HttpClient _client = HttpClient()..findProxy = ((_) => 'DIRECT');

  /// Turns of the most recent model request, captured by the fixture worker.
  List<Map<String, Object?>> readChatTurns() {
    expect(turnsFile.existsSync(), isTrue, reason: 'worker recorded its turns');
    return (jsonDecode(turnsFile.readAsStringSync()) as List)
        .cast<Map<String, Object?>>();
  }

  Future<Map<String, Object?>> call(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
    int expectedStatus = 200,
  }) async {
    final timeout = remaining();
    return (() async {
      final request = await _client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      request.followRedirects = false;
      if (token != null) {
        request.headers.set('authorization', 'Bearer $token');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close();
      expect(response.statusCode, expectedStatus, reason: '$method $path');
      final bytes = await response.expand((chunk) => chunk).toList();
      return (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
    })().timeout(timeout);
  }

  void close() => _client.close(force: true);
}

// A real child process: the production adapter launches it and speaks the real
// framed protocol. It never opens a socket; the configured base is TEST-NET.
const _worker = r'''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final raw = await stdin.transform(utf8.decoder).join();
  final req = jsonDecode(raw) as Map;
  final payload = jsonDecode(utf8.decode(base64Decode(req['body'] as String))) as Map;
  final turns = (payload['messages'] as List).cast<Map<Object?, Object?>>();
  File('${File.fromUri(Platform.script).parent.path}/turns.json')
      .writeAsStringSync(jsonEncode(turns));
  if (req['method'] != 'POST' ||
      payload['model'] != 'auto' ||
      payload['stream'] != false) {
    stdout.writeln('{"ok":false,"code":"unavailable"}');
    return;
  }
  // Two callers share this worker: the B2 own-DM reply (system plus the live
  // owner text and optional memory segments) and the B3 proactive call (one
  // short system instruction).
  final system = turns.first['content'] as String;
  final text = system.contains('主动') ? 'proactive-model-reply' : 'b2-model-reply';
  final response = jsonEncode({
    'choices': [
      {'message': {'role': 'assistant', 'content': text}},
    ],
    'usage': {'prompt_tokens': 11, 'completion_tokens': 4, 'total_tokens': 15},
  });
  stdout.writeln(jsonEncode({
    'ok': true,
    'statusCode': 200,
    'headers': {},
    'body': base64Encode(utf8.encode(response)),
  }));
}
''';
