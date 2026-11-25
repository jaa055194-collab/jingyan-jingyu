// 通话服务契约（M08）。
//
// 内存实现与 SQLite 实现共用同一份契约：
// * FR-32 call_id 幂等、30s 未接转 missed；
// * FR-32 同一 call_id 换 peer 复用被拒；
// * FR-32 接听不得越过 30s 响铃期限：迟答标 missed 并返回既有冲突；
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
void callServiceContract(String label, Future<CallFixture> Function() create) {
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

    test('FR-32 answer just before the 30s deadline still succeeds', () async {
      await fixture.calls.start(callId: 'd1', ai: ai, peerAccountId: 'human');
      fixture.clock.advance(const Duration(seconds: 29));
      final result = await fixture.calls.answer(callId: 'd1');
      expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
      expect(result.value.state, CallState.active);
      expect(result.value.answeredAt, fixture.clock.now());
      expect(result.value.endedAt, isNull);
    });

    test('FR-32 answer at the 30s deadline marks the call missed', () async {
      await fixture.calls.start(callId: 'd2', ai: ai, peerAccountId: 'human');
      fixture.clock.advance(const Duration(seconds: 30));
      final result = await fixture.calls.answer(callId: 'd2');
      expect(result.failureOrNull?.code, FailureCode.conflict);
      expect(result.failureOrNull?.message, '通话已结束');
      final stored = await fixture.calls.get(callId: 'd2');
      expect(stored.value.state, CallState.missed);
      expect(stored.value.answeredAt, isNull);
      expect(stored.value.endedAt, fixture.clock.now());
    });

    test(
      'FR-32 a rejected late answer stays missed across a sweep and retry',
      () async {
        await fixture.calls.start(callId: 'd3', ai: ai, peerAccountId: 'human');
        fixture.clock.advance(const Duration(seconds: 30));
        final missedAt = fixture.clock.now();
        final result = await fixture.calls.answer(callId: 'd3');
        expect(result.failureOrNull?.code, FailureCode.conflict);

        fixture.clock.advance(const Duration(seconds: 1));
        expect((await fixture.calls.sweepMissed()).value, isEmpty);
        final retry = await fixture.calls.answer(callId: 'd3');
        expect(retry.failureOrNull?.code, FailureCode.conflict);
        expect(retry.failureOrNull?.message, '通话已结束');
        final stored = await fixture.calls.get(callId: 'd3');
        expect(stored.value.state, CallState.missed);
        expect(stored.value.answeredAt, isNull);
        expect(stored.value.endedAt, missedAt);
      },
    );

    test(
      'FR-32 an answer far past the deadline never activates the call',
      () async {
        await fixture.calls.start(callId: 'd4', ai: ai, peerAccountId: 'human');
        fixture.clock.advance(const Duration(minutes: 10));
        final result = await fixture.calls.answer(callId: 'd4');
        expect(result.failureOrNull?.code, FailureCode.conflict);
        final stored = await fixture.calls.get(callId: 'd4');
        expect(stored.value.state, CallState.missed);
        expect(stored.value.answeredAt, isNull);
        expect(stored.value.endedAt, isNotNull);
      },
    );

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
        await fixture.calls.start(callId: 'c4', ai: ai, peerAccountId: 'human');
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

    test(
      'list is newest-first, filters by state and pages with before',
      () async {
        await fixture.calls.start(callId: 'l1', ai: ai, peerAccountId: 'human');
        fixture.clock.advance(const Duration(seconds: 10));
        await fixture.calls.start(callId: 'l2', ai: ai, peerAccountId: 'human');
        fixture.clock.advance(const Duration(seconds: 10));
        await fixture.calls.start(callId: 'l3', ai: ai, peerAccountId: 'human');
        await fixture.calls.end(callId: 'l1');

        final all = (await fixture.calls.list()).value;
        expect(all.map((c) => c.callId).toList(), ['l3', 'l2', 'l1']);

        final ended = (await fixture.calls.list(status: CallState.ended)).value;
        expect(ended.map((c) => c.callId).toList(), ['l1']);

        final newest = (await fixture.calls.list(limit: 1)).value;
        expect(newest.single.callId, 'l3');

        final older = (await fixture.calls.list(
          before: all.first.startedAt,
        )).value;
        expect(older.map((c) => c.callId).toList(), ['l2', 'l1']);

        final bad = await fixture.calls.list(limit: 0);
        expect(bad.failureOrNull?.code, FailureCode.invalidArgument);

        final mine = (await fixture.calls.list(accountId: 'human')).value;
        expect(mine.map((c) => c.callId).toList(), ['l3', 'l2', 'l1']);
        final foreign = (await fixture.calls.list(accountId: 'nope')).value;
        expect(foreign, isEmpty);
      },
    );

    test('list snapshots are metadata-only (no audio or transcript)', () async {
      await fixture.calls.start(callId: 'l4', ai: ai, peerAccountId: 'human');
      final json = (await fixture.calls.list()).value.single.toJson();
      expect(json.keys.toSet(), {
        'callId',
        'aiId',
        'peerAccountId',
        'state',
        'startedAt',
      });
    });
  });
}
