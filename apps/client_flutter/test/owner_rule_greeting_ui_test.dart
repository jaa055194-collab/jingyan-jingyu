import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/owner_rule_greeting_fixture.dart';

void main() {
  late GreetingConnection host;
  late GreetingRuntime runtime;
  setUp(() {
    host = GreetingConnection();
    runtime = GreetingRuntime(host);
  });
  tearDown(() async {
    runtime.dispose();
    await host.close();
  });
  const read = 'owner-rule-greeting-read';
  const review = 'owner-rule-greeting-review';
  const confirm = 'owner-rule-greeting-confirm';
  const disable = 'owner-rule-greeting-disable';
  const offset = 'owner-rule-greeting-offset';
  const daily = 'owner-rule-greeting-local';
  const start = 'owner-rule-greeting-quiet-start';
  const end = 'owner-rule-greeting-quiet-end';

  Future<void> open(WidgetTester t) async {
    await openGreetingSettings(t, runtime);
    await openGreetingEditor(t);
    await revealGreetingCard(t);
    expect(host.calls, [('POST', greetingRegister)]);
    await tapGreeting(t, read);
  }

  testWidgets(
    'per-AI opt-in requires review and explicit confirmation of fixed schedule',
    (t) async {
      await openGreetingSettings(t, runtime);
      await openGreetingEditor(t);
      expect(greetingKey(read), findsOneWidget);
      await revealGreetingCard(t);
      expect(host.calls, [('POST', greetingRegister)]);
      await tapGreeting(t, read);
      expect(find.text('未授权规则问候'), findsOneWidget);
      expect(
        t.widget<TextField>(greetingKey(offset)).controller!.text,
        isEmpty,
      );
      await enterGreeting(t, daily, '01:30');
      await enterGreeting(t, offset, '+08:00');
      await tapGreeting(t, review);
      expect(find.textContaining('问候示例 A'), findsWidgets);
      expect(find.textContaining('UTC+08:00'), findsOneWidget);
      expect(find.textContaining('延至静默结束'), findsOneWidget);
      expect(host.calls, [
        ('POST', greetingRegister),
        ('GET', greetingPath(greetingProfileA)),
        ('GET', greetingPath(greetingProfileA)),
      ]);
      expect(host.writes, isEmpty);
      await tapGreeting(t, 'owner-rule-greeting-cancel');
      expect(host.writes, isEmpty);
      await tapGreeting(t, review);
      await tapGreeting(t, confirm);
      expect(host.writes.single.$1, greetingPath(greetingProfileA));
      expect(host.writes.single.$2, {
        'expectedRevision': 0,
        'enabled': true,
        'localMinute': 90,
        'offsetMinutes': 480,
        'quietStartMinute': 1380,
        'quietEndMinute': 480,
        'expectedChatRevision': 1,
        'expectedGlobalRevision': 0,
      });
      expect(find.text('已授权规则问候'), findsOneWidget);
      expect(find.textContaining('不保证发送'), findsWidgets);
    },
  );

  testWidgets(
    'revocation ignores unsaved form and budget outage and retains saved schedule',
    (t) async {
      host.settings[greetingProfileA] = greetingJson(
        revision: 3,
        enabled: true,
        localMinute: 615,
        offsetMinutes: -330,
        quietStartMinute: 1350,
        quietEndMinute: 420,
        budgetReady: false,
      );
      await open(t);
      expect(find.text('已授权规则问候'), findsOneWidget);
      expect(t.widget<FilledButton>(greetingKey(review)).onPressed, isNull);
      await enterGreeting(t, daily, '15:20');
      await tapGreeting(t, disable);
      expect(host.writes.single.$2, {
        'expectedRevision': 3,
        'enabled': false,
        'localMinute': 615,
        'offsetMinutes': -330,
        'quietStartMinute': 1350,
        'quietEndMinute': 420,
        'expectedChatRevision': null,
        'expectedGlobalRevision': null,
      });
      expect(find.text('未授权规则问候'), findsOneWidget);
      expect(t.widget<TextField>(greetingKey(daily)).controller!.text, '10:15');
      expect(
        t.widget<TextField>(greetingKey(offset)).controller!.text,
        '-05:30',
      );
    },
  );

  testWidgets(
    'invalid fixed offset and identical quiet endpoints cannot open review',
    (t) async {
      await open(t);
      await enterGreeting(t, offset, 'PST');
      expect(t.widget<FilledButton>(greetingKey(review)).onPressed, isNull);
      await enterGreeting(t, offset, '+14:01');
      expect(t.widget<FilledButton>(greetingKey(review)).onPressed, isNull);
      await enterGreeting(t, offset, '-14:00');
      await enterGreeting(t, start, '10:30');
      await enterGreeting(t, end, '10:30');
      expect(t.widget<FilledButton>(greetingKey(review)).onPressed, isNull);
      expect(greetingKey(confirm), findsNothing);
      expect(host.writes, isEmpty);
    },
  );

  for (final (name, settings, blocked) in [
    ('global stop', greetingJson(offsetMinutes: 0), true),
    ('missing pair', greetingJson(offsetMinutes: 0, chatRevision: null), false),
    ('L2', greetingJson(offsetMinutes: 0, socialLevel: 'L2'), false),
    ('budget', greetingJson(offsetMinutes: 0, budgetReady: false), false),
  ]) {
    testWidgets('$name withholds enable review', (t) async {
      host.settings[greetingProfileA] = settings;
      host.global = {'revision': 2, 'blocked': blocked};
      await open(t);
      expect(t.widget<FilledButton>(greetingKey(review)).onPressed, isNull);
      expect(greetingKey(confirm), findsNothing);
      expect(host.writes, isEmpty);
    });
  }

  testWidgets(
    'fresh enable read suppresses review if the pair revision changed',
    (t) async {
      await open(t);
      await enterGreeting(t, offset, '+00:00');
      host.settings[greetingProfileA]!['chatRevision'] = 2;
      await tapGreeting(t, review);
      expect(greetingKey(confirm), findsNothing);
      expect(greetingKey('owner-rule-greeting-conflict'), findsOneWidget);
      expect(host.writes, isEmpty);
    },
  );

  testWidgets(
    'commit conflict discards old confirmation, with no automatic replay',
    (t) async {
      await open(t);
      await enterGreeting(t, offset, '+00:00');
      await tapGreeting(t, review);
      host.global = {'revision': 3, 'blocked': true};
      await tapGreeting(t, confirm);
      expect(host.writes, hasLength(1));
      expect(greetingKey('owner-rule-greeting-conflict'), findsOneWidget);
      expect(greetingKey(confirm), findsNothing);
      expect(greetingKey('owner-rule-greeting-state'), findsNothing);
      await tapGreeting(t, read);
      expect(t.widget<FilledButton>(greetingKey(review)).onPressed, isNull);
      expect(host.writes, hasLength(1));
    },
  );

  testWidgets('switching AI retires prior approval before the next frame', (
    t,
  ) async {
    await open(t);
    await enterGreeting(t, offset, '+00:00');
    await tapGreeting(t, review);
    final old = t.widget<FilledButton>(greetingKey(confirm)).onPressed!;
    t.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
    await t.pump();
    final change = t
        .widget<DropdownButton<String>>(greetingKey('ai-config-write-select'))
        .onChanged!;
    change(greetingAiB);
    old();
    await t.pumpAndSettle();
    expect(find.text('档案：profile-b'), findsOneWidget);
    await revealGreetingCard(t);
    await tapGreeting(t, read);
    expect(t.widget<FilledButton>(greetingKey(review)).onPressed, isNull);
    expect(host.writes, isEmpty);
  });

  testWidgets('lock and unlock retire a pending AI read', (t) async {
    final pending = Completer<Map<String, Object?>>();
    host.beforeSettingsRead = (_) => pending.future;
    await openGreetingSettings(t, runtime);
    await openGreetingEditor(t);
    await revealGreetingCard(t);
    await tapGreeting(t, read, settle: false);
    expect(host.calls.last, ('GET', greetingPath(greetingProfileA)));
    runtime.changeSession(lock: true);
    runtime.changeSession(lock: false);
    pending.complete(greetingJson(enabled: true, offsetMinutes: 0));
    await t.pumpAndSettle();
    expect(greetingKey('ai-config-session-invalid'), findsOneWidget);
    expect(greetingKey('owner-rule-greeting-state'), findsNothing);
    expect(host.writes, isEmpty);
  });

  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('schedule and review fit at $width logical pixels', (t) async {
      t.view.physicalSize = Size(width, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await open(t);
      await enterGreeting(t, offset, '+08:00');
      await tapGreeting(t, review);
      expect(greetingKey(confirm).hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      expect(host.writes, isEmpty);
    });
  }
}
