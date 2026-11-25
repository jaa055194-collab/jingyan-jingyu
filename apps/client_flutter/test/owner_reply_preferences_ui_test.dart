import 'dart:async';

import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import 'support/owner_reply_preferences_fixture.dart';

const _read = 'owner-reply-preferences-read';
const _state = 'owner-reply-preferences-state';
const _review = 'owner-reply-preferences-review';
const _confirm = 'owner-reply-preferences-confirm';
const _cancel = 'owner-reply-preferences-cancel';
const _save = 'owner-reply-preferences-save';
const _disable = 'owner-reply-preferences-disable';
const _clear = 'owner-reply-preferences-clear';
const _clearConfirm = 'owner-reply-preferences-clear-confirm';

void main() {
  late PreferencesConnection host;
  late PreferencesRuntime runtime;

  setUp(() {
    host = PreferencesConnection();
    runtime = PreferencesRuntime(host);
  });
  tearDown(() async {
    runtime.dispose();
    await host.close();
  });

  testWidgets(
    'default off; only fresh named confirmation authorizes fixed choices',
    (t) async {
      await openPreferencesEditor(t, runtime);
      expect(host.calls, [('POST', preferencesRegister)]);
      expect(preferenceKey(_read), findsOneWidget);
      await tapPreference(t, _read);
      expect(t.widget<Text>(preferenceKey(_state)).data, '未授权自动使用');
      expect(preferenceKey(_confirm), findsNothing);
      expect(host.writes, isEmpty);
      expect(t.widget<FilledButton>(preferenceKey(_review)).onPressed, isNull);
      await tapPreference(t, 'owner-reply-length-brief');
      await tapPreference(t, 'owner-reply-format-bullets');
      await tapPreference(t, _review);
      expect(host.calls, [
        ('POST', preferencesRegister),
        ('GET', preferencesPath(preferencesProfile)),
        ('GET', preferencesPath(preferencesProfile)),
      ]);
      expect(
        find.textContaining('https://provider.example.invalid:8443'),
        findsWidgets,
      );
      expect(find.textContaining('fixture-chat-model'), findsWidgets);
      expect(find.textContaining('fixture-provider'), findsWidgets);
      expect(find.textContaining('fixture-target-A'), findsNothing);
      expect(find.textContaining('后续'), findsWidgets);
      expect(find.textContaining('简短'), findsWidgets);
      expect(find.textContaining('要点'), findsWidgets);
      expect(host.writes, isEmpty);
      await tapPreference(t, _cancel);
      expect(host.writes, isEmpty);
      host.states[preferencesProfile] = preferenceReply(
        target: {
          ...syntheticTarget,
          'origin': 'https://changed.example.invalid',
          'token': 'fixture-target-B',
        },
      );
      await tapPreference(t, _review);
      expect(
        find.textContaining('https://changed.example.invalid'),
        findsWidgets,
      );
      expect(find.textContaining('fixture-target-B'), findsNothing);
      await tapPreference(t, _confirm);
      expect(host.writes, [
        {
          'expectedRevision': 0,
          'enabled': true,
          'length': 'brief',
          'format': 'bullets',
          'expectedTargetToken': 'fixture-target-B',
        },
      ]);
      expect(t.widget<Text>(preferenceKey(_state)).data, '已授权自动使用');
    },
  );

  testWidgets(
    'saved off choices stay off; revoke retains choices; clear removes both',
    (t) async {
      await openPreferencesEditor(t, runtime);
      await tapPreference(t, _read);
      await tapPreference(t, 'owner-reply-length-detailed');
      await tapPreference(t, _save);
      expect(host.writes.single, {
        'expectedRevision': 0,
        'enabled': false,
        'length': 'detailed',
        'format': null,
        'expectedTargetToken': null,
      });
      expect(t.widget<Text>(preferenceKey(_state)).data, '未授权自动使用');
      await tapPreference(t, _review);
      await tapPreference(t, _confirm);
      await tapPreference(
        t,
        'owner-reply-format-paragraphs',
      ); // Unsaved draft is not part of revocation.
      expect(find.text('当前选择尚未保存。'), findsOneWidget);
      expect(find.text('已保存：详细 · 不指定'), findsOneWidget);
      await tapPreference(t, _disable);
      expect(host.writes.last, {
        'expectedRevision': 2,
        'enabled': false,
        'length': 'detailed',
        'format': null,
        'expectedTargetToken': null,
      });
      expect(t.widget<Text>(preferenceKey(_state)).data, '未授权自动使用');
      host.states[preferencesProfile] = preferenceReply(
        revision: 3,
        length: 'detailed',
        target: null,
      );
      await tapPreference(t, _read);
      await tapPreference(t, _clear);
      expect(
        host.writes.length,
        3,
        reason: 'clear requires explicit confirmation',
      );
      await tapPreference(t, _clearConfirm);
      expect(host.writes.last, {
        'expectedRevision': 3,
        'enabled': false,
        'length': null,
        'format': null,
        'expectedTargetToken': null,
      });
      expect(host.writes.length, 4);
    },
  );

  testWidgets(
    'missing target cannot enable and does not prevent saving off choices',
    (t) async {
      await openPreferencesEditor(t, runtime);
      await choosePreferencesAi(t, 'ai-b');
      await tapPreference(t, _read);
      await tapPreference(t, 'owner-reply-format-paragraphs');
      expect(t.widget<FilledButton>(preferenceKey(_review)).onPressed, isNull);
      expect(
        preferenceKey('owner-reply-preferences-no-target'),
        findsOneWidget,
      );
      expect(host.writes, isEmpty);
      await tapPreference(t, _save);
      expect(host.calls.last, (
        'PUT',
        preferencesPath(otherPreferencesProfile),
      ));
      expect(host.writes.single['enabled'], false);
    },
  );

  testWidgets(
    'conflict retires approval and requires re-read and a new confirmation',
    (t) async {
      await openPreferencesEditor(t, runtime);
      await tapPreference(t, _read);
      await tapPreference(t, 'owner-reply-length-brief');
      await tapPreference(t, _review);
      host.write = (profile, body) async => throw const HostRequestException(
        Failure(FailureCode.conflict, 'secret upstream payload'),
      );
      await tapPreference(t, _confirm);
      expect(preferenceKey('owner-reply-preferences-conflict'), findsOneWidget);
      expect(preferenceKey(_confirm), findsNothing);
      expect(preferenceKey(_state), findsNothing);
      expect(find.textContaining('secret upstream payload'), findsNothing);
      expect(host.writes.length, 1);
      expect(host.calls.where((c) => c.$1 == 'GET').length, 2);
      host.write = null;
      host.states[preferencesProfile] = preferenceReply(
        revision: 1,
        format: 'paragraphs',
      );
      await tapPreference(t, _read);
      await tapPreference(t, _review);
      expect(host.writes.length, 1);
      await tapPreference(t, _confirm);
      expect(host.writes.last, {
        'expectedRevision': 1,
        'enabled': true,
        'length': null,
        'format': 'paragraphs',
        'expectedTargetToken': 'fixture-target-A',
      });
    },
  );

  testWidgets(
    'timeout discards the old receipt and does not repeat or report success',
    (t) async {
      await openPreferencesEditor(t, runtime);
      await tapPreference(t, _read);
      await tapPreference(t, 'owner-reply-format-bullets');
      await tapPreference(t, _review);
      host.write = (profile, body) async {
        host.applyWrite(profile, body); // Network drops after the mutation.
        throw TimeoutException('opaque test timeout');
      };
      await tapPreference(t, _confirm);
      expect(preferenceKey('owner-reply-preferences-unknown'), findsOneWidget);
      expect(preferenceKey('owner-reply-preferences-saved'), findsNothing);
      expect(preferenceKey(_state), findsNothing);
      expect(host.writes.length, 1);
      host.read = (_) async =>
          throw const FormatException('opaque malformed response');
      await tapPreference(t, _read);
      expect(
        preferenceKey('owner-reply-preferences-unknown'),
        findsOneWidget,
        reason: 'failed refresh cannot resolve uncertainty',
      );
      expect(
        preferenceKey('owner-reply-preferences-unavailable'),
        findsOneWidget,
      );
      host.read = null;
      await tapPreference(t, _read);
      expect(t.widget<Text>(preferenceKey(_state)).data, '已授权自动使用');
      expect(preferenceKey('owner-reply-preferences-saved'), findsNothing);
      expect(host.writes.length, 1);
    },
  );

  testWidgets(
    'AI switch drops a delayed profile reply and invalidates retained confirmation',
    (t) async {
      await openPreferencesEditor(t, runtime);
      final oldRead = Completer<Map<String, Object?>>();
      host.read = (profile) => profile == preferencesProfile
          ? oldRead.future
          : Future.value(host.states[profile]);
      await tapPreference(t, _read, settle: false);
      await choosePreferencesAi(t, 'ai-b');
      oldRead.complete(
        preferenceReply(revision: 3, enabled: true, length: 'brief'),
      );
      await t.pumpAndSettle();
      expect(find.text('档案：profile-b'), findsOneWidget);
      expect(preferenceKey(_state), findsNothing);
      await tapPreference(t, _read);
      expect(t.widget<Text>(preferenceKey(_state)).data, '未授权自动使用');
      await choosePreferencesAi(t, 'ai-a');
      host.read = null;
      await tapPreference(t, _read);
      await tapPreference(t, 'owner-reply-length-brief');
      t
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await t.pump();
      final choose = t
          .widget<DropdownButton<String>>(
            preferenceKey('ai-config-write-select'),
          )
          .onChanged!;
      await tapPreference(t, _review);
      final stale = t.widget<FilledButton>(preferenceKey(_confirm)).onPressed!;
      choose('ai-b');
      stale();
      await t.pumpAndSettle();
      expect(host.writes, isEmpty);
      expect(preferenceKey(_confirm), findsNothing);
    },
  );

  testWidgets('a late committed receipt cannot publish in a replaced editor', (
    t,
  ) async {
    await openPreferencesEditor(t, runtime);
    await tapPreference(t, _read);
    await tapPreference(t, 'owner-reply-length-brief');
    await tapPreference(t, _review);
    final pending = Completer<Map<String, Object?>>();
    host.write = (_, _) => pending.future;
    await tapPreference(t, _confirm, settle: false);
    expect(host.writes, hasLength(1));
    runtime.changeView(replaceSession: true);
    await t.pumpAndSettle();
    pending.complete(
      preferenceReply(revision: 1, enabled: true, length: 'brief'),
    );
    await t.pumpAndSettle();
    expect(preferenceKey(_state), findsNothing);
    expect(preferenceKey('owner-reply-preferences-saved'), findsNothing);
    expect(find.textContaining('fixture-provider'), findsNothing);
    expect(host.writes, hasLength(1));
  });

  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('review disclosure and confirm fit at $width logical pixels', (
      t,
    ) async {
      t.view.physicalSize = Size(width, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await openPreferencesEditor(t, runtime);
      await tapPreference(t, _read);
      await tapPreference(t, 'owner-reply-length-brief');
      await tapPreference(t, _review);
      expect(preferenceKey(_confirm).hitTestable(), findsOneWidget);
      expect(
        find.textContaining('fixture-chat-model').hitTestable(),
        findsOneWidget,
      );
      expect(
        find
            .textContaining('https://provider.example.invalid:8443')
            .hitTestable(),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
      expect(host.writes, isEmpty);
    });
  }

  for (final lock in [true, false]) {
    testWidgets(
      'old confirmation refuses ${lock ? 'lock and unlock' : 'same-owner session change'} before another frame',
      (t) async {
        await openPreferencesEditor(t, runtime);
        await tapPreference(t, _read);
        await tapPreference(t, 'owner-reply-length-brief');
        await tapPreference(t, _review);
        final stale = t
            .widget<FilledButton>(preferenceKey(_confirm))
            .onPressed!;
        if (lock) {
          runtime.changeView(lock: true);
          runtime.changeView(lock: false);
        } else {
          runtime.changeView(replaceSession: true);
        }
        stale();
        await t.pumpAndSettle();
        expect(host.writes, isEmpty);
        expect(preferenceKey(_confirm), findsNothing);
        expect(
          find.textContaining('https://provider.example.invalid'),
          findsNothing,
        );
      },
    );
  }
}
