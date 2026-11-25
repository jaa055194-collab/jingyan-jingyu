import 'dart:convert';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

import 'shell_controller_test.dart' show MemoryPersistence, message;

MessageEventFrame revision(
  MessageEventFrame base, {
  Map<String, Object?>? body,
  String? messageId,
}) => MessageEventFrame(
  id: base.id,
  at: base.at,
  conversationId: base.conversationId,
  seq: base.seq,
  messageId: messageId ?? base.messageId,
  senderId: base.senderId,
  kind: base.kind,
  body: body ?? base.body,
  sentAt: base.sentAt,
);

ClientShellController shellFor(MemoryPersistence store) =>
    ClientShellController(
      persistence: store,
      submit: (_) async => throw StateError('no submit'),
      requestSync: (_) async => throw StateError('no sync'),
    );

void main() {
  test(
    'a confirmed edit replaces the cached body and persists the marker',
    () async {
      final store = MemoryPersistence();
      final shell = shellFor(store);
      await shell.initialize();
      final edited = message(2);
      await shell.acceptMessage(message(1));
      await shell.acceptMessage(edited);

      expect(
        await shell.applyMessageRevisions('c', [
          revision(edited, body: const {'text': '改好的内容'}),
        ], markEdited: edited.messageId),
        1,
      );
      expect(shell.messagesFor('c').last.body, {'text': '改好的内容'});
      expect(shell.isMessageEdited('c', edited.messageId), isTrue);
      expect(shell.isMessageEdited('c', message(1).messageId), isFalse);
      expect(
        shell.lastSeqFor('c'),
        2,
        reason: 'revisions never move the cursor',
      );

      final reopened = shellFor(store);
      await reopened.initialize();
      expect(reopened.messagesFor('c').last.body, {'text': '改好的内容'});
      expect(reopened.isMessageEdited('c', edited.messageId), isTrue);
    },
  );

  test('a confirmed recall becomes a terminal tombstone', () async {
    final store = MemoryPersistence();
    final shell = shellFor(store);
    await shell.initialize();
    final removed = message(2);
    await shell.acceptMessage(message(1));
    await shell.acceptMessage(removed);

    expect(
      await shell.applyMessageRevisions('c', [
        revision(
          removed,
          body: const {'recalled': true, 'text': 'leftover plaintext'},
        ),
      ]),
      1,
    );
    expect(shell.messagesFor('c').last.body, {'recalled': true});

    // A stale page that still carries the old plaintext must not resurrect it.
    expect(await shell.applyMessageRevisions('c', [removed]), 0);
    expect(shell.messagesFor('c').last.body, {'recalled': true});

    final reopened = shellFor(store);
    await reopened.initialize();
    expect(reopened.messagesFor('c').last.body, {'recalled': true});
    expect(jsonEncode(store.data), isNot(contains('leftover plaintext')));
  });

  test('an unknown sequence is ignored, not invented into the cache', () async {
    final store = MemoryPersistence();
    final shell = shellFor(store);
    await shell.initialize();
    await shell.acceptMessage(message(1));
    expect(
      await shell.applyMessageRevisions('c', [
        revision(message(5), body: const {'text': 'future'}),
      ]),
      0,
    );
    expect(shell.messagesFor('c').map((row) => row.seq), [1]);
    expect(shell.lastSeqFor('c'), 1);
    final id = message(5).messageId;
    expect(
      await shell.applyMessageRevisions('c', [message(5)], markEdited: id),
      0,
    );
    expect(shell.isMessageEdited('c', id), isFalse);
    expect(store.writeAttempts, 1, reason: 'only the initial accept wrote');
  });

  test('a conflicting identity or foreign conversation is refused', () async {
    final store = MemoryPersistence();
    final shell = shellFor(store);
    await shell.initialize();
    final second = message(2);
    await shell.acceptMessage(message(1));
    await shell.acceptMessage(second);

    await expectLater(
      shell.applyMessageRevisions('c', [
        revision(second, messageId: 'other-message'),
      ]),
      throwsFormatException,
    );
    await expectLater(
      shell.applyMessageRevisions('c', [message(2, conversationId: 'other')]),
      throwsFormatException,
    );
    expect(shell.messagesFor('c').singleWhere((row) => row.seq == 2), second);
  });

  test(
    'a failed checkpoint leaves the body, marker and cursor unchanged',
    () async {
      final store = MemoryPersistence();
      final shell = shellFor(store);
      await shell.initialize();
      final second = message(2);
      await shell.acceptMessage(message(1));
      await shell.acceptMessage(second);
      store.fail = true;
      await expectLater(
        shell.applyMessageRevisions('c', [
          revision(second, body: const {'text': 'dropped'}),
        ], markEdited: second.messageId),
        throwsStateError,
      );
      expect(shell.messagesFor('c').last.body, {'text': '2'});
      expect(shell.isMessageEdited('c', second.messageId), isFalse);
      expect(shell.lastSeqFor('c'), 2);
    },
  );
}
