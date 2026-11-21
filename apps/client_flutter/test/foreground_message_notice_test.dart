import 'dart:async';
import 'dart:io';

import 'package:client_flutter/app/shell_app.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/foreground_notice_fixture.dart';

final _notice = find.text(ForegroundNoticeFixture.notice);

void _windowsTestWidgets(String name, WidgetTesterCallback check) =>
    testWidgets(name, check, skip: !Platform.isWindows);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  Future<ForegroundNoticeFixture> open(
    WidgetTester tester, {
    String page = '联系人',
    bool history = false,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final fixture = (await tester.runAsync(
      () => ForegroundNoticeFixture.open(history: history),
    ))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(WhaleChatApp(model: fixture.runtime));
    await openNoticeFixturePage(tester, page);
    return fixture;
  }

  _windowsTestWidgets(
    'one generic dismissible cue for an accepted inbound batch',
    (tester) async {
      final f = await open(tester);
      expect(_notice, findsNothing);
      f.add();
      f.add();
      await f.refresh(tester);
      expect(
        f.runtime.shell.lastSeqFor(ForegroundNoticeFixture.conversation),
        2,
      );
      expect(f.runtime.conversations.single.unread, 2);
      expect(_notice, findsOneWidget);
      expect(find.text(ForegroundNoticeFixture.contactsEmpty), findsOneWidget);
      expect(find.text(ForegroundNoticeFixture.peerText), findsNothing);
      expect(find.text(ForegroundNoticeFixture.conversation), findsNothing);
      expect(f.runtime.selectedConversationId, isNull);
      expect(f.writes, isEmpty);

      await tester.tap(find.byTooltip('关闭新消息提示'));
      await tester.pump();
      await f.refresh(tester);
      expect(_notice, findsNothing, reason: 'same cursor is not a new message');
      expect(f.runtime.conversations.single.unread, 2);
      expect(f.writes, isEmpty);
    },
  );

  _windowsTestWidgets(
    'Inbox stays in place and the cue expires without marking read',
    (tester) async {
      final f = await open(tester, page: '收件箱');
      f.add();
      await f.refresh(tester);
      expect(_notice, findsOneWidget);
      expect(find.byKey(const Key('inbox-refresh')), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(_notice, findsNothing);
      expect(f.runtime.conversations.single.unread, 1);
      expect(f.writes, isEmpty);
    },
  );

  _windowsTestWidgets(
    'history, own rows and recalled placeholders remain silent',
    (tester) async {
      final f = await open(tester, history: true);
      expect(f.runtime.conversations.single.unread, 1);
      expect(_notice, findsNothing);
      f.add(sender: 'alice');
      f.add(body: {'recalled': true});
      await f.refresh(tester);
      expect(
        f.runtime.shell.lastSeqFor(ForegroundNoticeFixture.conversation),
        3,
      );
      expect(_notice, findsNothing);
      f.add();
      await f.refresh(tester);
      expect(_notice, findsOneWidget);
    },
  );

  _windowsTestWidgets(
    'a malformed frame and skipped visibility-floor history are silent',
    (tester) async {
      final f = await open(tester);
      f.add();
      f.rows.last['body'] = 'malformed';
      await f.refresh(tester);
      expect(
        f.runtime.shell.lastSeqFor(ForegroundNoticeFixture.conversation),
        0,
      );
      expect(_notice, findsNothing);
      f.rows.clear();
      f.add();
      f.add();
      f.firstVisibleSeq = 2;
      await f.refresh(tester);
      expect(
        f.runtime.shell.lastSeqFor(ForegroundNoticeFixture.conversation),
        2,
      );
      expect(
        _notice,
        findsNothing,
        reason: 'unseen history floor is only seeded',
      );
      f.add();
      await f.refresh(tester);
      expect(
        _notice,
        findsOneWidget,
        reason: 'the unchanged floor is now primed',
      );
    },
  );

  _windowsTestWidgets(
    'the first refresh after an observed outage only re-baselines',
    (tester) async {
      final f = await open(tester);
      f.offline = true;
      await f.refresh(tester);
      expect(f.runtime.online, isFalse);
      f.add();
      f.offline = false;
      await f.refresh(tester);
      expect(f.runtime.online, isTrue);
      expect(f.runtime.conversations.single.unread, 1);
      expect(_notice, findsNothing);
      f.add();
      await f.refresh(tester);
      expect(_notice, findsOneWidget);
    },
  );

  for (final page in ['聊天', '动态']) {
    _windowsTestWidgets('$page is not eligible and the notice is not queued', (
      tester,
    ) async {
      final f = await open(tester, page: page);
      f.add();
      await f.refresh(tester);
      expect(_notice, findsNothing);
      await openNoticeFixturePage(tester, '收件箱');
      expect(_notice, findsNothing);
      expect(f.runtime.conversations.single.unread, 1);
    });
  }

  _windowsTestWidgets(
    'leaving and returning before the sync completes invalidates it',
    (tester) async {
      final f = await open(tester);
      f.add();
      await tester.runAsync(() async {
        final started = Completer<void>();
        final release = Completer<void>();
        f.beforeSyncReply = () async {
          if (!started.isCompleted) started.complete();
          await release.future;
        };
        final work = f.runtime.refreshConversations();
        try {
          await started.future.timeout(const Duration(seconds: 5));
          await tester.tap(find.byTooltip('设置'));
          await tester.pump();
          await tester.tap(find.byTooltip('设置'));
          await tester.pump();
        } finally {
          f.beforeSyncReply = null;
          release.complete();
          await work;
        }
      });
      await tester.pump();
      expect(f.runtime.conversations.single.unread, 1);
      expect(_notice, findsNothing);
      f.add();
      await f.refresh(tester);
      expect(_notice, findsOneWidget);
    },
  );

  _windowsTestWidgets(
    'a modal covers the cue and no notice reappears on return',
    (tester) async {
      final f = await open(tester);
      f.add();
      await f.refresh(tester);
      final context = tester.element(
        find.text(ForegroundNoticeFixture.contactsEmpty),
      );
      final dialog = showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('Synthetic dialog')),
      );
      await tester.pumpAndSettle();
      expect(_notice, findsNothing);
      f.add();
      await f.refresh(tester);
      Navigator.of(context, rootNavigator: true).pop();
      await tester.pumpAndSettle();
      await dialog;
      expect(_notice, findsNothing);
      expect(f.runtime.conversations.single.unread, 2);
    },
  );

  _windowsTestWidgets(
    'inactivity clears the cue and does not replay background arrivals',
    (tester) async {
      final f = await open(tester);
      f.add();
      await f.refresh(tester);
      expect(_notice, findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(_notice, findsNothing);
      f.add();
      await f.refresh(tester);
      expect(_notice, findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(_notice, findsNothing);
      f.add();
      await f.refresh(tester);
      expect(
        _notice,
        findsNothing,
        reason: 'first resume poll is a new baseline',
      );
      f.add();
      await f.refresh(tester);
      expect(_notice, findsOneWidget);
    },
  );

  _windowsTestWidgets(
    'native logout removes the visible cue and forgets the source',
    (tester) async {
      final f = await open(tester);
      f.add();
      await f.refresh(tester);
      expect(_notice, findsOneWidget);
      await sendNoticeFixtureEvent(tester, 'logout');
      expect(f.runtime.authenticated, isFalse);
      expect(_notice, findsNothing);
    },
  );

  _windowsTestWidgets(
    'an app lock suppresses the cue and stops its stale view',
    (tester) async {
      final f = await open(tester);
      await tester.runAsync(() => f.runtime.setAppLock(true, '4321'));
      await tester.pump();
      expect(f.runtime.appLockEnabled, isTrue);
      f.add();
      await f.refresh(tester);
      expect(_notice, findsOneWidget);
      await sendNoticeFixtureEvent(tester, 'lock');
      expect(f.runtime.locked, isTrue);
      expect(_notice, findsNothing);
      f.add();
      await f.refresh(tester);
      expect(
        f.runtime.shell.lastSeqFor(ForegroundNoticeFixture.conversation),
        1,
      );
      expect(f.writes, isEmpty);
    },
  );
}
