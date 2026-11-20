import 'dart:async';
import 'dart:convert';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
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
ClientShellController historyShell(
  MemoryPersistence store, {
  List<SyncRequestFrame>? requests,
}) => ClientShellController(
  persistence: store,
  submit: (_) async => throw StateError('History floor must not submit'),
  requestSync: (frame) async {
    if (requests == null) throw StateError('Unexpected sync request');
    requests.add(frame);
  },
);

void main() {
  test('a failed draft checkpoint retains the prior draft in memory', () async {
    final store = MemoryPersistence();
    final shell = historyShell(store);
    await shell.initialize();
    await shell.saveDraft('c', 'previous');
    final snapshot = await store.read();
    store.fail = true;

    await expectLater(
      shell.saveDraft('c', 'new draft', checkActive: () {}),
      throwsStateError,
    );
    expect(shell.draftFor('c'), 'previous');
    expect(await store.read(), snapshot);
  });

  for (final boundary in ['queue', 'read']) {
    test('guarded draft cancels at shared writer $boundary boundary', () async {
      final store = MemoryPersistence();
      final shell = historyShell(store);
      await shell.initialize();
      await shell.saveDraft('c', 'previous');
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      Future<void>? other;
      if (boundary == 'queue') {
        store.beforeWrite = () async {
          if (!started.isCompleted) started.complete();
          await release.future;
        };
        other = writeClientSection(store, 'consent', {'allowed': false});
        await started.future;
      } else {
        store.beforeRead = () async {
          if (!started.isCompleted) started.complete();
          await release.future;
        };
      }
      var active = true;
      final failed = expectLater(
        shell.saveDraft(
          'c',
          'incoming',
          checkActive: () {
            if (!active) throw StateError('expired');
          },
        ),
        throwsStateError,
      );
      if (boundary == 'read') await started.future;
      active = false;
      release.complete();
      await other;
      await failed;
      expect(shell.draftFor('c'), 'previous');
      expect(((store.data!['shell'] as Map)['drafts'] as Map)['c'], 'previous');
    });
  }

  test(
    'a floor-only checkpoint restores before visible history arrives',
    () async {
      final store = MemoryPersistence();
      final shell = historyShell(store);
      await shell.initialize();

      await shell.applySyncHistoryFloor('c', 3);
      expect(shell.lastSeqFor('c'), 2);
      expect(shell.messagesFor('c'), isEmpty);
      expect(store.writeAttempts, 1);
      expect(store.data, {
        'shell': {
          'outbox': [],
          'dropped': [],
          'drafts': {},
          'cursors': {'c': 2},
          'readSeq': {},
          'messages': [],
        },
      });

      final requests = <SyncRequestFrame>[];
      final reboot = historyShell(store, requests: requests);
      await reboot.initialize();
      expect(reboot.lastSeqFor('c'), 2);
      expect(reboot.messagesFor('c'), isEmpty);
      expect(await reboot.acceptMessage(message(4)), MergeOutcome.gap);
      expect(requests.single.afterSeq, 2);
      expect(await reboot.acceptMessage(message(3)), MergeOutcome.applied);
      expect(requests, hasLength(1));
      expect(reboot.messagesFor('c').map((m) => m.seq), [3]);
    },
  );

  test('rejoin prunes only restricted messages without rewinding', () async {
    final store = MemoryPersistence();
    final shell = historyShell(store);
    await shell.initialize();
    for (final seq in [1, 2, 3, 4]) {
      await shell.acceptMessage(message(seq));
    }
    await shell.acceptMessage(message(1, conversationId: 'other'));
    await shell.saveDraft('c', 'keep draft');
    final queuedId = await shell.enqueue('c', MessageKind.text, {
      'text': 'keep queued',
    });
    final writes = store.writeAttempts;

    await shell.applySyncHistoryFloor('c', 4);
    expect(shell.messagesFor('c').map((m) => m.seq), [4]);
    expect(shell.lastSeqFor('c'), 4);
    expect(store.writeAttempts, writes + 1);
    await shell.applySyncHistoryFloor('c', 4);
    await shell.applySyncHistoryFloor('c', 2);
    expect(store.writeAttempts, writes + 1);

    final reboot = historyShell(store);
    await reboot.initialize();
    expect(reboot.messagesFor('c').map((m) => m.seq), [4]);
    expect(reboot.lastSeqFor('c'), 4);
    expect(reboot.messagesFor('other').map((m) => m.seq), [1]);
    expect(reboot.lastSeqFor('other'), 1);
    expect(reboot.draftFor('c'), 'keep draft');
    expect(reboot.outbox.items.single.clientMsgId, queuedId);
    expect(await reboot.acceptMessage(message(2)), MergeOutcome.duplicate);
    expect(await reboot.acceptMessage(message(5)), MergeOutcome.applied);
    expect(reboot.messagesFor('c').map((m) => m.seq), [4, 5]);
  });

  test(
    'a failed floor write never publishes the staged cursor or cache',
    () async {
      final store = MemoryPersistence();
      final shell = historyShell(store);
      await shell.initialize();
      await shell.acceptMessage(message(1));
      await shell.acceptMessage(message(2));
      final before = await store.read();
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      store.beforeWrite = () async {
        started.complete();
        await release.future;
      };
      store.fail = true;
      final failed = expectLater(
        shell.applySyncHistoryFloor('c', 4),
        throwsStateError,
      );

      await started.future.timeout(const Duration(seconds: 1));
      expect(shell.lastSeqFor('c'), 2);
      expect(shell.messagesFor('c').map((m) => m.seq), [1, 2]);
      release.complete();
      await failed;
      expect(shell.lastSeqFor('c'), 2);
      expect(shell.messagesFor('c').map((m) => m.seq), [1, 2]);
      expect(await store.read(), before);
      final beforeRetry = historyShell(store);
      await beforeRetry.initialize();
      expect(beforeRetry.lastSeqFor('c'), 2);
      expect(beforeRetry.messagesFor('c').map((m) => m.seq), [1, 2]);

      store.beforeWrite = null;
      store.fail = false;
      final retry = shell.applySyncHistoryFloor('c', 4);
      final visible = shell.acceptMessage(message(4));
      await retry;
      expect(await visible, MergeOutcome.applied);
      final afterRetry = historyShell(store);
      await afterRetry.initialize();
      expect(afterRetry.lastSeqFor('c'), 4);
      expect(afterRetry.messagesFor('c').map((m) => m.seq), [4]);
    },
  );

  test(
    'superseded sync work cannot mutate behind a pending draft write',
    () async {
      final store = MemoryPersistence();
      final shell = historyShell(store);
      await shell.initialize();
      await shell.acceptMessage(message(1));
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      store.beforeWrite = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      final draft = shell.saveDraft('other', 'keep');
      await started.future.timeout(const Duration(seconds: 5));
      var active = true;
      void checkActive() {
        if (!active) throw StateError('superseded');
      }

      final floor = expectLater(
        shell.applySyncHistoryFloor('c', 3, checkActive: checkActive),
        throwsStateError,
      );
      final row = expectLater(
        shell.acceptMessage(message(2), checkActive: checkActive),
        throwsStateError,
      );
      active = false;
      release.complete();
      await Future.wait([draft, floor, row]);
      expect(store.writeAttempts, 2);
      final reboot = historyShell(store);
      await reboot.initialize();
      expect(reboot.messagesFor('c').single.seq, 1);
      expect(reboot.lastSeqFor('c'), 1);
      expect(reboot.draftFor('other'), 'keep');
    },
  );

  test(
    'a floor waiting for another section cannot checkpoint after cancellation',
    () async {
      final store = MemoryPersistence();
      final shell = historyShell(store);
      await shell.initialize();
      await shell.acceptMessage(message(1));
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
      final floor = expectLater(
        shell.applySyncHistoryFloor(
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
      await Future.wait([other, floor]);
      expect(store.writeAttempts, 2);
      final reboot = historyShell(store);
      await reboot.initialize();
      expect(reboot.messagesFor('c').single.seq, 1);
      expect(reboot.lastSeqFor('c'), 1);
      expect((await store.read())?['consent'], {'approved': true});
    },
  );

  test('durable enqueue failure leaves no sendable in-memory item', () async {
    final store = MemoryPersistence();
    final shell = historyShell(store);
    await shell.initialize();
    store.fail = true;
    await expectLater(
      shell.enqueueDurable('c', MessageKind.file, {
        'attachmentId': 'attachment-1',
      }),
      throwsStateError,
    );
    expect(shell.outbox.items, isEmpty);
    store.fail = false;
    final id = await shell.enqueueDurable('c', MessageKind.file, {
      'attachmentId': 'attachment-1',
    });
    expect(shell.outbox.items.single.clientMsgId, id);
    final reboot = historyShell(store);
    await reboot.initialize();
    expect(reboot.outbox.items.single.clientMsgId, id);
  });

  test('invalid floors and an unchanged floor never write', () async {
    final store = MemoryPersistence();
    final shell = historyShell(store);
    await shell.initialize();

    for (final floor in [0, -1]) {
      await expectLater(
        shell.applySyncHistoryFloor('c', floor),
        throwsArgumentError,
      );
    }
    store.fail = true;
    await shell.applySyncHistoryFloor('c', 1);
    expect(shell.lastSeqFor('c'), 0);
    expect(shell.messagesFor('c'), isEmpty);
    expect(store.writeAttempts, 0);
  });

  for (final code in [FailureCode.unavailable, FailureCode.rateLimited]) {
    test(
      'overlapping shell flush shares transient flight without retry $code',
      () async {
        final store = MemoryPersistence(),
            started = Completer<void>(),
            release = Completer<void>();
        var sends = 0;
        final shell = ClientShellController(
          persistence: store,
          submit: (_) async {
            sends++;
            if (!started.isCompleted) started.complete();
            await release.future;
            return err<void>(code, 'temporary');
          },
          requestSync: (_) async {},
        );
        await shell.initialize();
        final id = await shell.enqueue('c', MessageKind.text, {
          'text': 'queued',
        });
        final first = shell.flush();
        await started.future;
        final second = shell.flush();
        release.complete();
        final reports = await Future.wait([first, second]);
        expect(sends, 1);
        expect(identical(first, second), isTrue);
        expect(identical(reports.first, reports.last), isTrue);
        expect(shell.outbox.items.single.clientMsgId, id);
        expect(shell.outbox.items.single.attempts, 1);
        await shell.flush();
        expect(sends, 2);
        expect(shell.outbox.items.single.attempts, 2);
      },
    );
  }
  test(
    'shared shell checkpoint errors release flight for later explicit retry',
    () async {
      final store = MemoryPersistence();
      var sends = 0;
      final shell = ClientShellController(
        persistence: store,
        submit: (_) async {
          sends++;
          return const Ok(null);
        },
        requestSync: (_) async {},
      );
      await shell.initialize();
      await shell.enqueue('c', MessageKind.text, {'text': 'queued'});
      store.fail = true;
      final first = shell.flush(), second = shell.flush();
      await Future.wait([
        expectLater(first, throwsStateError),
        expectLater(second, throwsStateError),
      ]);
      expect(identical(first, second), isTrue);
      expect(sends, 0);
      store.fail = false;
      expect((await shell.flush()).sent, 1);
      expect(sends, 1);
    },
  );
  test(
    'durable enqueue survives restart and concurrent flush preserves ids',
    () async {
      final store = MemoryPersistence();
      final sent = <String>[];
      final gate = Completer<void>();
      final first = ClientShellController(
        persistence: store,
        submit: (_) async => const Ok(null),
        requestSync: (_) async {},
      );
      await first.initialize();
      final id = await first.enqueue('c', MessageKind.text, {
        'text': 'offline',
      });
      final shell = ClientShellController(
        persistence: store,
        submit: (item) async {
          sent.add(item.clientMsgId);
          await gate.future;
          return const Ok(null);
        },
        requestSync: (_) async {},
      );
      await shell.initialize();
      final a = shell.flush();
      final b = shell.flush();
      gate.complete();
      await Future.wait([a, b]);
      expect(sent, [id]);
      expect(shell.outbox.items, isEmpty);
      final reboot = ClientShellController(
        persistence: store,
        submit: (_) async => const Ok(null),
        requestSync: (_) async {},
      );
      await reboot.initialize();
      expect(reboot.outbox.items, isEmpty);
    },
  );
  test(
    'failed persistence prevents network and failed permanent sends survive restart',
    () async {
      final store = MemoryPersistence();
      var sends = 0;
      ClientShellController build() => ClientShellController(
        persistence: store,
        submit: (_) async {
          sends++;
          return err(FailureCode.forbidden, 'blocked');
        },
        requestSync: (_) async {},
      );
      final shell = build();
      await shell.initialize();
      store.fail = true;
      await expectLater(
        shell.enqueue('c', MessageKind.text, {'text': 'x'}),
        throwsStateError,
      );
      expect(sends, 0);
      store.fail = false;
      await shell.flush();
      expect(shell.dropped.single.failure.code, FailureCode.forbidden);
      final reboot = build();
      await reboot.initialize();
      expect(reboot.dropped.single.item.body['text'], 'x');
    },
  );
  test(
    'gap requests difference without appending and mirror/drafts survive restart',
    () async {
      final store = MemoryPersistence();
      final requests = <SyncRequestFrame>[];
      ClientShellController build() => ClientShellController(
        persistence: store,
        submit: (_) async => const Ok(null),
        requestSync: (f) async => requests.add(f),
      );
      final shell = build();
      await shell.initialize();
      expect(await shell.acceptMessage(message(1)), MergeOutcome.applied);
      expect(await shell.acceptMessage(message(3)), MergeOutcome.gap);
      expect(requests.single.afterSeq, 1);
      expect(shell.messagesFor('c').length, 1);
      await shell.saveDraft('c', 'hello');
      await shell.saveDraft('other', 'other draft');
      final reboot = build();
      await reboot.initialize();
      expect(reboot.draftFor('c'), 'hello');
      expect(reboot.draftFor('other'), 'other draft');
      expect(await reboot.acceptMessage(message(1)), MergeOutcome.duplicate);
      expect(await reboot.acceptMessage(message(2)), MergeOutcome.applied);
    },
  );
  test('gap callback may accept missing page without deadlocking', () async {
    final store = MemoryPersistence();
    late ClientShellController shell;
    shell = ClientShellController(
      persistence: store,
      submit: (_) async => const Ok(null),
      requestSync: (request) async {
        expect(request.afterSeq, 0);
        await shell.acceptMessage(message(1));
        await shell.acceptMessage(message(2));
      },
    );
    await shell.initialize();
    expect(
      await shell.acceptMessage(message(2)).timeout(const Duration(seconds: 1)),
      MergeOutcome.gap,
    );
    expect(shell.messagesFor('c').map((m) => m.seq), [1, 2]);
  });
  test('failed mirror checkpoint can retry same sequence durably', () async {
    final store = MemoryPersistence();
    final shell = ClientShellController(
      persistence: store,
      submit: (_) async => const Ok(null),
      requestSync: (_) async {},
    );
    await shell.initialize();
    store.fail = true;
    await expectLater(shell.acceptMessage(message(1)), throwsStateError);
    store.fail = false;
    expect(await shell.acceptMessage(message(1)), MergeOutcome.applied);
    final reboot = ClientShellController(
      persistence: store,
      submit: (_) async => const Ok(null),
      requestSync: (_) async {},
    );
    await reboot.initialize();
    expect(reboot.messagesFor('c').single.seq, 1);
  });
  test(
    'read position advances forward, clamps to the head, and survives restart',
    () async {
      final store = MemoryPersistence();
      final shell = historyShell(store);
      await shell.initialize();
      for (final seq in [1, 2, 3]) {
        await shell.acceptMessage(message(seq));
      }
      expect(shell.readSeqFor('c'), 0);
      final writes = store.writeAttempts;

      await shell.markRead('c', 2);
      expect(shell.readSeqFor('c'), 2);
      expect(store.writeAttempts, writes + 1);
      expect(((store.data!['shell'] as Map)['readSeq'] as Map)['c'], 2);

      // Never rewinds, never passes the cached head, and never rewrites.
      await shell.markRead('c', 1);
      await shell.markRead('c', 99);
      expect(shell.readSeqFor('c'), 3);
      expect(store.writeAttempts, writes + 2);

      final reboot = historyShell(store);
      await reboot.initialize();
      expect(reboot.readSeqFor('c'), 3);
      expect(reboot.readSeqFor('unknown'), 0);
      expect(reboot.messagesFor('c').map((m) => m.seq), [1, 2, 3]);
      expect(reboot.draftFor('c'), isEmpty);
    },
  );

  test('a failed read checkpoint keeps the previous position', () async {
    final store = MemoryPersistence();
    final shell = historyShell(store);
    await shell.initialize();
    await shell.acceptMessage(message(1));
    await shell.acceptMessage(message(2));
    await shell.markRead('c', 1);
    store.fail = true;

    await expectLater(shell.markRead('c', 2), throwsStateError);
    expect(shell.readSeqFor('c'), 1);
    expect(((store.data!['shell'] as Map)['readSeq'] as Map)['c'], 1);
  });

  test('read checkpoint honours checkActive before publishing', () async {
    final store = MemoryPersistence();
    final shell = historyShell(store);
    await shell.initialize();
    await shell.acceptMessage(message(1));
    final started = Completer<void>(), release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    store.beforeWrite = () async {
      if (!started.isCompleted) started.complete();
      await release.future;
    };
    final other = writeClientSection(store, 'consent', {'approved': true});
    await started.future;
    var active = true;
    final read = expectLater(
      shell.markRead(
        'c',
        1,
        checkActive: () {
          if (!active) throw StateError('superseded');
        },
      ),
      throwsStateError,
    );
    active = false;
    release.complete();
    await Future.wait([other, read]);
    expect(shell.readSeqFor('c'), 0);
    // The cancelled checkpoint never recorded a position for this conversation.
    expect(((store.data!['shell'] as Map)['readSeq'] as Map)['c'], isNull);
  });

  test(
    'restart without opening keeps unread history, upgrade seeds from cursor',
    () async {
      // A current install that synced but never opened 'c': the readSeq key
      // exists, so its 3 synced rows must still count as unread after restart.
      final store = MemoryPersistence();
      final shell = historyShell(store);
      await shell.initialize();
      await shell.acceptMessage(message(1, conversationId: 'other'));
      for (final seq in [1, 2, 3]) {
        await shell.acceptMessage(message(seq));
      }
      await shell.markRead('other', 1);
      expect(((store.data!['shell'] as Map)['readSeq'] as Map).keys, ['other']);

      final restart = historyShell(store);
      await restart.initialize();
      expect(restart.readSeqFor('c'), 0);
      expect(
        restart.messagesFor('c').where((m) => m.seq > restart.readSeqFor('c')),
        hasLength(3),
      );

      // A pre-upgrade snapshot has cursors but no readSeq key at all; that one
      // upgrade seeds each cursor so old history is not shown as unread.
      final upgraded = Map<String, Object?>.from(store.data!);
      final section = Map<String, Object?>.from(upgraded['shell'] as Map)
        ..remove('readSeq');
      upgraded['shell'] = section;
      store.data = upgraded;

      final seeded = historyShell(store);
      await seeded.initialize();
      expect(seeded.readSeqFor('c'), 3);
      expect(seeded.readSeqFor('other'), 1);
      expect(
        seeded.messagesFor('c').where((m) => m.seq > seeded.readSeqFor('c')),
        isEmpty,
      );
      // Seeding is memory-only; the snapshot is not rewritten on restore.
      expect((store.data!['shell'] as Map).containsKey('readSeq'), isFalse);
    },
  );

  test(
    'markRead above the cached head clamps instead of overshooting',
    () async {
      final store = MemoryPersistence();
      final shell = historyShell(store);
      await shell.initialize();
      await shell.acceptMessage(message(1));
      await shell.acceptMessage(message(2));

      await shell.markRead('c', 999);
      expect(shell.readSeqFor('c'), 2);
      expect(((store.data!['shell'] as Map)['readSeq'] as Map)['c'], 2);
    },
  );

  test(
    'AI attachment consent persists independently per conversation',
    () async {
      final store = MemoryPersistence();
      final consent = ConversationConsentController(store);
      await consent.initialize();
      expect(
        consent.requiresConsent('a', MessageKind.image, isAi: true),
        isTrue,
      );
      expect(
        consent.requiresConsent('a', MessageKind.text, isAi: true),
        isFalse,
      );
      await consent.grant('a');
      final reboot = ConversationConsentController(store);
      await reboot.initialize();
      expect(
        reboot.requiresConsent('a', MessageKind.file, isAi: true),
        isFalse,
      );
      expect(
        reboot.requiresConsent('b', MessageKind.image, isAi: true),
        isTrue,
      );
      expect(
        reboot.requiresConsent('b', MessageKind.image, isAi: false),
        isFalse,
      );
    },
  );
}
