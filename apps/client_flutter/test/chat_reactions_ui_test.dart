import 'dart:async';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/net/message_reactions_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/chat_reactions_fixture.dart';

Finder k(String key) => find.byKey(Key(key));
final entry = k('message-action-reactions');
final like = k('message-reaction-thumbsUp');
final heart = k('message-reaction-heart');
final refresh = k('message-reactions-refresh');
final success = k('message-reactions-confirmed');
final unavailable = k('message-reactions-unavailable');
final unknown = k('message-reactions-unknown');
final invalid = k('message-reactions-retired');

Future<void> showReactionTestChat(
  WidgetTester t,
  ClientRuntime runtime, {
  double width = 390,
}) async {
  t.view.physicalSize = Size(width, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(WhaleChatApp(model: runtime));
  await t.pumpAndSettle();
  await t.tap(k(pinsChat));
  await t.pumpAndSettle();
  expect(find.text(peerText), findsOneWidget);
}

Future<void> tapAndWait(WidgetTester t, Finder action, Finder result) async {
  expect(action.hitTestable(), findsOneWidget);
  await t.runAsync(() async {
    await t.tap(action);
    // Retire the previous success frame before waiting for a new receipt.
    await t.pump();
    final elapsed = Stopwatch()..start();
    while (result.evaluate().isEmpty &&
        elapsed.elapsed < const Duration(seconds: 8)) {
      await t.pump(const Duration(milliseconds: 16));
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
    expect(result, findsOneWidget);
  });
  await t.pumpAndSettle();
}

Future<void> showActions(WidgetTester t) async {
  await t.tap(k('message-actions-$peerMessage'));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late ChatReactionsFixture fixture;
  late ClientRuntime runtime;
  setUp(() async {
    fixture = await ChatReactionsFixture.create();
    runtime = await fixture.open();
  });
  tearDown(() async {
    runtime.dispose();
    await fixture.cleanup();
  });

  test(
    'runtime rejects hidden rows, recalled rows and pre-lock callbacks',
    () async {
      await runtime.selectConversation(pinsChat);
      final scope = runtime.messageOperationsContext!;
      Future<ReactionRead> read(String id) => runtime.readMessageReactions(
        conversationId: pinsChat,
        messageId: id,
        expectedContext: scope,
        viewIsCurrent: () => true,
      );
      Future<ReactionWrite> toggle(String id) => runtime.toggleMessageReaction(
        conversationId: pinsChat,
        messageId: id,
        choice: ChatReaction.thumbsUp,
        expectedContext: scope,
        viewIsCurrent: () => true,
      );
      for (final id in [hiddenMessage, recalledMessage]) {
        expect(await read(id), isA<ReactionsUnavailable>());
        expect(await toggle(id), isA<ReactionCancelled>());
      }
      await runtime.setAppLock(true, '1234');
      expect(runtime.appLock.enabled, isTrue);
      runtime.appLock.lock();
      expect(runtime.locked, isTrue);
      expect(await read(peerMessage), isA<ReactionsUnavailable>());
      expect(await toggle(peerMessage), isA<ReactionCancelled>());
      expect(fixture.requests, isEmpty);
    },
  );

  testWidgets(
    'kebab opens fixed aggregate and mine states without exposing legacy strings',
    (t) async {
      await showReactionTestChat(t, runtime);
      final cursors = (
        runtime.shell.lastSeqFor(pinsChat),
        runtime.shell.readSeqFor(pinsChat),
      );
      expect(fixture.requests, isEmpty);
      expect(k('message-actions-$recalledMessage'), findsNothing);
      await showActions(t);
      expect(entry.hitTestable(), findsOneWidget);
      expect(k('message-action-copy'), findsOneWidget);
      expect(k('message-action-pin'), findsOneWidget);
      expect(fixture.requests, isEmpty);
      await tapAndWait(t, entry, like);
      expect(t.widget<FilterChip>(like).selected, isFalse);
      expect(t.widget<FilterChip>(heart).selected, isTrue);
      expect(
        find.descendant(of: heart, matching: find.text('2')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: like, matching: find.text('1')),
        findsOneWidget,
      );
      expect(find.text(reactionActor), findsNothing);
      expect(find.text(legacyReaction), findsNothing);
      expect(fixture.requests, [('GET', peerReactionPath, '')]);
      expect((
        runtime.shell.lastSeqFor(pinsChat),
        runtime.shell.readSeqFor(pinsChat),
      ), cursors);
    },
  );

  testWidgets('add and remove each toggle once and require matching readback', (
    t,
  ) async {
    await showReactionTestChat(t, runtime, width: 375);
    await showActions(t);
    await tapAndWait(t, entry, like);
    final staleTap = t.widget<FilterChip>(like).onSelected!;
    await t.runAsync(() async {
      staleTap(true);
      staleTap(true); // No frame between the two calls.
      final elapsed = Stopwatch()..start();
      while (success.evaluate().isEmpty &&
          elapsed.elapsed < const Duration(seconds: 8)) {
        await t.pump(const Duration(milliseconds: 16));
        await Future<void>.delayed(const Duration(milliseconds: 12));
      }
    });
    await t.pumpAndSettle();
    expect(success, findsOneWidget);
    expect(fixture.writes, 1);
    staleTap(
      true,
    ); // Retained callback from the old list must not toggle again.
    expect(t.widget<FilterChip>(like).selected, isTrue);
    expect(find.descendant(of: like, matching: find.text('2')), findsOneWidget);
    await tapAndWait(t, like, success);
    expect(t.widget<FilterChip>(like).selected, isFalse);
    expect(fixture.requests, [
      ('GET', peerReactionPath, ''),
      ('POST', peerReactionPath, '{"emoji":"👍"}'),
      ('GET', peerReactionPath, ''),
      ('POST', peerReactionPath, '{"emoji":"👍"}'),
      ('GET', peerReactionPath, ''),
    ]);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'unknown toggle and failed explicit refresh do not invite blind toggles',
    (t) async {
      fixture.writeStatus = 500;
      fixture.appliesWithoutReceipt = true;
      await showReactionTestChat(t, runtime);
      await showActions(t);
      await tapAndWait(t, entry, like);
      await tapAndWait(t, like, unknown);
      expect(success, findsNothing);
      expect(like, findsNothing);
      expect(fixture.writes, 1);
      expect(
        fixture.reads,
        1,
        reason: 'unknown cannot trigger another automatic request',
      );
      fixture.readStatus = 503;
      await tapAndWait(t, refresh, unavailable);
      expect(unknown, findsOneWidget);
      expect(like, findsNothing);
      fixture.readStatus = 200;
      await tapAndWait(t, refresh, like);
      expect(t.widget<FilterChip>(like).selected, isTrue);
      expect(unknown, findsNothing);
      expect(success, findsNothing);
      expect(fixture.writes, 1);
    },
  );

  testWidgets(
    'matching receipt without matching readback does not claim success',
    (t) async {
      await showReactionTestChat(t, runtime);
      await showActions(t);
      await tapAndWait(t, entry, like);
      fixture.staleReadback = true;
      await tapAndWait(t, like, k('message-reactions-unconfirmed'));
      expect(like, findsNothing);
      expect(success, findsNothing);
      expect(fixture.reads, 2);
      expect(fixture.writes, 1);
    },
  );

  testWidgets(
    'read denial and write denial remain distinct from empty results',
    (t) async {
      fixture.readStatus = 404;
      await showReactionTestChat(t, runtime);
      await showActions(t);
      await tapAndWait(t, entry, unavailable);
      expect(like, findsNothing);
      expect(k('message-reactions-empty'), findsNothing);
      fixture.readStatus = 200;
      fixture.writeStatus = 404;
      await tapAndWait(t, refresh, like);
      await tapAndWait(t, like, k('message-reactions-refused'));
      expect(success, findsNothing);
      expect(fixture.reads, 2);
      expect(fixture.writes, 1);
    },
  );

  testWidgets('while writing, the sheet cannot be dismissed or toggled again', (
    t,
  ) async {
    await showReactionTestChat(t, runtime);
    await showActions(t);
    await tapAndWait(t, entry, like);
    await t.runAsync(() async {
      final arrived = Completer<void>();
      final release = Completer<void>();
      fixture.beforeReceipt = () async {
        arrived.complete();
        await release.future;
      };
      try {
        await t.tap(like);
        await arrived.future.timeout(const Duration(seconds: 8));
        await t.pump();
        expect(like, findsNothing);
        expect(
          t.widget<TextButton>(k('message-reactions-close')).onPressed,
          isNull,
        );
        await t.binding.handlePopRoute();
        await t.pump();
        expect(k('message-reactions-sheet'), findsOneWidget);
      } finally {
        release.complete();
      }
      final elapsed = Stopwatch()..start();
      while (success.evaluate().isEmpty &&
          elapsed.elapsed < const Duration(seconds: 8)) {
        await t.pump(const Duration(milliseconds: 16));
        await Future<void>.delayed(const Duration(milliseconds: 12));
      }
      expect(success, findsOneWidget);
    });
    expect(fixture.writes, 1);
    expect(fixture.reads, 2);
  });

  testWidgets('a retained toggle is inert after chat A→B→A', (t) async {
    await showReactionTestChat(t, runtime);
    await showActions(t);
    await tapAndWait(t, entry, like);
    final tap = t.widget<FilterChip>(like).onSelected!;
    await t.runAsync(() async {
      await runtime.selectConversation(otherChat);
      await runtime.selectConversation(pinsChat);
      tap(true);
    });
    await t.pumpAndSettle();
    expect(invalid, findsOneWidget);
    expect(like, findsNothing);
    expect(fixture.writes, 0);
  });

  testWidgets(
    'a delayed confirmed toggle cannot publish or read back after chat switch',
    (t) async {
      await showReactionTestChat(t, runtime);
      await showActions(t);
      await tapAndWait(t, entry, like);
      await t.runAsync(() async {
        final arrived = Completer<void>();
        final release = Completer<void>();
        fixture.beforeReceipt = () async {
          arrived.complete();
          await release.future;
        };
        try {
          await t.tap(like);
          await arrived.future.timeout(const Duration(seconds: 8));
          await runtime.selectConversation(otherChat);
        } finally {
          release.complete();
        }
      });
      await t.pumpAndSettle();
      expect(invalid, findsOneWidget);
      expect(like, findsNothing);
      expect(success, findsNothing);
      expect(fixture.writes, 1);
      expect(fixture.reads, 1);
    },
  );
}
