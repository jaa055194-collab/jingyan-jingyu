// M08 voice 模块测试入口。
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host/src/voice/calls.dart';
import 'package:jingyu_host/src/voice/sqlite_calls.dart';
import 'package:jingyu_host/src/voice/sqlite_voice_profiles.dart';
import 'package:jingyu_host/src/voice/voice_gateway.dart';
import 'package:jingyu_host/src/voice/voice_migrations.dart';
import 'package:jingyu_host/src/voice/voice_module.dart';
import 'package:jingyu_host/src/voice/voice_profiles.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

import 'voice_call_service_contract.dart';
import 'voice_profile_store_contract.dart';

const _testMigrations = [...allMigrations, ...voiceMigrations];

class _InMemoryProfileFixture implements VoiceProfileFixture {
  @override
  final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));

  @override
  late final VoiceProfiles profiles = InMemoryVoiceProfiles(clock: clock);

  @override
  Future<void> close() async {}
}

class _SqliteProfileFixture implements VoiceProfileFixture {
  _SqliteProfileFixture(this.directory, this.db, this.clock);

  final Directory directory;
  final SqliteDatabase db;

  @override
  final FakeClock clock;

  @override
  late final VoiceProfiles profiles = SqliteVoiceProfiles(
    database: db,
    clock: clock,
  );

  static Future<_SqliteProfileFixture> create() async {
    final directory = await Directory.systemTemp.createTemp('voice-profile-');
    final db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: _testMigrations,
    );
    return _SqliteProfileFixture(
      directory,
      db,
      FakeClock(DateTime.utc(2026, 1, 1)),
    );
  }

  @override
  Future<void> close() async {
    await db.close();
    await directory.delete(recursive: true);
  }
}

class _MemoryCallFixture implements CallFixture {
  @override
  final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));

  @override
  late final InMemoryCallService calls = InMemoryCallService(clock: clock);

  @override
  CallRuntimeDriver get runtime => calls;

  @override
  int get createdCount => calls.createdCount;

  @override
  Future<void> close() async {}
}

class _SqliteCallFixture implements CallFixture {
  _SqliteCallFixture(this.directory, this.db, this.clock);

  final Directory directory;
  final SqliteDatabase db;

  @override
  final FakeClock clock;

  @override
  late final SqliteCallService calls = SqliteCallService(
    database: db,
    clock: clock,
  );

  @override
  CallRuntimeDriver get runtime => calls;

  @override
  int get createdCount => calls.createdCount;

  static Future<_SqliteCallFixture> create() async {
    final directory = await Directory.systemTemp.createTemp('voice-calls-');
    final db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: _testMigrations,
    );
    return _SqliteCallFixture(
      directory,
      db,
      FakeClock(DateTime.utc(2026, 1, 1)),
    );
  }

  @override
  Future<void> close() async {
    await db.close();
    await directory.delete(recursive: true);
  }
}

void main() {
  group('voice profiles', () {
    voiceProfileContract('in-memory', () async => _InMemoryProfileFixture());
    voiceProfileContract('SQLite', _SqliteProfileFixture.create);
  });

  group('voice gateway', () {
    final ai = AiId.parse('ai1');
    late FakeClock clock;
    late InMemoryVoiceProfiles profiles;
    late FakeTtsAdapter tts;
    late FakeAsrAdapter asr;
    late VoiceGateway gateway;

    setUp(() async {
      clock = FakeClock(DateTime.utc(2026, 1, 1));
      profiles = InMemoryVoiceProfiles(clock: clock);
      tts = FakeTtsAdapter();
      asr = FakeAsrAdapter();
      gateway = VoiceGateway(
        profiles: profiles,
        tts: tts,
        asr: asr,
        clock: clock,
      );
      await profiles.create(
        ai: ai,
        provider: 'minimax',
        model: 'speech-01',
        voiceId: 'v-100',
        consentRef: 'consent-1',
        grantedBy: 'owner',
        params: const {'speed': 1.1},
      );
    });

    test('AC-11 synthesis uses the bound provider and voice_id', () async {
      final result = await gateway.speak(ai: ai, text: '你好');
      expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
      expect(result.value.spoken, isTrue);
      expect(result.value.voiceId, 'v-100');
      expect(result.value.provider, 'minimax');
      expect(tts.requests.single['provider'], 'minimax');
      expect(tts.requests.single['voiceId'], 'v-100');
    });

    test('AC-11 vendor failure downgrades to text and keeps voice_id', () async {
      tts.available = false;
      final result = await gateway.speak(ai: ai, text: '今天好吗');
      expect(result.isOk, isTrue);
      final outcome = result.value;
      expect(outcome.spoken, isFalse);
      expect(outcome.degraded, isTrue);
      expect(outcome.text, '今天好吗');
      expect(outcome.voiceId, 'v-100');
      expect(outcome.provider, 'minimax');

      // 从未换音色、从未跨厂商：档案保持原样，适配器始终收到 v-100。
      final profile = await profiles.get(ai: ai);
      expect(profile.value.voiceId, 'v-100');
      expect(profile.value.provider, 'minimax');
      expect(tts.requests.single['voiceId'], 'v-100');
    });

    test('NFR-06 ticket is short-lived and never carries the vendor key',
        () async {
      final issued = await gateway.issueTicket(ai: ai, ownerAccountId: 'owner');
      expect(issued.isOk, isTrue, reason: issued.failureOrNull?.message);
      final ticket = issued.value;
      expect(
        ticket.toJson().keys.toSet(),
        {'token', 'aiId', 'expiresAt'},
      );
      expect(ticket.toJson().toString().contains(tts.vendorKey), isFalse);

      clock.advance(const Duration(minutes: 4, seconds: 59));
      expect(
        (await gateway.redeemTicket(token: ticket.token, ai: ai)).isOk,
        isTrue,
      );
      clock.advance(const Duration(seconds: 2));
      expect(
        (await gateway.redeemTicket(token: ticket.token, ai: ai))
            .failureOrNull
            ?.code,
        FailureCode.unauthenticated,
      );
    });

    test('ASR failure degrades without blocking the call', () async {
      asr.available = false;
      final result = await gateway.transcribe(ai: ai, audio: const [1, 2, 3]);
      expect(result.isOk, isTrue);
      expect(result.value.degraded, isTrue);
      expect(result.value.transcript, isNull);
    });

    test('ASR success returns transcript text', () async {
      final result = await gateway.transcribe(ai: ai, audio: const [4, 5]);
      expect(result.isOk, isTrue);
      expect(result.value.degraded, isFalse);
      expect(result.value.transcript?.text, 'hello');
    });
  });

  callServiceContract('calls in-memory', () async => _MemoryCallFixture());
  callServiceContract('calls SQLite', _SqliteCallFixture.create);

  group('voice module', () {
    test('is named voice and registers its three service interfaces', () async {
      final services = HostServices();
      final module = VoiceModule(
        clock: FakeClock(DateTime.utc(2026, 1, 1)),
        sweepInterval: Duration.zero,
      );
      expect(module.name, 'voice');
      await module.configure(services);

      expect(services.get<VoiceProfiles>(), isA<InMemoryVoiceProfiles>());
      expect(services.get<VoiceGateway>(), isA<VoiceGateway>());
      expect(services.get<CallService>(), isA<InMemoryCallService>());

      await module.stop();
      await module.stop(); // 停止必须幂等
    });

    test('persistent factory wires the SQLite-backed services', () async {
      final db = await SqliteDatabase.open(
        ':memory:',
        migrations: _testMigrations,
      );
      final module = VoiceModule.persistent(
        database: db,
        clock: FakeClock(DateTime.utc(2026, 1, 1)),
        sweepInterval: Duration.zero,
      );
      final services = HostServices();
      await module.configure(services);
      expect(services.get<VoiceProfiles>(), isA<SqliteVoiceProfiles>());
      expect(services.get<CallService>(), isA<SqliteCallService>());
      await module.stop();
      await db.close();
    });

    test('wires caller-provided dependencies through HostServices', () async {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final profiles = InMemoryVoiceProfiles(clock: clock);
      final gateway = VoiceGateway(
        profiles: profiles,
        tts: FakeTtsAdapter(),
        asr: FakeAsrAdapter(),
        clock: clock,
      );
      final calls = InMemoryCallService(clock: clock);
      final module = VoiceModule(
        profiles: profiles,
        gateway: gateway,
        calls: calls,
        clock: clock,
        sweepInterval: Duration.zero,
      );
      final services = HostServices();
      await module.configure(services);

      expect(services.get<VoiceProfiles>(), same(profiles));
      expect(services.get<VoiceGateway>(), same(gateway));
      expect(services.get<CallService>(), same(calls));
    });
  });

  test('SQLite profile and call state survive a reopen', () async {
    final directory = await Directory.systemTemp.createTemp('voice-persist-');
    final clock = FakeClock(DateTime.utc(2026, 1, 1));
    final ai = AiId.parse('ai-persist');
    final path = '${directory.path}/host.sqlite';

    var db = await SqliteDatabase.open(path, migrations: _testMigrations);
    var profiles = SqliteVoiceProfiles(database: db, clock: clock);
    var calls = SqliteCallService(database: db, clock: clock);

    expect(
      (await profiles.create(
        ai: ai,
        provider: 'minimax',
        model: 'speech-01',
        voiceId: 'v-9',
        consentRef: 'consent-9',
        grantedBy: 'owner',
      ))
          .isOk,
      isTrue,
    );
    await profiles.stageParams(ai: ai, params: const {'speed': 1.3});
    await profiles.applyAtSentenceBoundary(ai: ai);
    await calls.start(callId: 'call-persist', ai: ai, peerAccountId: 'human');
    await calls.answer(callId: 'call-persist');
    await db.close();

    db = await SqliteDatabase.open(path, migrations: _testMigrations);
    profiles = SqliteVoiceProfiles(database: db, clock: clock);
    calls = SqliteCallService(database: db, clock: clock);

    final reopenedProfile = await profiles.get(ai: ai);
    expect(reopenedProfile.value.voiceId, 'v-9');
    expect(reopenedProfile.value.revision, 2);
    expect(reopenedProfile.value.params['speed'], 1.3);
    expect((await profiles.consents(ai: ai)).value, isNotEmpty);

    final reopenedCall = await calls.get(callId: 'call-persist');
    expect(reopenedCall.value.state, CallState.active);
    expect(reopenedCall.value.aiId, ai);

    await db.close();
    await directory.delete(recursive: true);
  });
}
