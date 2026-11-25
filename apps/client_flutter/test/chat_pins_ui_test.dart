import 'dart:async';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/net/chat_pins_api.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/chat_pins_fixture.dart';

final _openPins = find.byKey(const Key('open-chat-pins'));
final _managePin = find.byKey(const Key('message-action-pin'));
final _confirm = find.byKey(const Key('chat-pin-confirm'));
final _refresh = find.byKey(const Key('chat-pins-refresh'));
final _empty = find.byKey(const Key('chat-pins-empty'));
final _readFailure = find.byKey(const Key('chat-pins-read-failure'));
final _accepted = find.byKey(const Key('chat-pin-confirmed'));
final _unknown = find.byKey(const Key('chat-pin-unknown'));
final _refused = find.byKey(const Key('chat-pin-refused'));
Finder _pin(String id) => find.byKey(Key('chat-pinned-message-$id'));

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  final deadline = Stopwatch()..start();
  while (finder.evaluate().isEmpty &&
      deadline.elapsed < const Duration(seconds: 8)) {
    await tester.pump(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(milliseconds: 12));
  }
  expect(finder, findsOneWidget);
}

Future<void> _tapAndWait(WidgetTester tester, Finder from, Finder to) async {
  await tester.runAsync(() async {
    await tester.tap(from);
    await _waitFor(tester, to);
  });
  await tester.pumpAndSettle();
}

Future<void> _showChat(
  WidgetTester t,
  ClientRuntime runtime, {
  double width = 390,
}) async {
  t.view.physicalSize = Size(width, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(WhaleChatApp(model: runtime));
  await t.tap(find.byKey(const ValueKey(pinsChat)));
  await t.pumpAndSettle();
  expect(find.text(ownText), findsOneWidget);
}

Future<void> _manage(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(Key('message-actions-$id')));
  await tester.pumpAndSettle();
  await _tapAndWait(tester, _managePin, _confirm);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late ChatPinsFixture fixture;
  late ClientRuntime runtime;

  setUp(() async {
    fixture = await ChatPinsFixture.create();
    runtime = await fixture.openRuntime();
  });
  tearDown(() async {
    runtime.dispose();
    await fixture.cleanup();
  });

  test(
    'runtime rejects a stale selection and never writes hidden or recalled IDs',
    () async {
      await runtime.selectConversation(pinsChat);
      final original = runtime.messageOperationsContext!;
      Future<ChatPinWrite> set(String id, {bool pinned = true}) =>
          runtime.setMessagePinned(
            conversationId: pinsChat,
            messageId: id,
            pinned: pinned,
            expectedContext: original,
            viewIsCurrent: () => true,
          );
      expect(await set(hiddenMessage), ChatPinWrite.cancelled);
      expect(await set(recalledMessage, pinned: false), ChatPinWrite.cancelled);
      await runtime.selectConversation(otherChat);
      await runtime.selectConversation(pinsChat);
      expect(await set(peerMessage), ChatPinWrite.cancelled);
      expect(fixture.writes, isEmpty);
      expect(fixture.reads, 0);
    },
  );

  testWidgets('the in-chat list projects only current visible live pins', (
    t,
  ) async {
    await _showChat(t, runtime);
    expect(fixture.reads, 0, reason: 'no read before a user action');
    expect(fixture.writes, isEmpty);
    final cursors = (
      runtime.shell.lastSeqFor(pinsChat),
      runtime.shell.readSeqFor(pinsChat),
    );
    await _tapAndWait(t, _openPins, _pin(peerMessage));
    expect(fixture.reads, 1);
    expect(
      find.descendant(of: _pin(peerMessage), matching: find.text(peerText)),
      findsOneWidget,
    );
    expect(_pin(hiddenMessage), findsNothing);
    expect(_pin(recalledMessage), findsNothing);
    expect(find.text(hiddenActor), findsNothing);
    expect(_empty, findsNothing);
    expect(fixture.writes, isEmpty);
    expect((
      runtime.shell.lastSeqFor(pinsChat),
      runtime.shell.readSeqFor(pinsChat),
    ), cursors);
  });

  testWidgets(
    'explicit pin and unpin issue one write each and read back current state',
    (t) async {
      await _showChat(t, runtime);
      await _manage(t, ownMessage);
      expect(
        fixture.writes,
        isEmpty,
        reason: 'opening the confirmation must not write',
      );
      expect(
        find.descendant(of: _confirm, matching: find.text('置顶')),
        findsOneWidget,
      );
      await _tapAndWait(t, _confirm, _accepted);
      expect(fixture.writes, [
        (
          'POST',
          '/api/v1/conversations/$pinsChat/messages/$ownMessage/pin',
          '',
        ),
      ]);
      await t.tap(find.byKey(const Key('close-chat-pins')));
      await t.pumpAndSettle();
      await _tapAndWait(t, _openPins, _pin(ownMessage));
      await t.tap(find.byKey(const Key('close-chat-pins')));
      await t.pumpAndSettle();
      await _manage(t, ownMessage);
      expect(
        find.descendant(of: _confirm, matching: find.text('取消置顶')),
        findsOneWidget,
      );
      await _tapAndWait(t, _confirm, _accepted);
      expect(fixture.writes.last, (
        'DELETE',
        '/api/v1/conversations/$pinsChat/messages/$ownMessage/pin',
        '',
      ));
      expect(fixture.writes.length, 2);
      await t.tap(find.byKey(const Key('close-chat-pins')));
      await t.pumpAndSettle();
      await _tapAndWait(t, _openPins, _pin(peerMessage));
      expect(_pin(ownMessage), findsNothing);
    },
  );

  testWidgets(
    'read failure is not empty; explicit refresh can confirm a visible empty list',
    (t) async {
      fixture.listStatus = 503;
      await _showChat(t, runtime);
      await _tapAndWait(t, _openPins, _readFailure);
      expect(_empty, findsNothing);
      expect(fixture.reads, 1);
      expect(fixture.writes, isEmpty);
      fixture.listStatus = 200;
      fixture.pinned.remove(peerMessage);
      await _tapAndWait(t, _refresh, _empty);
      expect(_readFailure, findsNothing);
      expect(fixture.reads, 2);
      expect(_pin(hiddenMessage), findsNothing);
      expect(_pin(recalledMessage), findsNothing);
      expect(fixture.writes, isEmpty);
    },
  );

  testWidgets(
    'an offline list prompts a read after reconnect and never implies empty',
    (t) async {
      await _showChat(t, runtime);
      fixture.hostInfoStatus = 503;
      await t.runAsync(runtime.refreshConversations);
      await t.pumpAndSettle();
      expect(runtime.online, isFalse);
      await t.tap(_openPins);
      await t.pumpAndSettle();
      expect(find.text('连接宿主后才能查看或修改置顶。'), findsOneWidget);
      expect(_empty, findsNothing);
      expect(fixture.reads, 0);
      fixture.hostInfoStatus = 200;
      await t.runAsync(runtime.refreshConversations);
      await t.pumpAndSettle();
      expect(runtime.online, isTrue);
      expect(find.byKey(const Key('chat-pins-refresh-needed')), findsOneWidget);
      expect(
        fixture.reads,
        0,
        reason: 'no background pins read after reconnect',
      );
      await _tapAndWait(t, _refresh, _pin(peerMessage));
      expect(fixture.reads, 1);
      expect(fixture.writes, isEmpty);
    },
  );

  testWidgets('a known receipt cannot substitute for a failed list readback', (
    t,
  ) async {
    fixture.readStatusAfterWrite = 503;
    await _showChat(t, runtime);
    await _manage(t, ownMessage);
    await _tapAndWait(t, _confirm, _accepted);
    expect(_readFailure, findsOneWidget);
    expect(_empty, findsNothing);
    expect(_confirm, findsNothing);
    expect(fixture.reads, 2);
    expect(fixture.writes.length, 1);
  });

  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('pins and group controls fit at $width logical pixels', (
      t,
    ) async {
      await _showChat(t, runtime, width: width);
      expect(
        find.byKey(const Key('add-group-member')).hitTestable(),
        findsOneWidget,
      );
      await _tapAndWait(t, _openPins, _pin(peerMessage));
      expect(
        find.byKey(const Key('close-chat-pins')).hitTestable(),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
      expect(fixture.writes, isEmpty);
    });
  }

  testWidgets('a write refusal is not shown as a confirmed change', (t) async {
    fixture.writeStatus = 403;
    await _showChat(t, runtime);
    // Author of a pin is not the client authority; the host decides if writing is allowed.
    await _manage(t, peerMessage);
    await _tapAndWait(t, _confirm, _refused);
    expect(_accepted, findsNothing);
    expect(fixture.pinned, contains(peerMessage));
    expect(fixture.writes.length, 1);
  });

  testWidgets('an ambiguous receipt disables writes until an explicit read', (
    t,
  ) async {
    fixture.writeStatus = 500;
    fixture.commitWithoutReceipt = true;
    await _showChat(t, runtime);
    await _manage(t, ownMessage);
    await _tapAndWait(t, _confirm, _unknown);
    expect(_accepted, findsNothing);
    expect(_empty, findsNothing);
    expect(_confirm.hitTestable(), findsNothing);
    expect(fixture.writes.length, 1);
    expect(fixture.reads, 1, reason: 'no auto-retry or optimistic read-back');
    fixture.listStatus = 503;
    await _tapAndWait(t, _refresh, _readFailure);
    expect(
      _unknown,
      findsOneWidget,
      reason: 'a failed read cannot clear write uncertainty',
    );
    expect(_confirm, findsNothing);
    fixture.listStatus = 200;
    await _tapAndWait(t, _refresh, _confirm);
    expect(_unknown, findsNothing);
    expect(
      find.descendant(of: _confirm, matching: find.text('取消置顶')),
      findsOneWidget,
    );
    expect(fixture.reads, 3);
    expect(fixture.writes.length, 1);
  });

  testWidgets('a stale confirmation cannot write after the selection changes', (
    t,
  ) async {
    await _showChat(t, runtime);
    await _manage(t, peerMessage);
    await t.runAsync(() async {
      await runtime.selectConversation(otherChat);
      // Still tap the already-rendered old button before the remake frame.
      await t.tap(_confirm);
    });
    await t.pumpAndSettle();
    expect(fixture.writes, isEmpty);
    expect(_confirm, findsNothing);
    expect(find.text(peerText), findsNothing);
  });

  testWidgets('a late read cannot expose a pin in another chat', (t) async {
    await _showChat(t, runtime);
    await t.runAsync(() async {
      // Both gates must belong to the real I/O Zone, not the widget fake clock.
      final arrived = Completer<void>();
      final release = Completer<void>();
      fixture.beforeList = () async {
        arrived.complete();
        await release.future;
      };
      try {
        await t.tap(_openPins);
        final deadline = Stopwatch()..start();
        while (!arrived.isCompleted &&
            deadline.elapsed < const Duration(seconds: 8)) {
          await t.pump(const Duration(milliseconds: 16));
          await Future<void>.delayed(const Duration(milliseconds: 12));
        }
        expect(arrived.isCompleted, isTrue, reason: 'read reached loopback');
        expect(find.byKey(const Key('chat-pins-loading')), findsOneWidget);
        await runtime.selectConversation(otherChat);
      } finally {
        release.complete();
      }
    });
    await t.pumpAndSettle();
    expect(_pin(peerMessage), findsNothing);
    expect(find.text(peerText), findsNothing);
    expect(_accepted, findsNothing);
    expect(fixture.writes, isEmpty);
  });
}
