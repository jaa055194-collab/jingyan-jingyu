import 'dart:async';

import 'package:jingyu_host/src/messages/accepted_message_fanout.dart';
import 'package:jingyu_host/src/messages/accepted_message_observer.dart';
import 'package:jingyu_host/src/messages/message_store.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _Observer implements AcceptedMessageObserver {
  _Observer(this.accept);
  final Future<void> Function(StoredMessage) accept;

  @override
  Future<void> onAccepted(StoredMessage message) => accept(message);
}

StoredMessage _message() => StoredMessage(
  conversationId: 'group',
  seq: 1,
  messageId: 'message',
  senderId: 'human',
  clientMsgId: 'one',
  kind: MessageKind.text,
  body: const {'text': 'private synthetic body'},
  sentAt: DateTime.utc(2026),
);

void main() {
  test(
    'constructor snapshots observers instead of retaining mutable list',
    () async {
      final calls = <String>[];
      final input = <AcceptedMessageObserver>[
        _Observer((_) async => calls.add('original')),
      ];
      final fanout = AcceptedMessageFanout(input);
      input
        ..clear()
        ..add(_Observer((_) async => calls.add('replacement')));
      await fanout.onAccepted(_message());
      expect(calls, ['original']);
    },
  );

  test(
    'awaits each observer sequentially and awaits last completion',
    () async {
      final message = _message();
      final calls = <String>[];
      final firstEntered = Completer<void>();
      final firstRelease = Completer<void>();
      final secondEntered = Completer<void>();
      final secondRelease = Completer<void>();
      final fanout = AcceptedMessageFanout([
        _Observer((incoming) async {
          expect(identical(incoming, message), isTrue);
          calls.add('first-start');
          firstEntered.complete();
          await firstRelease.future;
          calls.add('first-end');
        }),
        _Observer((incoming) async {
          expect(identical(incoming, message), isTrue);
          calls.add('second-start');
          secondEntered.complete();
          await secondRelease.future;
          calls.add('second-end');
        }),
      ]);
      var completed = false;
      final pending = fanout.onAccepted(message).then((_) => completed = true);
      await firstEntered.future;
      expect(calls, ['first-start']);
      expect(completed, isFalse);
      firstRelease.complete();
      await secondEntered.future;
      expect(calls, ['first-start', 'first-end', 'second-start']);
      expect(completed, isFalse);
      secondRelease.complete();
      await pending;
      expect(calls, ['first-start', 'first-end', 'second-start', 'second-end']);
      expect(completed, isTrue);
    },
  );

  test(
    'sync and async failures do not starve next or log private details',
    () async {
      final calls = <String>[];
      final printed = <String>[];
      final fanout = AcceptedMessageFanout([
        _Observer((_) {
          calls.add('sync-throws');
          throw StateError('private synthetic body');
        }),
        _Observer((_) async {
          await Future<void>.value();
          calls.add('async-throws');
          throw StateError('private synthetic body');
        }),
        _Observer((_) async => calls.add('last')),
      ]);
      await runZoned(
        () => fanout.onAccepted(_message()),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );
      expect(calls, ['sync-throws', 'async-throws', 'last']);
      expect(printed, isEmpty);
    },
  );

  test('empty fanout completes without observers', () async {
    await expectLater(
      AcceptedMessageFanout([]).onAccepted(_message()),
      completes,
    );
  });
}
