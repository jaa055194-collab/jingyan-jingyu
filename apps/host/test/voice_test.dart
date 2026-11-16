// M08 voice 模块测试入口。
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/voice/calls.dart';
import 'package:jingyu_host/src/voice/voice_gateway.dart';
import 'package:jingyu_host/src/voice/voice_module.dart';
import 'package:jingyu_host/src/voice/voice_profiles.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

import 'voice_profile_store_contract.dart';

class _InMemoryProfileFixture implements VoiceProfileFixture {
  @override
  final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));

  @override
  late final VoiceProfiles profiles = InMemoryVoiceProfiles(clock: clock);

  @override
  Future<void> close() async {}
}

void main() {
  group('voice profiles (in-memory)', () {
    voiceProfileContract(
      'in-memory',
      () async => _InMemoryProfileFixture(),
    );
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

  group('calls', () {
    final ai = AiId.parse('ai1');
    late FakeClock clock;
    late InMemoryCallService calls;

    setUp(() {
      clock = FakeClock(DateTime.utc(2026, 1, 1));
      calls = InMemoryCallService(clock: clock);
    });

    test('FR-32 the same call_id never opens a second call', () async {
      final first = await calls.start(
        callId: 'c1',
        ai: ai,
        peerAccountId: 'human',
      );
      final second = await calls.start(
        callId: 'c1',
        ai: ai,
        peerAccountId: 'human',
      );
      expect(first.isOk, isTrue, reason: first.failureOrNull?.message);
      expect(second.isOk, isTrue);
      expect(second.value.callId, 'c1');
      expect(calls.createdCount, 1);
      expect((await calls.get(callId: 'c1')).value.state, CallState.ringing);
    });

    test('FR-32 unanswered call becomes missed after 30s', () async {
      await calls.start(callId: 'c2', ai: ai, peerAccountId: 'human');
      clock.advance(const Duration(seconds: 29));
      expect((await calls.sweepMissed()).value, isEmpty);
      clock.advance(const Duration(seconds: 1));
      expect((await calls.sweepMissed()).value, contains('c2'));
      expect((await calls.get(callId: 'c2')).value.state, CallState.missed);
    });

    test('FR-32 answered call is not swept as missed', () async {
      await calls.start(callId: 'c3', ai: ai, peerAccountId: 'human');
      await calls.answer(callId: 'c3');
      clock.advance(const Duration(minutes: 1));
      expect((await calls.sweepMissed()).value, isEmpty);
      expect((await calls.get(callId: 'c3')).value.state, CallState.active);
    });

    test('FR-32 reusing call_id for a different peer is rejected', () async {
      await calls.start(callId: 'c6', ai: ai, peerAccountId: 'human');
      final result = await calls.start(
        callId: 'c6',
        ai: ai,
        peerAccountId: 'other',
      );
      expect(result.failureOrNull?.code, FailureCode.conflict);
    });

    test(
      'AC-13 interrupt cancels LLM, clears TTS queue, stops playback and marks truncation',
      () async {
        await calls.start(callId: 'c4', ai: ai, peerAccountId: 'human');
        await calls.answer(callId: 'c4');
        calls.beginAssistantTurn('c4', '这句话说到一半');
        calls.enqueueTts('c4', 'seg-1');
        calls.enqueueTts('c4', 'seg-2');
        calls.beginPlayback('c4');

        expect(calls.isLlmCancelled('c4'), isFalse);
        expect(calls.ttsQueueOf('c4'), hasLength(2));
        expect(calls.isPlaying('c4'), isTrue);

        final result = await calls.interrupt(callId: 'c4');
        expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
        final outcome = result.value;
        expect(outcome.llmCancelled, isTrue);
        expect(outcome.ttsQueueEmpty, isTrue);
        expect(outcome.playbackStopped, isTrue);
        expect(outcome.truncated, isTrue);

        expect(calls.isLlmCancelled('c4'), isTrue);
        expect(calls.ttsQueueOf('c4'), isEmpty);
        expect(calls.isPlaying('c4'), isFalse);

        final utterances = calls.utterancesOf('c4');
        expect(utterances, hasLength(1));
        expect(utterances.single.interrupted, isTrue);
        expect(utterances.single.complete, isFalse);
        expect(utterances.single.marker, '中途被打断');
      },
    );

    test('AC-13 interrupt outside an active call is rejected', () async {
      await calls.start(callId: 'c5', ai: ai, peerAccountId: 'human');
      final result = await calls.interrupt(callId: 'c5');
      expect(result.failureOrNull?.code, FailureCode.conflict);
    });
  });

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
}
