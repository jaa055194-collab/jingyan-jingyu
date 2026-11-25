import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/scheduled_messages_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late ScheduledMessagesFixture fixture;
  late ClientRuntime runtime;
  setUp(() async {
    fixture = await ScheduledMessagesFixture.create();
    runtime = await fixture.open();
  });
  tearDown(() async {
    runtime.dispose();
    await fixture.cleanup();
  });
  const open = 'open-scheduled-messages';
  const compose = 'schedule-compose';
  const review = 'schedule-review';
  const confirm = 'schedule-confirm';
  const refresh = 'schedule-refresh';

  Future<void> chat(WidgetTester t, {double width = 390}) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    t.view.physicalSize = Size(width, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await showScheduleChat(t, runtime);
  }

  Future<void> reviewCreate(WidgetTester t) async {
    await tapScheduleAndWait(t, open, compose);
    await tapSchedule(t, compose);
    expect(
      t.widget<TextField>(scheduleKey('schedule-text')).controller!.text,
      isEmpty,
    );
    await enterScheduleFields(t);
    await tapSchedule(t, review);
    expect(scheduleKey(confirm).hitTestable(), findsOneWidget);
    expect(fixture.hasMutations, isFalse);
  }

  testWidgets(
    'only explicit confirmation creates a plain text schedule and preserves the draft',
    (t) async {
      await chat(t);
      expect(scheduleKey(open).hitTestable(), findsOneWidget);
      expect(fixture.calls, isEmpty);
      await reviewCreate(t);
      expect(find.textContaining('周末野餐'), findsWidgets);
      expect(find.textContaining('2090-06-15 09:32'), findsOneWidget);
      expect(
        find.textContaining(scheduledInstant.toIso8601String()),
        findsOneWidget,
      );
      expect(find.text(scheduleText), findsOneWidget);
      await tapScheduleAndWait(t, confirm, 'schedule-created');
      expect(fixture.calls.map((call) => (call.$1, call.$2)), [
        ('GET', schedulePath),
        ('POST', schedulePath),
      ]);
      expect(jsonDecode(fixture.calls.last.$3), {
        'kind': 'text',
        'body': {'text': scheduleText},
        'deliverAt': scheduledInstant.toIso8601String(),
      });
      expect(scheduleKey('schedule-row-$scheduleId'), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      expect(
        t.widget<TextField>(scheduleKey('composer')).controller!.text,
        scheduleDraft,
      );
      expect(runtime.draftFor(pinsChat), scheduleDraft);
      expect(runtime.queuedCount, 0);
      expect(find.text(scheduleText), findsNothing);
    },
  );

  testWidgets(
    'invalid normalized dates and past times never reach confirmation',
    (t) async {
      await chat(t);
      await tapScheduleAndWait(t, open, compose);
      await tapSchedule(t, compose);
      for (final (date, time) in [
        ('2090-02-30', '09:32'),
        ('2001-12-02', '12:00'),
        (scheduleDate, '24:32'),
      ]) {
        await enterScheduleFields(t, date: date, time: time);
        expect(t.widget<FilledButton>(scheduleKey(review)).onPressed, isNull);
        expect(scheduleKey(confirm), findsNothing);
      }
      expect(fixture.hasMutations, isFalse);
      await t.pageBack();
      await t.pumpAndSettle();
      expect(runtime.draft, scheduleDraft);
    },
  );

  testWidgets(
    'a missing status endpoint does not offer writes on an old host',
    (t) async {
      fixture.refuseList = true;
      await chat(t);
      await tapScheduleAndWait(t, open, 'schedule-read-unavailable');
      expect(scheduleKey(compose), findsNothing);
      expect(fixture.calls, [('GET', schedulePath, '')]);
    },
  );

  testWidgets(
    'an unknown create cannot be confirmed by an uncorrelated list refresh',
    (t) async {
      fixture.loseCreateReceipt = true;
      await chat(t);
      await reviewCreate(t);
      await tapScheduleAndWait(t, confirm, 'schedule-create-unknown');
      expect(scheduleKey('schedule-created'), findsNothing);
      await tapScheduleAndWait(
        t,
        'schedule-list-refresh',
        'schedule-row-$scheduleId',
      );
      expect(scheduleKey('schedule-create-unknown'), findsOneWidget);
      expect(scheduleKey('schedule-created'), findsNothing);
      expect(scheduleKey(compose), findsNothing);
      expect(fixture.calls.map((call) => (call.$1, call.$2)), [
        ('GET', schedulePath),
        ('POST', schedulePath),
        ('GET', schedulePath),
      ]);
      expect(runtime.draft, scheduleDraft);
    },
  );

  testWidgets(
    'only a pending known ID can be cancelled after explicit confirmation',
    (t) async {
      fixture.seed('job-done', 'delivered');
      fixture.seed('job-expired', 'expired');
      fixture.seed(scheduleId, 'pending');
      await chat(t);
      await tapScheduleAndWait(t, open, compose);
      expect(scheduleKey('schedule-status-legend'), findsOneWidget);
      expect(find.textContaining('已取消/未发送'), findsWidgets);
      expect(scheduleKey('schedule-cancel-job-done'), findsNothing);
      expect(scheduleKey('schedule-cancel-job-expired'), findsNothing);
      await tapSchedule(t, 'schedule-cancel-$scheduleId');
      expect(fixture.hasMutations, isFalse);
      await tapSchedule(t, 'schedule-cancel-dismiss');
      expect(fixture.hasMutations, isFalse);
      await tapSchedule(t, 'schedule-cancel-$scheduleId');
      await tapScheduleAndWait(
        t,
        'schedule-confirm-cancel',
        'schedule-cancelled',
      );
      expect(fixture.calls, [
        ('GET', schedulePath, ''),
        ('DELETE', '$schedulePath/$scheduleId', ''),
      ]);
      expect(scheduleKey('schedule-cancel-$scheduleId'), findsNothing);
      expect(runtime.draft, scheduleDraft);
    },
  );

  testWidgets(
    'an ambiguous cancel queries the exact known ID and 404 proves nothing',
    (t) async {
      fixture.seed(scheduleId, 'pending');
      fixture.loseCancelReceipt = true;
      await chat(t);
      await tapScheduleAndWait(t, open, compose);
      await tapSchedule(t, 'schedule-cancel-$scheduleId');
      await tapScheduleAndWait(
        t,
        'schedule-confirm-cancel',
        'schedule-cancel-unknown',
      );
      fixture.hideKnown = true;
      await tapScheduleAndWait(t, refresh, 'schedule-read-unavailable');
      expect(scheduleKey('schedule-cancel-unknown'), findsOneWidget);
      expect(scheduleKey('schedule-cancelled'), findsNothing);
      fixture.hideKnown = false;
      await tapScheduleAndWait(t, refresh, 'schedule-row-$scheduleId');
      expect(scheduleKey('schedule-loading'), findsNothing);
      expect(scheduleKey('schedule-cancel-unknown'), findsNothing);
      expect(
        scheduleKey('schedule-cancelled'),
        findsNothing,
        reason: 'readback confirms status, not the original DELETE',
      );
      expect(fixture.calls, [
        ('GET', schedulePath, ''),
        ('DELETE', '$schedulePath/$scheduleId', ''),
        ('GET', '$schedulePath?scheduledId=$scheduleId', ''),
        ('GET', '$schedulePath?scheduledId=$scheduleId', ''),
      ]);
    },
  );

  testWidgets('switch away and back retires old confirmation before frame', (
    t,
  ) async {
    await chat(t);
    await reviewCreate(t);
    final old = t.widget<FilledButton>(scheduleKey(confirm)).onPressed!;
    await runtime.selectConversation(otherChat);
    await runtime.selectConversation(pinsChat);
    old();
    await t.pumpAndSettle();
    expect(scheduleKey('schedule-retired'), findsOneWidget);
    expect(find.text(scheduleText), findsNothing);
    expect(fixture.hasMutations, isFalse);
  });

  testWidgets('direct and offline conversations cannot enter schedule flow', (
    t,
  ) async {
    await chat(t);
    await runtime.selectConversation(scheduleDirect);
    await t.pumpAndSettle();
    expect(
      runtime.conversations.singleWhere((row) => row.id == scheduleDirect).kind,
      'direct',
    );
    expect(scheduleKey(open), findsNothing);
    await runtime.selectConversation(pinsChat);
    fixture.chat.hostInfoStatus = 503;
    await t.runAsync(runtime.refreshConversations);
    await t.pumpAndSettle();
    expect(runtime.online, isFalse);
    expect(scheduleKey(open), findsNothing);
    expect(fixture.calls, isEmpty);
  });

  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('schedule review fits $width logical pixels', (t) async {
      await chat(t, width: width);
      await reviewCreate(t);
      expect(t.takeException(), isNull);
    });
  }
}
