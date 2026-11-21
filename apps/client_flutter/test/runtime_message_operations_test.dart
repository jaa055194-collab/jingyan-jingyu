import 'dart:async';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/net/message_operations_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/message_actions_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late MessageActionsFixture fixture;
  late ClientRuntime runtime;
  setUp(() async {
    fixture = await MessageActionsFixture.create();
    runtime = await fixture.open();
  });
  tearDown(() async {
    runtime.dispose();
    await fixture.host.cleanup();
  });

  ShellMessage row(String id) =>
      runtime.messages.singleWhere((m) => m.id == id);

  Future<MessageWriteOutcome> edit({
    String id = ownId,
    bool Function()? current,
  }) => runtime.editMessage(
    conversationId: chatId,
    messageId: id,
    expectedText: row(id).text,
    text: revisedText,
    expectedContext: runtime.messageOperationsContext!,
    viewIsCurrent: current ?? () => true,
  );

  Future<MessageWriteOutcome> recall(String id) => runtime.recallMessage(
    conversationId: chatId,
    messageId: id,
    expectedContext: runtime.messageOperationsContext!,
    viewIsCurrent: () => true,
  );

  test(
    'accepted edit persists exact body and local marker; composer untouched',
    () async {
      runtime.updateDraft(draftText);
      expect(await edit(), isA<MessageWriteAccepted>());
      expect(row(ownId).text, revisedText);
      expect(row(ownId).edited, isTrue);
      expect(runtime.draft, draftText);
      expect(runtime.shell.lastSeqFor(chatId), 4);
      expect(runtime.shell.readSeqFor(chatId), 4);
      expect(fixture.writes.single.$2, {
        'body': {
          'text': revisedText,
          'mentionAccountIds': ['sample-ai'],
        },
      });
      final reopened = await fixture.open();
      addTearDown(reopened.dispose);
      final restored = reopened.messages.singleWhere((m) => m.id == ownId);
      expect((restored.text, restored.edited), (revisedText, true));
    },
  );

  test('canonical recall placeholders keep no actionable plaintext', () async {
    expect(row(recalledId).recalled, isTrue, reason: 'host-supplied tombstone');
    final accepted = await recall(ownId);
    expect(accepted, isA<MessageWriteAccepted>());
    final removed = row(ownId);
    expect(removed.recalled, isTrue);
    expect(removed.copyText, isNull);
    expect(removed.attachmentId, isNull);
    expect(removed.favoriteEligible, isFalse);
    expect(removed.canEdit, isFalse);
    expect(runtime.shell.lastSeqFor(chatId), 4);
    expect(fixture.writes.single.$2, isNull);
  });

  test('peer edits and expired recalls never issue a write', () async {
    expect(await edit(id: peerId), isA<MessageWriteRejected>());
    expect(await recall(peerId), isA<MessageWriteRejected>());
    expect(await recall(oldId), isA<MessageWriteRejected>());
    expect(await recall(recalledId), isA<MessageWriteRejected>());
    expect(fixture.writes, isEmpty);
    expect(row(oldId).canEdit, isTrue, reason: 'only recall has a 24h window');
  });

  test(
    'definitive refusals and unconfirmed writes do not mutate local state',
    () async {
      fixture.mutationStatus = 403;
      expect(await edit(), isA<MessageWriteRejected>());
      fixture.mutationStatus = 500;
      expect(await recall(ownId), isA<MessageWriteUnknown>());
      expect(fixture.writes.length, 2);
      expect(
        (row(ownId).text, row(ownId).edited, row(ownId).recalled),
        (ownText, false, false),
      );
      expect(await edit(), isA<MessageWriteUnknown>());
      expect(
        fixture.writes.length,
        2,
        reason: 'do not repeat an ambiguous mutation',
      );
    },
  );

  test('a stale view cannot initiate a mutation', () async {
    expect(await edit(current: () => false), isA<MessageWriteCancelled>());
    expect(fixture.writes, isEmpty);
  });

  test(
    'a confirmed in-flight edit does not show feedback in another chat',
    () async {
      final posted = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      fixture.beforeMutationReply = () async {
        posted.complete();
        await release.future;
      };
      final outcome = edit();
      await posted.future.timeout(const Duration(seconds: 5));
      await runtime.selectConversation('elsewhere');
      release.complete();
      expect(await outcome, isA<MessageWriteCancelled>());
      expect(runtime.messages, isEmpty);
      await runtime.selectConversation(chatId);
      expect((row(ownId).text, row(ownId).edited), (revisedText, true));
    },
  );
}
