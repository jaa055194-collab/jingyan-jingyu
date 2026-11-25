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

  final stop = greetingKey('owner-rule-greeting-global-stop');
  final confirm = greetingKey('owner-rule-greeting-global-confirm');

  testWidgets('Settings offers account stop even with no AI accounts', (
    t,
  ) async {
    runtime.ais.clear();
    await openGreetingSettings(t, runtime);
    expect(greetingKey('open-owner-rule-greeting-global'), findsOneWidget);
    expect(host.calls, isEmpty);
    await openGreetingGlobal(t);
    expect(t.widget<SwitchListTile>(stop).value, isFalse);
    expect(host.calls, [('GET', greetingGlobalPath)]);
    await tapGreeting(t, 'owner-rule-greeting-global-stop');
    expect(host.writes, isEmpty);
    await tapGreeting(t, 'owner-rule-greeting-global-cancel');
    expect(host.writes, isEmpty);
    await tapGreeting(t, 'owner-rule-greeting-global-stop');
    await tapGreeting(t, 'owner-rule-greeting-global-confirm');
    expect(host.writes, hasLength(1));
    expect(host.writes.single.$1, greetingGlobalPath);
    expect(host.writes.single.$2, {'expectedRevision': 0, 'blocked': true});
    expect(t.widget<SwitchListTile>(stop).value, isTrue);
  });

  testWidgets('global unblock never restores an earlier per-AI grant', (
    t,
  ) async {
    host.settings[greetingProfileA] = greetingJson(
      revision: 5,
      enabled: true,
      offsetMinutes: 480,
    );
    await openGreetingSettings(t, runtime);
    await openGreetingGlobal(t);
    await tapGreeting(t, 'owner-rule-greeting-global-stop');
    await tapGreeting(t, 'owner-rule-greeting-global-confirm');
    await tapGreeting(t, 'owner-rule-greeting-global-stop');
    await tapGreeting(t, 'owner-rule-greeting-global-confirm');
    expect(host.writes.map((w) => w.$1), [
      greetingGlobalPath,
      greetingGlobalPath,
    ]);
    expect(host.writes.map((w) => w.$2), [
      {'expectedRevision': 0, 'blocked': true},
      {'expectedRevision': 1, 'blocked': false},
    ]);
    expect(t.widget<SwitchListTile>(stop).value, isFalse);
    await t.pageBack();
    await t.pumpAndSettle();
    await openGreetingEditor(t);
    await revealGreetingCard(t);
    await tapGreeting(t, 'owner-rule-greeting-read');
    expect(find.text('未授权规则问候'), findsOneWidget);
    expect(
      t
          .widget<TextField>(greetingKey('owner-rule-greeting-offset'))
          .controller!
          .text,
      '+08:00',
    );
    expect(host.writes, hasLength(2));
  });

  testWidgets('ambiguous account stop result hides the switch without replay', (
    t,
  ) async {
    host.beforeGlobalWrite = (_) async => throw StateError('opaque details');
    await openGreetingSettings(t, runtime);
    await openGreetingGlobal(t);
    await tapGreeting(t, 'owner-rule-greeting-global-stop');
    await tapGreeting(t, 'owner-rule-greeting-global-confirm');
    expect(stop, findsNothing);
    expect(greetingKey('owner-rule-greeting-global-unknown'), findsOneWidget);
    expect(find.textContaining('opaque'), findsNothing);
    host.beforeGlobalRead = () async => throw StateError('opaque read');
    await tapGreeting(t, 'owner-rule-greeting-global-read');
    expect(stop, findsNothing);
    expect(greetingKey('owner-rule-greeting-global-unknown'), findsOneWidget);
    host.beforeGlobalRead = null;
    await tapGreeting(t, 'owner-rule-greeting-global-read');
    expect(stop, findsOneWidget);
    expect(greetingKey('owner-rule-greeting-global-unknown'), findsNothing);
    expect(host.writes, hasLength(1));
  });

  testWidgets('old stop confirmation is rejected after same-owner relogin', (
    t,
  ) async {
    await openGreetingSettings(t, runtime);
    await openGreetingGlobal(t);
    await tapGreeting(t, 'owner-rule-greeting-global-stop');
    final old = t.widget<FilledButton>(confirm).onPressed!;
    runtime.changeSession(replaceSession: true);
    old();
    await t.pumpAndSettle();
    expect(confirm, findsNothing);
    expect(stop, findsNothing);
    expect(host.writes, isEmpty);
  });

  testWidgets('late stop read cannot expose previous state after locking', (
    t,
  ) async {
    final pending = Completer<Map<String, Object?>>();
    host.beforeGlobalRead = () => pending.future;
    await openGreetingSettings(t, runtime);
    final open = greetingKey('open-owner-rule-greeting-global');
    await t.ensureVisible(open);
    await t.tap(open);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(host.calls, [('GET', greetingGlobalPath)]);
    runtime.changeSession(lock: true);
    runtime.changeSession(lock: false);
    pending.complete({'revision': 7, 'blocked': true});
    await t.pumpAndSettle();
    expect(stop, findsNothing);
    expect(host.writes, isEmpty);
  });
}
