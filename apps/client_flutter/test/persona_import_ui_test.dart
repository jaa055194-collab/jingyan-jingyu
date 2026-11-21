import 'package:client_flutter/features/ai_config/ai_config_editor.dart';
import 'package:client_flutter/features/ai_config/persona_card_import.dart';
import 'package:client_flutter/features/ai_config/persona_file_picker.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/net/ai_config_write_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

/// Minimal fixed sample shared by UI tests; parser tests cover real boundaries.
const personaSampleJson = '''
{
  "format": "PRIVATE_AI_PERSONA_1",
  "p0": {"name": "Nora", "role": "guide"},
  "p1": {"style": "warm"},
  "p2": {"mood": "calm"}
}
''';

class _Picker implements PersonaFilePicker {
  _Picker(this.next);
  Future<PersonaFileImport?> Function() next;
  int calls = 0;

  @override
  Future<PersonaFileImport?> pick() async {
    calls++;
    return next();
  }
}

class _FailingPicker implements PersonaFilePicker {
  _FailingPicker(this.problem);
  final PersonaFileProblem problem;

  @override
  Future<PersonaFileImport?> pick() async {
    throw PersonaFileImportException(problem);
  }
}

class _FakeWriter implements AiConfigWriter {
  final calls = <String>[];
  Map<String, Object?> last = const {};

  @override
  Future<ProviderConfigView> createProvider({
    required String name,
    required String baseUrl,
    required String apiKey,
    required Set<String> capabilities,
    bool enabled = true,
  }) async {
    calls.add('createProvider');
    return ProviderConfigView(
      id: 'prov-1',
      name: name,
      baseUrl: baseUrl,
      keyMask: '****abcd',
      enabled: true,
      capabilities: capabilities.toList(),
    );
  }

  @override
  Future<ProviderConfigView> updateProvider(
    String providerId, {
    String? name,
    String? baseUrl,
    String? apiKey,
    Set<String>? capabilities,
    bool? enabled,
  }) async {
    calls.add('updateProvider');
    return ProviderConfigView(
      id: providerId,
      name: name ?? 'P',
      baseUrl: 'https://provider.example/v1',
      keyMask: '****abcd',
      enabled: true,
      capabilities: const ['chat'],
    );
  }

  @override
  Future<void> initializePersona(
    String aiProfileId, {
    required Map<String, String> p0,
    required Map<String, String> p1,
    required Map<String, String> p2,
  }) async {
    calls.add('initializePersona');
    last = {'profile': aiProfileId, 'p0': p0, 'p1': p1, 'p2': p2};
  }

  @override
  Future<void> editPersona(
    String aiProfileId, {
    required int expectedVersion,
    required String reason,
    required Map<String, String?> p0,
    required Map<String, String?> p1,
    required Map<String, String?> p2,
  }) async {
    calls.add('editPersona');
    last = {'version': expectedVersion, 'reason': reason, 'p0': p0};
  }

  @override
  Future<void> setChatBinding(
    String aiProfileId, {
    required String providerId,
    required String model,
  }) async {
    calls.add('setChatBinding');
  }

  @override
  Future<void> configureBudget(
    String aiProfileId, {
    required int dailyTokens,
    required Map<String, int> layerLimits,
    required Map<String, int> capabilityLimits,
    required int offsetMinutes,
  }) async {
    calls.add('configureBudget');
  }
}

class _EditorSession extends TestShellModel {
  _EditorSession() {
    connectedAccountId = 'fixture-owner';
  }

  @override
  List<ShellOwnedAi> ownAiAccounts = const [
    ShellOwnedAi(accountId: 'ai-1', displayName: '示例 AI', disabled: false),
  ];
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeWriter writer,
  PersonaFilePicker? picker,
  _EditorSession? session,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AiConfigEditor(
        writer: writer,
        resolveProfileId: (account) async => 'profile-1',
        personaFilePicker: picker,
        session: session == null
            ? null
            : (model: session, isCurrent: () => !session.locked),
        ownedAiAccountIds: const ['ai-1'],
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _to(WidgetTester tester, Key key) async {
  await tester.scrollUntilVisible(
    find.byKey(key),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

String _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

PersonaFileImport _fileImport({
  String name = 'synthetic-card.json',
  String json = personaSampleJson,
}) => PersonaFileImport(name: name, card: PersonaCard.parseText(json));

void main() {
  testWidgets('file import only fills the persona form and shows its source', (
    tester,
  ) async {
    final writer = _FakeWriter();
    final picker = _Picker(() async => _fileImport());
    await _pump(tester, writer: writer, picker: picker);
    await _to(tester, const Key('persona-import-file'));
    expect(writer.calls, isEmpty);

    await tester.tap(find.byKey(const Key('persona-import-file')));
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    expect(_field(tester, 'persona-p0'), 'name=Nora\nrole=guide');
    expect(_field(tester, 'persona-p1'), 'style=warm');
    expect(_field(tester, 'persona-p2'), 'mood=calm');
    expect(writer.calls, isEmpty, reason: 'import never writes');
    await _to(tester, const Key('persona-import-status'));
    expect(find.textContaining('synthetic-card.json'), findsOneWidget);
    expect(find.textContaining('P0 2 项'), findsOneWidget);
    expect(find.textContaining('仅填充表单'), findsOneWidget);
  });

  testWidgets('pasted JSON fills the same form without any host write', (
    tester,
  ) async {
    final writer = _FakeWriter();
    await _pump(tester, writer: writer);
    await _to(tester, const Key('persona-import-paste'));
    await tester.tap(find.byKey(const Key('persona-import-paste')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('persona-import-paste-dialog')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('persona-import-paste-input')),
      personaSampleJson,
    );
    await tester.tap(find.byKey(const Key('persona-import-paste-apply')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('persona-import-paste-dialog')), findsNothing);
    expect(_field(tester, 'persona-p0'), 'name=Nora\nrole=guide');
    expect(_field(tester, 'persona-p1'), 'style=warm');
    expect(_field(tester, 'persona-p2'), 'mood=calm');
    expect(writer.calls, isEmpty);
    await _to(tester, const Key('persona-import-status'));
    expect(find.textContaining('粘贴内容'), findsOneWidget);
  });

  testWidgets(
    'invalid pasted JSON reports an error and leaves the form intact',
    (tester) async {
      final writer = _FakeWriter();
      await _pump(tester, writer: writer);
      await _to(tester, const Key('persona-p0'));
      await tester.enterText(find.byKey(const Key('persona-p0')), 'keep=me');
      await _to(tester, const Key('persona-import-paste'));
      await tester.tap(find.byKey(const Key('persona-import-paste')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('persona-import-paste-input')),
        '{"format":"WRONG"}',
      );
      await tester.tap(find.byKey(const Key('persona-import-paste-apply')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('persona-import-paste-dialog')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('persona-import-paste-error')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('persona-import-paste-cancel')));
      await tester.pumpAndSettle();
      expect(_field(tester, 'persona-p0'), 'keep=me');
      expect(writer.calls, isEmpty);
    },
  );

  testWidgets('a cancelled or failed file pick never changes or writes', (
    tester,
  ) async {
    final writer = _FakeWriter();
    final picker = _Picker(() async => null);
    await _pump(tester, writer: writer, picker: picker);
    await _to(tester, const Key('persona-import-file'));
    await tester.tap(find.byKey(const Key('persona-import-file')));
    await tester.pumpAndSettle();
    expect(_field(tester, 'persona-p0'), isEmpty);
    expect(find.byKey(const Key('persona-import-error')), findsNothing);

    await _pump(
      tester,
      writer: writer,
      picker: _FailingPicker(PersonaFileProblem.tooLarge),
    );
    await _to(tester, const Key('persona-import-file'));
    await tester.tap(find.byKey(const Key('persona-import-file')));
    await tester.pumpAndSettle();
    expect(_field(tester, 'persona-p0'), isEmpty);
    await _to(tester, const Key('persona-import-error'));
    expect(find.textContaining('64 KiB'), findsOneWidget);
    expect(writer.calls, isEmpty);
  });

  testWidgets('the existing write buttons act only on explicit clicks', (
    tester,
  ) async {
    final writer = _FakeWriter();
    final picker = _Picker(() async => _fileImport());
    await _pump(tester, writer: writer, picker: picker);
    await _to(tester, const Key('persona-import-file'));
    await tester.tap(find.byKey(const Key('persona-import-file')));
    await tester.pumpAndSettle();
    expect(writer.calls, isEmpty);

    await _to(tester, const Key('persona-edit'));
    await tester.tap(find.byKey(const Key('persona-edit')));
    await tester.pumpAndSettle();
    expect(writer.calls, isEmpty, reason: 'missing version/reason is rejected');

    await _to(tester, const Key('persona-initialize'));
    await tester.tap(find.byKey(const Key('persona-initialize')));
    await tester.pumpAndSettle();
    expect(writer.calls, ['initializePersona']);
    expect(writer.last['profile'], 'profile-1');
    expect(writer.last['p0'], {'name': 'Nora', 'role': 'guide'});
    expect(writer.last['p1'], {'style': 'warm'});
    expect(writer.last['p2'], {'mood': 'calm'});
  });

  testWidgets('locking the session clears imported persona values and source', (
    tester,
  ) async {
    final writer = _FakeWriter();
    final session = _EditorSession();
    final picker = _Picker(() async => _fileImport());
    await _pump(tester, writer: writer, picker: picker, session: session);
    await _to(tester, const Key('persona-import-file'));
    await tester.tap(find.byKey(const Key('persona-import-file')));
    await tester.pumpAndSettle();
    expect(_field(tester, 'persona-p0'), isNotEmpty);

    session.locked = true;
    session.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-config-session-invalid')), findsOneWidget);
    expect(find.byKey(const Key('persona-p0')), findsNothing);
    expect(find.byKey(const Key('persona-import-status')), findsNothing);
    expect(writer.calls, isEmpty);
  });
}
