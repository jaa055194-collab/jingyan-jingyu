// M08 voice HTTP 路由契约测试。
//
// 覆盖：真实 bearer 认证（缺失/无效→401）、owner/AI 隔离与 404 不泄露、
// 票据 5 分钟且不含厂商 key、通话 create/answer/end/interrupt 生命周期。
// 使用可控 fake TTS/ASR + SQLite profile/call stores。
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host/src/voice/sqlite_calls.dart';
import 'package:jingyu_host/src/voice/sqlite_voice_profiles.dart';
import 'package:jingyu_host/src/voice/voice_gateway.dart';
import 'package:jingyu_host/src/voice/voice_migrations.dart';
import 'package:jingyu_host/src/voice/voice_module.dart';
import 'package:jingyu_host/src/voice/voice_ownership.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

class _FakeOwnership implements VoiceOwnership {
  _FakeOwnership(this.ownerToAis);

  final Map<String, Set<String>> ownerToAis;

  @override
  Future<bool> ownsAi({required AccountId owner, required AiId ai}) async =>
      ownerToAis[owner.value]?.contains(ai.value) ?? false;
}

const _migrations = [...allMigrations, ...voiceMigrations];

const _ownerToken = 'owner-token';
const _otherToken = 'other-token';

void main() {
  late SqliteDatabase db;
  late FakeClock clock;
  late SqliteVoiceProfiles profiles;
  late SqliteCallService calls;
  late FakeTtsAdapter tts;
  late FakeAsrAdapter asr;
  late Pipeline pipeline;

  final ai1 = AiId.parse('ai1');

  Future<Principal?> authenticate(HostRequest request) async {
    final header = request.headers['authorization'] ?? '';
    if (!header.startsWith('Bearer ')) return null;
    final token = header.substring(7);
    if (token == _ownerToken) {
      return const Principal(accountId: 'owner', deviceId: 'd-owner');
    }
    if (token == _otherToken) {
      return const Principal(accountId: 'other', deviceId: 'd-other');
    }
    return null;
  }

  setUp(() async {
    db = await SqliteDatabase.open(':memory:', migrations: _migrations);
    clock = FakeClock(DateTime.utc(2026, 1, 1));
    profiles = SqliteVoiceProfiles(database: db, clock: clock);
    calls = SqliteCallService(database: db, clock: clock);
    tts = FakeTtsAdapter(vendorKey: 'SECRET-VENDOR-KEY-123');
    asr = FakeAsrAdapter();
    final gateway = VoiceGateway(
      profiles: profiles,
      tts: tts,
      asr: asr,
      clock: clock,
    );
    final module = VoiceModule(
      profiles: profiles,
      gateway: gateway,
      calls: calls,
      clock: clock,
      sweepInterval: Duration.zero,
      authenticate: authenticate,
      ownership: _FakeOwnership({
        'owner': {'ai1', 'ai2'},
        'other': {'ai-other'},
      }),
    );
    final services = HostServices();
    await module.configure(services);
    final router = Router();
    module.mount(router);
    pipeline = Pipeline(router: router, authenticate: authenticate);

    await profiles.create(
      ai: ai1,
      provider: 'minimax',
      model: 'speech-01',
      voiceId: 'v-100',
      consentRef: 'consent-1',
      grantedBy: 'owner',
      params: const {'speed': 1.0},
    );
  });

  tearDown(() async => db.close());

  String profilePath(String aiId) => '/api/v1/ai-profiles/$aiId/voice-profile';
  String ticketPath(String aiId) => '/api/v1/ai-profiles/$aiId/voice-ticket';
  const callsPath = '/api/v1/voice/calls';
  String callPath(String id) => '/api/v1/voice/calls/$id';

  Future<HostResponse> call(
    String method,
    String path, {
    Object? body,
    String token = _ownerToken,
    Map<String, String> query = const {},
  }) =>
      pipeline.handle(
        HostRequest(
          method: method,
          path: path,
          body: body,
          query: query,
          headers: {'authorization': 'Bearer $token'},
        ),
      );

  group('auth', () {
    test('missing or invalid bearer returns 401', () async {
      expect((await call('GET', profilePath('ai1'), token: '')).status, 401);
      expect((await call('GET', profilePath('ai1'), token: 'nope')).status, 401);
      expect((await call('POST', ticketPath('ai1'), token: '')).status, 401);
      expect((await call('POST', callsPath, token: 'nope', body: {
        'callId': 'c1',
        'aiId': 'ai1',
      })).status, 401);
    });
  });

  group('voice profile', () {
    test('owner reads own AI profile', () async {
      final response = await call('GET', profilePath('ai1'));
      expect(response.status, 200);
      final json = response.json! as Map<String, Object?>;
      expect(json['aiId'], 'ai1');
      expect(json['provider'], 'minimax');
      expect(json['voiceId'], 'v-100');
      expect(json['revision'], 1);
    });

    test('foreign owner or missing AI is hidden as 404', () async {
      expect((await call('GET', profilePath('ai1'), token: _otherToken)).status,
          404);
      // other 的 AI 对 owner 不可见。
      expect((await call('GET', profilePath('ai-other'))).status, 404);
      expect((await call('GET', profilePath('missing'))).status, 404);
    });

    test('malformed AI id or body is 400', () async {
      expect((await call('GET', profilePath('bad%2Fid'))).status, 400);
      expect((await call('GET', profilePath('ai1'), body: {'x': 1})).status,
          400);
    });
  });

  group('voice ticket', () {
    test('is 5 minutes, owner-only and never exposes the vendor key', () async {
      final response = await call('POST', ticketPath('ai1'));
      expect(response.status, 200);
      final json = response.json! as Map<String, Object?>;
      expect(json.keys.toSet(), {'token', 'aiId', 'expiresAt'});
      expect(json['aiId'], 'ai1');
      expect(
        json['expiresAt'],
        clock.now().toUtc().add(const Duration(minutes: 5)).toIso8601String(),
      );
      expect(response.encodeBody().contains(tts.vendorKey), isFalse);

      expect((await call('POST', ticketPath('ai1'), token: _otherToken)).status,
          404);
    });

    test('unexpected body or query is 400', () async {
      expect((await call('POST', ticketPath('ai1'), body: {'k': 1})).status,
          400);
      expect(
        (await call('POST', ticketPath('ai1'), query: {'k': 'v'})).status,
        400,
      );
    });
  });

  group('calls', () {
    test('create is idempotent and lifecycle works via routes', () async {
      final created = await call(
        'POST',
        callsPath,
        body: {'callId': 'c1', 'aiId': 'ai1'},
      );
      expect(created.status, 200);
      expect((created.json! as Map)['state'], 'ringing');

      final duplicate = await call(
        'POST',
        callsPath,
        body: {'callId': 'c1', 'aiId': 'ai1'},
      );
      expect(duplicate.status, 200);
      expect((duplicate.json! as Map)['state'], 'ringing');
      expect(calls.createdCount, 1);

      final answered = await call('POST', '${callPath('c1')}/answer');
      expect(answered.status, 200);
      expect((answered.json! as Map)['state'], 'active');

      final fetched = await call('GET', callPath('c1'));
      expect(fetched.status, 200);
      expect((fetched.json! as Map)['state'], 'active');

      // 模拟发言中途被打断，经路由触发打断清理。
      calls.beginAssistantTurn('c1', '半句话');
      calls.enqueueTts('c1', 'seg-1');
      calls.beginPlayback('c1');
      final interrupted = await call('POST', '${callPath('c1')}/interrupt');
      expect(interrupted.status, 200);
      final outcome = interrupted.json! as Map<String, Object?>;
      expect(outcome['llmCancelled'], isTrue);
      expect(outcome['ttsQueueEmpty'], isTrue);
      expect(outcome['playbackStopped'], isTrue);
      expect(outcome['truncated'], isTrue);
      expect(calls.utterancesOf('c1').single.marker, '中途被打断');

      final ended = await call('POST', '${callPath('c1')}/end');
      expect(ended.status, 200);
      expect((ended.json! as Map)['state'], 'ended');
    });

    test('foreign or missing call is hidden as 404', () async {
      await call(
        'POST',
        callsPath,
        body: {'callId': 'c2', 'aiId': 'ai1'},
      );
      expect((await call('GET', callPath('c2'), token: _otherToken)).status,
          404);
      expect((await call('POST', '${callPath('c2')}/answer', token: _otherToken))
          .status, 404);
      expect((await call('GET', callPath('missing'))).status, 404);
      expect((await call('POST', '${callPath('missing')}/interrupt')).status,
          404);
    });

    test('strict body and id validation returns 400', () async {
      for (final body in <Object?>[
        null,
        <String, Object?>{},
        <String, Object?>{'callId': 'c9'},
        <String, Object?>{'callId': 'c9', 'aiId': 'ai1', 'extra': true},
        <String, Object?>{'callId': 1, 'aiId': 'ai1'},
        <String, Object?>{'callId': 'bad/id', 'aiId': 'ai1'},
        <String, Object?>{'callId': 'c9', 'aiId': 'bad/id'},
      ]) {
        expect((await call('POST', callsPath, body: body)).status, 400);
      }
      expect((await call('GET', callPath('bad%2Fid'))).status, 400);
    });
  });

  group('DatabaseVoiceOwnership', () {
    test('only the owning operator of an active AI matches', () async {
      final gateDb = await SqliteDatabase.open(
        ':memory:',
        migrations: [
          ...allMigrations,
          ...accountsMigrations,
          aiIdentityMigration,
          ...voiceMigrations,
        ],
      );
      try {
        await gateDb.execute(
          "INSERT INTO account VALUES ('owner','Owner','human',0,0,'h',0,0)",
        );
        await gateDb.execute(
          "INSERT INTO account VALUES ('other','Other','human',0,0,'h2',0,0)",
        );
        await gateDb.execute(
          "INSERT INTO account VALUES ('ai','AI','ai',0,0,NULL,0,0)",
        );
        await gateDb.execute("INSERT INTO ai_operator VALUES ('ai','owner')");
        await gateDb.execute("INSERT INTO ai_profile VALUES ('profile','ai')");
        final gate = DatabaseVoiceOwnership(gateDb);
        expect(
          await gate.ownsAi(
            owner: AccountId.parse('owner'),
            ai: AiId.parse('profile'),
          ),
          isTrue,
        );
        expect(
          await gate.ownsAi(
            owner: AccountId.parse('other'),
            ai: AiId.parse('profile'),
          ),
          isFalse,
        );
        expect(
          await gate.ownsAi(
            owner: AccountId.parse('owner'),
            ai: AiId.parse('missing'),
          ),
          isFalse,
        );
        await gateDb.execute("UPDATE account SET disabled=1 WHERE id='owner'");
        expect(
          await gate.ownsAi(
            owner: AccountId.parse('owner'),
            ai: AiId.parse('profile'),
          ),
          isFalse,
        );
      } finally {
        await gateDb.close();
      }
    });
  });
}
