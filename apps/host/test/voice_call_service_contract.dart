// 通话服务契约（M08）。
//
// 内存实现与 SQLite 实现共用同一份契约：
// * FR-32 call_id 幂等、30s 未接转 missed；
// * FR-32 同一 call_id 换 peer 复用被拒；
// * AC-13 打断取消 LLM、清 TTS 队列、停播并标记截断句。
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/voice/calls.dart';
import 'package:test/test.dart';

/// 一个实现需要提供的夹具。
abstract class CallFixture {
  CallService get calls;
  CallRuntimeDriver get runtime;
  FakeClock get clock;

  /// 实际新建的通话数，用于断言 call_id 幂等。
  int get createdCount;
  Future<void> close();
}

/// 对任意 [CallService] 实现运行契约测试。
void callServiceContract(
  String label,
  Future<CallFixture> Function() create,
) {
  group(label, () {
    final ai = AiId.parse('ai1');
    late CallFixture fixture;

    setUp(() async => fixture = await create());
    tearDown(() => fixture.close());

    test('FR-32 the same call_id never opens a second call', () async {
      final first = await fixture.calls.start(
        callId: 'c1',
        ai: ai,
        peerAccountId: 'human',
      );
      final second = await fixture.calls.start(
        callId: 'c1',
        ai: ai,
        peerAccountId: 'human',
      );
      expect(first.isOk, isTrue, reason: first.failureOrNull?.message);
      expect(second.isOk, isTrue);
      expect(second.value.callId, 'c1');
      expect(fixture.createdCount, 1);
      expect(
        (await fixture.calls.get(callId: 'c1')).value.state,
        CallState.ringing,
      );
    });

    test('FR-32 unanswered call becomes missed after 30s', () async {
      await fixture.calls.start(callId: 'c2', ai: ai, peerAccountId: 'human');
      fixture.clock.advance(const Duration(seconds: 29));
      expect((await fixture.calls.sweepMissed()).value, isEmpty);
      fixture.clock.advance(const Duration(seconds: 1));
      expect((await fixture.calls.sweepMissed()).value, contains('c2'));
      expect(
        (await fixture.calls.get(callId: 'c2')).value.state,
        CallState.missed,
      );
    });

    test('FR-32 answered call is not swept as missed', () async {
      await fixture.calls.start(callId: 'c3', ai: ai, peerAccountId: 'human');
      await fixture.calls.answer(callId: 'c3');
      fixture.clock.advance(const Duration(minutes: 1));
      expect((await fixture.calls.sweepMissed()).value, isEmpty);
      expect(
        (await fixture.calls.get(callId: 'c3')).value.state,
        CallState.active,
      );
    });

    test('FR-32 reusing call_id for a different peer is rejected', () async {
      await fixture.calls.start(callId: 'c6', ai: ai, peerAccountId: 'human');
      final result = await fixture.calls.start(
        callId: 'c6',
        ai: ai,
        peerAccountId: 'other',
      );
      expect(result.failureOrNull?.code, FailureCode.conflict);
      expect(fixture.createdCount, 1);
    });

    test(
      'AC-13 interrupt cancels LLM, clears TTS queue, stops playback and marks truncation',
      () async {
        await fixture.calls.start(
          callId: 'c4',
          ai: ai,
          peerAccountId: 'human',
        );
        await fixture.calls.answer(callId: 'c4');
        fixture.runtime.beginAssistantTurn('c4', '这句话说到一半');
        fixture.runtime.enqueueTts('c4', 'seg-1');
        fixture.runtime.enqueueTts('c4', 'seg-2');
        fixture.runtime.beginPlayback('c4');

        expect(fixture.runtime.isLlmCancelled('c4'), isFalse);
        expect(fixture.runtime.ttsQueueOf('c4'), hasLength(2));
        expect(fixture.runtime.isPlaying('c4'), isTrue);

        final result = await fixture.calls.interrupt(callId: 'c4');
        expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
        final outcome = result.value;
        expect(outcome.llmCancelled, isTrue);
        expect(outcome.ttsQueueEmpty, isTrue);
        expect(outcome.playbackStopped, isTrue);
        expect(outcome.truncated, isTrue);

        expect(fixture.runtime.isLlmCancelled('c4'), isTrue);
        expect(fixture.runtime.ttsQueueOf('c4'), isEmpty);
        expect(fixture.runtime.isPlaying('c4'), isFalse);

        final utterances = fixture.runtime.utterancesOf('c4');
        expect(utterances, hasLength(1));
        expect(utterances.single.interrupted, isTrue);
        expect(utterances.single.complete, isFalse);
        expect(utterances.single.marker, '中途被打断');
      },
    );

    test('AC-13 interrupt outside an active call is rejected', () async {
      await fixture.calls.start(callId: 'c5', ai: ai, peerAccountId: 'human');
      final result = await fixture.calls.interrupt(callId: 'c5');
      expect(result.failureOrNull?.code, FailureCode.conflict);
    });
  });
}
