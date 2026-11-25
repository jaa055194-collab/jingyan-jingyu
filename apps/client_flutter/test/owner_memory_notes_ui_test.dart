import 'dart:convert';

import 'package:client_flutter/features/ai_config/ai_config_problem_line.dart';
import 'package:client_flutter/features/ai_config/owner_memory_notes_section.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/owner_memory_notes_fixture.dart';
import 'support/owner_reply_preferences_fixture.dart';

void _expectProblemIcon(Finder text) {
  final line = find.ancestor(
    of: text,
    matching: find.byType(AiConfigProblemLine, skipOffstage: false),
  );
  expect(
    find.descendant(
      of: line,
      matching: find.byIcon(Icons.error_outline, skipOffstage: false),
      skipOffstage: false,
    ),
    findsOneWidget,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryNotesConnection connection;
  late PreferencesRuntime runtime;
  setUp(() {
    connection = MemoryNotesConnection();
    runtime = PreferencesRuntime(connection);
  });
  tearDown(() async {
    runtime.dispose();
    await connection.close();
  });

  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await openMemoryEditor(t, runtime);
  }

  Future<void> tap(WidgetTester t, String key) async {
    final found = memoryKey(key);
    expect(found, findsOneWidget, reason: key);
    t.testTextInput.hide();
    await t.ensureVisible(found);
    await t.pump();
    if (found.hitTestable().evaluate().isEmpty) {
      await t.scrollUntilVisible(
        found,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await t.pumpAndSettle();
    }
    expect(found.hitTestable(), findsOneWidget, reason: key);
    await t.tap(found);
    await t.pumpAndSettle();
  }

  Future<void> read(WidgetTester t) => tap(t, 'memory-notes-read');

  Finder memorySwitch() =>
      find.byKey(const Key('memory-notes-enabled'), skipOffstage: false);

  testWidgets('memory notes stay unloaded until explicit read', (t) async {
    await open(t);
    expect(
      find.descendant(
        of: find.byType(OwnerMemoryNotesSection),
        matching: find.text('尚未读取宿主状态。'),
      ),
      findsOneWidget,
    );
    expect(connection.memoryCalls, isEmpty);
    await read(t);
    expect(find.text('未授权使用（默认关闭）。便签可先保存，授权需单独确认。'), findsOneWidget);
    expect(connection.memoryCalls.single.$1, 'GET');
  });

  testWidgets('add edit delete clear are explicit and CAS-backed', (t) async {
    await open(t);
    await read(t);
    await tap(t, 'memory-notes-add');
    await t.enterText(memoryKey('memory-notes-add-text'), '  喜欢桂花  ');
    await tap(t, 'memory-notes-add-save');
    expect(memoryKey('memory-notes-note-note-1'), findsOneWidget);
    expect(find.text('喜欢桂花'), findsOneWidget);
    expect(jsonDecode(connection.memoryCalls.last.$3), {
      'text': '喜欢桂花',
      'expectedRevision': 0,
    });

    await tap(t, 'memory-notes-edit-note-1');
    await t.enterText(memoryKey('memory-notes-edit-text'), '喜欢白色');
    await tap(t, 'memory-notes-edit-save');
    expect(find.text('喜欢白色'), findsOneWidget);
    expect(jsonDecode(connection.memoryCalls.last.$3), {
      'text': '喜欢白色',
      'expectedRevision': 1,
    });

    await tap(t, 'memory-notes-delete-note-1');
    expect(memoryKey('memory-notes-delete-dialog'), findsOneWidget);
    await tap(t, 'memory-notes-delete-cancel');
    expect(memoryKey('memory-notes-note-note-1'), findsOneWidget);
    await tap(t, 'memory-notes-delete-note-1');
    await tap(t, 'memory-notes-delete-confirm');
    expect(memoryKey('memory-notes-note-note-1'), findsNothing);
    expect(jsonDecode(connection.memoryCalls.last.$3), {'expectedRevision': 2});
  });

  testWidgets('clear keeps permission and only deletes confirmed notes', (
    t,
  ) async {
    connection.memory[memoryProfileA] = memoryState(
      revision: 2,
      enabled: true,
      target: memoryTarget,
      notes: [
        memoryNote(),
        memoryNote(id: 'note-b', text: '第二句'),
      ],
    );
    await open(t);
    await read(t);
    expect(t.widget<SwitchListTile>(memorySwitch()).value, isTrue);
    await tap(t, 'memory-notes-clear');
    expect(memoryKey('memory-notes-clear-dialog'), findsOneWidget);
    await tap(t, 'memory-notes-clear-cancel');
    expect(memoryKey('memory-notes-note-note-a'), findsOneWidget);
    await tap(t, 'memory-notes-clear');
    await tap(t, 'memory-notes-clear-confirm');
    expect(connection.memory[memoryProfileA]!['notes'], isEmpty);
    expect(connection.memoryCalls.last.$1, 'DELETE');
    expect(find.text('还没有便签。', skipOffstage: false), findsOneWidget);
    expect(t.widget<SwitchListTile>(memorySwitch()).value, isTrue);
    expect(jsonDecode(connection.memoryCalls.last.$3), {'expectedRevision': 2});
  });

  testWidgets(
    'permission requires fresh target review and revoke retains notes',
    (t) async {
      connection.memory[memoryProfileA] = memoryState(
        revision: 0,
        enabled: false,
        target: memoryTarget,
        notes: [memoryNote()],
      );
      await open(t);
      await read(t);
      await tap(t, 'memory-notes-enabled');
      expect(memoryKey('memory-notes-enable-dialog'), findsOneWidget);
      expect(find.textContaining('仅当前本人 AI 私聊'), findsOneWidget);
      expect(find.textContaining('不是聊天历史'), findsOneWidget);
      expect(find.textContaining('fixture-memory-model'), findsOneWidget);
      expect(find.textContaining('memory-target-A'), findsNothing);
      await tap(t, 'memory-notes-enable-cancel');
      expect(connection.memoryCalls.where((call) => call.$1 == 'PUT'), isEmpty);
      await tap(t, 'memory-notes-enabled');
      await tap(t, 'memory-notes-enable-confirm');
      expect(t.widget<SwitchListTile>(memorySwitch()).value, isTrue);
      expect(jsonDecode(connection.memoryCalls.last.$3), {
        'expectedRevision': 0,
        'enabled': true,
        'expectedTargetToken': 'memory-target-A',
      });
      await tap(t, 'memory-notes-enabled');
      expect(memoryKey('memory-notes-disable-dialog'), findsOneWidget);
      await tap(t, 'memory-notes-disable-confirm');
      expect(t.widget<SwitchListTile>(memorySwitch()).value, isFalse);
      expect(find.text('喜欢桂花'), findsOneWidget);
      expect(jsonDecode(connection.memoryCalls.last.$3), {
        'expectedRevision': 1,
        'enabled': false,
        'expectedTargetToken': null,
      });
    },
  );

  testWidgets('missing target disables enable but notes remain editable', (
    t,
  ) async {
    await open(t);
    await read(t);
    expect(find.textContaining('当前没有可用的本人私聊接收条件'), findsOneWidget);
    expect(t.widget<SwitchListTile>(memorySwitch()).onChanged, isNull);
    await tap(t, 'memory-notes-add');
    await t.enterText(memoryKey('memory-notes-add-text'), '第一条');
    await tap(t, 'memory-notes-add-save');
    expect(memoryKey('memory-notes-note-note-1'), findsOneWidget);
  });

  testWidgets('stale revision and changed target retire the pending action', (
    t,
  ) async {
    connection.memory[memoryProfileA] = memoryState(
      revision: 0,
      target: memoryTarget,
      notes: [memoryNote()],
    );
    await open(t);
    await read(t);
    // A revision change between read and add must never be guessed.
    connection.memory[memoryProfileA] = memoryState(
      revision: 3,
      target: memoryTarget,
      notes: [memoryNote()],
    );
    await tap(t, 'memory-notes-add');
    await t.enterText(memoryKey('memory-notes-add-text'), '新便签');
    await tap(t, 'memory-notes-add-save');
    expect(
      find.byKey(const Key('memory-notes-unknown'), skipOffstage: false),
      findsOneWidget,
    );
    _expectProblemIcon(
      find.byKey(const Key('memory-notes-unknown'), skipOffstage: false),
    );
    expect(
      find.byKey(const Key('memory-notes-read'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      connection.memoryCalls.where((call) => call.$1 == 'POST'),
      hasLength(1),
    );
  });

  testWidgets('lock and session changes retire the section', (t) async {
    await open(t);
    await read(t);
    runtime.changeView(lock: true);
    await t.pumpAndSettle();
    expect(memoryKey('owner-memory-notes-section'), findsNothing);
    expect(memoryKey('ai-config-session-invalid'), findsOneWidget);
    expect(connection.memoryCalls.where((call) => call.$1 != 'GET'), isEmpty);
  });

  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('memory notes and permission fit at $width logical pixels', (
      t,
    ) async {
      connection.memory[memoryProfileA] = memoryState(
        revision: 0,
        target: memoryTarget,
        notes: [
          memoryNote(),
          memoryNote(id: 'note-b', text: '第二句'),
        ],
      );
      t.view.physicalSize = Size(width, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await openMemoryEditor(t, runtime);
      await read(t);
      expect(memoryKey('memory-notes-add').hitTestable(), findsOneWidget);
      expect(memoryKey('memory-notes-enabled').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
