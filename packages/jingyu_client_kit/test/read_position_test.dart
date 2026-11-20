import 'dart:async';
import 'dart:convert';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class MemoryPersistence implements ClientPersistence {
  Map<String, Object?>? data;
  bool fail = false;
  int writeAttempts = 0;
  Future<void> Function()? beforeWrite;
  Future<void> Function()? beforeRead;
  @override
  Future<Map<String, Object?>?> read() async {
    await beforeRead?.call();
    return data == null
        ? null
        : Map<String, Object?>.from(jsonDecode(jsonEncode(data)) as Map);
  }

  @override
  Future<void> write(Map<String, Object?> snapshot) async {
    writeAttempts++;
    final gate = beforeWrite;
    if (gate != null) await gate();
    if (fail) throw StateError('disk full');
    data = Map<String, Object?>.from(jsonDecode(jsonEncode(snapshot)) as Map);
  }
}

MessageEventFrame message(int seq, {String conversationId = 'c'}) =>
    MessageEventFrame(
      id: '$conversationId-e$seq',
      at: DateTime.utc(2026),
      conversationId: conversationId,
      seq: seq,
      messageId: '$conversationId-m$seq',
      senderId: 'u',
      kind: MessageKind.text,
      body: {'text': '$seq'},
      sentAt: DateTime.utc(2026),
    );

ClientShellController build(MemoryPersistence store) => ClientShellController(
  persistence: store,
  submit: (_) async => throw StateError('Read position must not submit'),
  requestSync: (_) async => throw StateError('Read position must not sync'),
);

/// Seeds a conversation with canonical messages 1..head.
Future<ClientShellController> seeded(
  MemoryPersistence store, {
  int head = 5,
  String conversationId = 'c',
}) async {
  final shell = build(store);
  await shell.initialize();
  for (var seq = 1; seq <= head; seq++) {
    await shell.acceptMessage(message(seq, conversationId: conversationId));
  }
  return shell;
}

void main() {
  test(
    'an absent read position defaults to zero instead of hiding unread',
    () async {
      final store = MemoryPersistence();
      final shell = await seeded(store);
      // Everything cached above the history floor is still unread: defaulting to
      // the sync cursor would silently mark every cached message as read.
      expect(shell.readSeqFor('c'), 0);
      expect(shell.readSeqFor('never-synced'), 0);
    },
  );

  test('markRead advances and persists one read position', () async {
    final store = MemoryPersistence();
    final shell = await seeded(store);
    final before = store.writeAttempts;

    await shell.markRead('c', 3);
    expect(shell.readSeqFor('c'), 3);
    expect(store.writeAttempts, before + 1);
    expect((store.data!['shell'] as Map)['readSeq'], {'c': 3});

    // Only one top-level key is added inside the existing shell section; the
    // other sections keep their shape and no schema version is bumped.
    expect(store.data!.keys, ['shell']);
    expect(
      (store.data!['shell'] as Map).keys,
      containsAll(<String>[
        'outbox',
        'dropped',
        'drafts',
        'cursors',
        'messages',
        'readSeq',
      ]),
    );
  });

  test('markRead only moves forward and never writes a rewind', () async {
    final store = MemoryPersistence();
    final shell = await seeded(store);
    await shell.markRead('c', 4);
    final writes = store.writeAttempts;

    await shell.markRead('c', 2);
    await shell.markRead('c', 4);
    expect(shell.readSeqFor('c'), 4);
    expect(store.writeAttempts, writes);
  });

  test('markRead never advances past the cached head', () async {
    final store = MemoryPersistence();
    final shell = await seeded(store, head: 3);

    await shell.markRead('c', 99);
    expect(shell.readSeqFor('c'), 3);
    expect((store.data!['shell'] as Map)['readSeq'], {'c': 3});
  });

  test('markRead clamps to the history floor when nothing is cached', () async {
    final store = MemoryPersistence();
    final shell = build(store);
    await shell.initialize();
    await shell.applySyncHistoryFloor('c', 3);
    expect(shell.lastSeqFor('c'), 2);

    await shell.markRead('c', 99);
    // A floor-only conversation has no visible message to read past.
    expect(shell.readSeqFor('c'), 2);
  });

  test('read positions survive a restart', () async {
    final store = MemoryPersistence();
    final shell = await seeded(store);
    await shell.acceptMessage(message(1, conversationId: 'other'));
    await shell.markRead('c', 2);
    await shell.markRead('other', 1);

    final reboot = build(store);
    await reboot.initialize();
    expect(reboot.readSeqFor('c'), 2);
    expect(reboot.readSeqFor('other'), 1);
    expect(reboot.readSeqFor('absent'), 0);
  });

  test(
    'a snapshot written before read positions existed still restores',
    () async {
      final store = MemoryPersistence();
      store.data = {
        'shell': {
          'outbox': <Object?>[],
          'dropped': <Object?>[],
          'drafts': <String, Object?>{},
          'cursors': {'c': 7},
          'messages': <Object?>[],
        },
      };

      final shell = build(store);
      await shell.initialize();
      expect(shell.lastSeqFor('c'), 7);
      // No stored position is not "everything read".
      expect(shell.readSeqFor('c'), 0);
      await shell.markRead('c', 7);
      expect(shell.readSeqFor('c'), 7);
    },
  );

  test('a failed checkpoint keeps the previous read position', () async {
    final store = MemoryPersistence();
    final shell = await seeded(store);
    await shell.markRead('c', 2);
    final snapshot = await store.read();
    store.fail = true;

    await expectLater(shell.markRead('c', 5), throwsStateError);
    expect(shell.readSeqFor('c'), 2);
    expect(await store.read(), snapshot);

    store.fail = false;
    await shell.markRead('c', 5);
    expect(shell.readSeqFor('c'), 5);
    final reboot = build(store);
    await reboot.initialize();
    expect(reboot.readSeqFor('c'), 5);
  });

  test(
    'a rejected mark publishes nothing even after the write starts',
    () async {
      final store = MemoryPersistence();
      final shell = await seeded(store);
      await shell.markRead('c', 1);
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      store.beforeRead = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      var active = true;
      final failed = expectLater(
        shell.markRead(
          'c',
          4,
          checkActive: () {
            if (!active) throw StateError('expired');
          },
        ),
        throwsStateError,
      );
      await started.future.timeout(const Duration(seconds: 5));
      active = false;
      release.complete();
      await failed;
      expect(shell.readSeqFor('c'), 1);
      expect(((store.data!['shell'] as Map)['readSeq'] as Map)['c'], 1);
    },
  );

  test(
    'a mark queued behind another write cannot checkpoint once cancelled',
    () async {
      final store = MemoryPersistence();
      final shell = await seeded(store);
      final writing = Completer<void>(), release = Completer<void>();
      final checked = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      store.beforeWrite = () async {
        if (!writing.isCompleted) writing.complete();
        await release.future;
      };
      final other = writeClientSection(store, 'consent', {'approved': true});
      await writing.future.timeout(const Duration(seconds: 5));
      var active = true;
      final mark = expectLater(
        shell.markRead(
          'c',
          3,
          checkActive: () {
            if (!active) throw StateError('superseded');
            if (!checked.isCompleted) checked.complete();
          },
        ),
        throwsStateError,
      );
      await checked.future.timeout(const Duration(seconds: 5));
      active = false;
      release.complete();
      await Future.wait([other, mark]);
      expect(shell.readSeqFor('c'), 0);
      final snapshot = await store.read();
      expect((snapshot!['shell'] as Map)['readSeq'], isEmpty);
      expect(snapshot['consent'], {'approved': true});
    },
  );

  test('a negative read position is rejected without writing', () async {
    final store = MemoryPersistence();
    final shell = await seeded(store);
    final writes = store.writeAttempts;
    await expectLater(shell.markRead('c', -1), throwsArgumentError);
    expect(shell.readSeqFor('c'), 0);
    expect(store.writeAttempts, writes);
  });

  test('conversations keep independent read positions', () async {
    final store = MemoryPersistence();
    final shell = build(store);
    await shell.initialize();
    for (final seq in [1, 2, 3]) {
      await shell.acceptMessage(message(seq));
    }
    await shell.acceptMessage(message(1, conversationId: 'other'));
    await shell.acceptMessage(message(2, conversationId: 'other'));

    await shell.markRead('c', 2);
    expect(shell.readSeqFor('c'), 2);
    expect(shell.readSeqFor('other'), 0);

    await shell.markRead('other', 2);
    final reboot = build(store);
    await reboot.initialize();
    expect(reboot.readSeqFor('c'), 2);
    expect(reboot.readSeqFor('other'), 2);
  });
}
