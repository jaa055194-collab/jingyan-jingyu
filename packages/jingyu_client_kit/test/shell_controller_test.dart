import 'dart:async';
import 'dart:convert';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class MemoryPersistence implements ClientPersistence {
  Map<String, Object?>? data;
  bool fail = false;
  @override
  Future<Map<String, Object?>?> read() async => data == null
      ? null
      : Map<String, Object?>.from(jsonDecode(jsonEncode(data)) as Map);
  @override
  Future<void> write(Map<String, Object?> snapshot) async {
    if (fail) throw StateError('disk full');
    data = Map<String, Object?>.from(jsonDecode(jsonEncode(snapshot)) as Map);
  }
}

MessageEventFrame message(int seq) => MessageEventFrame(
  id: 'e$seq',
  at: DateTime.utc(2026),
  conversationId: 'c',
  seq: seq,
  messageId: 'm$seq',
  senderId: 'u',
  kind: MessageKind.text,
  body: {'text': '$seq'},
  sentAt: DateTime.utc(2026),
);
void main() {
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
