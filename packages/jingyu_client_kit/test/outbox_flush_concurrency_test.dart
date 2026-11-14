import 'dart:async';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  Outbox box() {
    var serial = 0;
    return Outbox(newClientMsgId: () => 'm${++serial}');
  }

  void enqueue(Outbox box, String text) =>
      box.enqueue('conversation', MessageKind.text, {'text': text});

  test(
    'overlapping flushes submit the pending head once and share one report',
    () async {
      final outbox = box();
      enqueue(outbox, 'A');
      final gate = Completer<Result<void>>();
      var calls = 0;
      final first = outbox.flush((_) {
        calls++;
        return gate.future;
      });
      final second = outbox.flush((_) {
        calls++;
        return gate.future;
      });
      final attempts = outbox.items.single.attempts;
      gate.complete(err<void>(FailureCode.unavailable, 'offline'));
      final reports = await Future.wait([first, second]);
      expect(calls, 1);
      expect(attempts, 1);
      expect(identical(first, second), isTrue);
      expect(identical(reports[0], reports[1]), isTrue);
      expect(reports.first.sent, 0);
      expect(reports.first.remaining, 1);
      expect(outbox.items.single.clientMsgId, 'm1');
    },
  );

  test(
    'the initial callbacks own FIFO drain including an item appended during await',
    () async {
      final outbox = box();
      enqueue(outbox, 'A');
      final gate = Completer<Result<void>>();
      final submitted = <String>[];
      var joinerCalls = 0;
      final first = outbox.flush((item) {
        submitted.add(item.clientMsgId);
        return submitted.length == 1
            ? gate.future
            : Future.value(const Ok<void>(null));
      });
      final second = outbox.flush((_) async {
        joinerCalls++;
        return const Ok<void>(null);
      });
      enqueue(outbox, 'B');
      gate.complete(const Ok<void>(null));
      final reports = await Future.wait([first, second]);
      expect(submitted, ['m1', 'm2']);
      expect(joinerCalls, 0);
      expect(reports.first.sent, 2);
      expect(reports.first.remaining, 0);
      expect(identical(reports.first, reports.last), isTrue);
      expect(outbox.items, isEmpty);
    },
  );

  for (final code in [
    FailureCode.unavailable,
    FailureCode.rateLimited,
    FailureCode.internal,
  ]) {
    test('a joined $code stop never schedules an implicit retry', () async {
      final outbox = box();
      enqueue(outbox, 'A');
      enqueue(outbox, 'B');
      final gate = Completer<Result<void>>();
      final first = outbox.flush((_) => gate.future);
      var unexpected = 0;
      final joined = outbox.flush((_) async {
        unexpected++;
        return const Ok<void>(null);
      });
      gate.complete(err<void>(code, 'temporary'));
      final results = await Future.wait([first, joined]);
      expect(unexpected, 0);
      expect(results.first.stoppedBy?.code, code);
      expect(outbox.items.map((i) => i.clientMsgId), ['m1', 'm2']);
      expect(outbox.items.map((i) => i.attempts), [1, 0]);
      final ids = <String>[];
      final retried = await outbox.flush((item) async {
        ids.add(item.clientMsgId);
        return const Ok<void>(null);
      });
      expect(ids, ['m1', 'm2']);
      expect(retried.sent, 2);
      expect(outbox.items, isEmpty);
    });
  }

  test(
    'permanent failures drop once using only first caller callbacks',
    () async {
      final outbox = box();
      enqueue(outbox, 'A');
      enqueue(outbox, 'B');
      final gate = Completer<Result<void>>();
      final dropped = <String>[];
      final submitted = <OutboxItem>[];
      final first = outbox.flush((item) {
        submitted.add(item);
        return submitted.length == 1
            ? gate.future
            : Future.value(const Ok<void>(null));
      }, onDropped: (item, _) => dropped.add(item.clientMsgId));
      var unexpected = 0;
      final joined = outbox.flush((_) async {
        unexpected++;
        return const Ok<void>(null);
      }, onDropped: (_, _) => unexpected++);
      gate.complete(err<void>(FailureCode.forbidden, 'denied'));
      final results = await Future.wait([first, joined]);
      expect(unexpected, 0);
      expect(dropped, ['m1']);
      expect(submitted.map((i) => i.clientMsgId), ['m1', 'm2']);
      expect(submitted.map((i) => i.attempts), [1, 1]);
      expect(results.first.sent, 1);
      expect(results.first.remaining, 0);
    },
  );

  test(
    'synchronous submit reentry joins a published flight without resubmission',
    () async {
      final outbox = box();
      enqueue(outbox, 'A');
      Future<FlushReport>? reentered;
      var calls = 0;
      final first = outbox.flush((_) {
        calls++;
        reentered = outbox.flush((_) async {
          calls++;
          return const Ok<void>(null);
        });
        return Future.value(const Ok<void>(null));
      });
      final report = await first;
      expect(calls, 1);
      expect(identical(reentered, first), isTrue);
      expect(identical(await reentered!, report), isTrue);
    },
  );

  test('synchronous onDropped reentry joins the same active flight', () async {
    final outbox = box();
    enqueue(outbox, 'A');
    enqueue(outbox, 'B');
    Future<FlushReport>? reentered;
    var attempts = 0;
    final first = outbox.flush(
      (_) async => ++attempts == 1
          ? err<void>(FailureCode.forbidden, 'denied')
          : const Ok<void>(null),
      onDropped: (_, _) {
        reentered = outbox.flush((_) async {
          fail('Joiner must not drain');
        });
      },
    );
    final report = await first;
    expect(attempts, 2);
    expect(identical(reentered, first), isTrue);
    expect(identical(await reentered!, report), isTrue);
  });

  test(
    'an asynchronous submit error is shared and leaves head retryable',
    () async {
      final outbox = box();
      enqueue(outbox, 'A');
      final gate = Completer<Result<void>>();
      final failure = StateError('transport failed');
      final first = outbox.flush((_) => gate.future);
      final joined = outbox.flush((_) async => const Ok<void>(null));
      final assertions = [
        expectLater(first, throwsA(same(failure))),
        expectLater(joined, throwsA(same(failure))),
      ];
      gate.completeError(failure, StackTrace.current);
      await Future.wait(assertions);
      expect(outbox.items.single.clientMsgId, 'm1');
      expect(outbox.items.single.attempts, 1);
      expect((await outbox.flush((_) async => const Ok<void>(null))).sent, 1);
    },
  );

  test(
    'synchronous submit throw releases flight without removing head',
    () async {
      final outbox = box();
      enqueue(outbox, 'A');
      final failure = StateError('synchronous transport');
      await expectLater(
        outbox.flush((_) => throw failure),
        throwsA(same(failure)),
      );
      expect(outbox.items.single.attempts, 1);
      expect((await outbox.flush((_) async => const Ok<void>(null))).sent, 1);
    },
  );

  test(
    'throwing drop callback leaves dropped item removed and tail retryable',
    () async {
      final outbox = box();
      enqueue(outbox, 'A');
      enqueue(outbox, 'B');
      final gate = Completer<Result<void>>();
      final failure = StateError('display failed');
      final first = outbox.flush(
        (_) => gate.future,
        onDropped: (_, _) => throw failure,
      );
      final joined = outbox.flush((_) async => const Ok<void>(null));
      final assertions = [
        expectLater(first, throwsA(same(failure))),
        expectLater(joined, throwsA(same(failure))),
      ];
      gate.complete(err<void>(FailureCode.forbidden, 'denied'));
      await Future.wait(assertions);
      expect(outbox.items.single.clientMsgId, 'm2');
      expect(outbox.items.single.attempts, 0);
      expect((await outbox.flush((_) async => const Ok<void>(null))).sent, 1);
    },
  );

  test(
    'empty completion releases ownership and separate boxes remain independent',
    () async {
      final first = box();
      final second = box();
      expect((await first.flush((_) async => const Ok<void>(null))).sent, 0);
      enqueue(first, 'A');
      enqueue(second, 'B');
      final gate = Completer<Result<void>>();
      final held = first.flush((_) => gate.future);
      expect((await second.flush((_) async => const Ok<void>(null))).sent, 1);
      gate.complete(const Ok<void>(null));
      expect((await held).sent, 1);
    },
  );
}
