import 'package:client_flutter/features/ai_config/ai_config_editor.dart';
import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:client_flutter/net/ai_config_write_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/ui/jy_palette.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

class _FakeWriter implements AiConfigWriter {
  final List<String> calls = <String>[];
  Map<String, Object?> last = <String, Object?>{};

  ProviderConfigView _view(String name, Set<String> caps) => ProviderConfigView(
    id: 'prov-1',
    name: name,
    baseUrl: 'https://provider.example/v1',
    keyMask: '****abcd',
    enabled: true,
    capabilities: caps.toList(),
  );

  @override
  Future<ProviderConfigView> createProvider({
    required String name,
    required String baseUrl,
    required String apiKey,
    required Set<String> capabilities,
    bool enabled = true,
  }) async {
    calls.add('createProvider');
    last = {
      'name': name,
      'baseUrl': baseUrl,
      'apiKey': apiKey,
      'capabilities': capabilities,
    };
    return _view(name, capabilities);
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
    last = {'providerId': providerId, 'name': name, 'apiKey': apiKey};
    return _view(name ?? 'P', capabilities ?? {'chat'});
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
    last = {'profile': aiProfileId, 'providerId': providerId, 'model': model};
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
    last = {
      'dailyTokens': dailyTokens,
      'layerLimits': layerLimits,
      'capabilityLimits': capabilityLimits,
      'offsetMinutes': offsetMinutes,
    };
  }
}

/// Writer that fails every chat binding with a fixed host failure code.
class _ErrorWriter extends _FakeWriter {
  _ErrorWriter(this.code);
  final FailureCode code;

  @override
  Future<void> setChatBinding(
    String aiProfileId, {
    required String providerId,
    required String model,
  }) async {
    throw HostRequestException(Failure(code, 'upstream detail must-not-leak'));
  }
}

Future<void> _pump(WidgetTester tester, AiConfigWriter? writer) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AiConfigEditor(
        writer: writer,
        resolveProfileId: (account) async => 'profile-1',
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

Future<void> _top(WidgetTester tester) async {
  await tester.drag(find.byType(Scrollable).first, const Offset(0, 6000));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('provider create submits api_key and only shows key_mask', (
    tester,
  ) async {
    final writer = _FakeWriter();
    await _pump(tester, writer);
    await _to(tester, const Key('provider-name'));
    await tester.enterText(find.byKey(const Key('provider-name')), 'P');
    await tester.enterText(
      find.byKey(const Key('provider-base-url')),
      'https://provider.example/v1',
    );
    await tester.enterText(
      find.byKey(const Key('provider-api-key')),
      'super-secret-key',
    );
    await tester.enterText(
      find.byKey(const Key('provider-capabilities')),
      'chat',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('provider-api-key')))
          .obscureText,
      isTrue,
    );
    await _to(tester, const Key('provider-create'));
    await tester.tap(find.byKey(const Key('provider-create')));
    await tester.pumpAndSettle();
    expect(writer.calls, ['createProvider']);
    expect(writer.last['apiKey'], 'super-secret-key');
    await _to(tester, const Key('ai-config-write-status'));
    expect(find.textContaining('****abcd'), findsOneWidget);
    // The obscured field is cleared and the raw key is never rendered as text.
    expect(find.textContaining('super-secret-key'), findsNothing);
  });

  testWidgets('persona initialize sends three nonempty layers', (tester) async {
    final writer = _FakeWriter();
    await _pump(tester, writer);
    await _to(tester, const Key('persona-p0'));
    await tester.enterText(find.byKey(const Key('persona-p0')), 'name=Nora');
    await tester.enterText(find.byKey(const Key('persona-p1')), 'style=warm');
    await tester.enterText(find.byKey(const Key('persona-p2')), 'mood=calm');
    await _to(tester, const Key('persona-initialize'));
    await tester.tap(find.byKey(const Key('persona-initialize')));
    await tester.pumpAndSettle();
    expect(writer.calls, ['initializePersona']);
    expect(writer.last['p0'], {'name': 'Nora'});
    expect(writer.last['p1'], {'style': 'warm'});
    expect(writer.last['p2'], {'mood': 'calm'});
  });

  testWidgets('binding and budget submit validated values', (tester) async {
    final writer = _FakeWriter();
    await _pump(tester, writer);
    await _to(tester, const Key('binding-provider'));
    await tester.enterText(find.byKey(const Key('binding-provider')), 'prov-1');
    await tester.enterText(find.byKey(const Key('binding-model')), 'gpt-x');
    await _to(tester, const Key('binding-save'));
    await tester.tap(find.byKey(const Key('binding-save')));
    await tester.pumpAndSettle();
    expect(writer.calls, ['setChatBinding']);
    expect(writer.last['providerId'], 'prov-1');
    expect(writer.last['model'], 'gpt-x');

    await _to(tester, const Key('budget-daily'));
    await tester.enterText(find.byKey(const Key('budget-daily')), '100');
    await _to(tester, const Key('budget-offset'));
    await tester.enterText(find.byKey(const Key('budget-offset')), '480');
    await _to(tester, const Key('budget-layers'));
    await tester.enterText(
      find.byKey(const Key('budget-layers')),
      'b0Life=1\nb1FastBrain=1\nb2DeepChat=1\nb3Proactive=1\nb4Maintenance=1',
    );
    await _to(tester, const Key('budget-caps'));
    await tester.enterText(
      find.byKey(const Key('budget-caps')),
      'chat=1\nchatFast=1\nvision=1\nimageGen=1\ntts=1\nasr=1\nembedding=1',
    );
    await tester.ensureVisible(find.byKey(const Key('budget-save')));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -250));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('budget-save')));
    await tester.pumpAndSettle();
    await _top(tester);
    expect(writer.calls, ['setChatBinding', 'configureBudget']);
    expect(writer.last['dailyTokens'], 100);
    expect(writer.last['offsetMinutes'], 480);
  });

  testWidgets('invalid persona input does not submit', (tester) async {
    final writer = _FakeWriter();
    await _pump(tester, writer);
    await _to(tester, const Key('persona-p0'));
    await tester.enterText(find.byKey(const Key('persona-p0')), '');
    await tester.enterText(find.byKey(const Key('persona-p1')), 'style=warm');
    await tester.enterText(find.byKey(const Key('persona-p2')), 'mood=calm');
    await _to(tester, const Key('persona-initialize'));
    await tester.tap(find.byKey(const Key('persona-initialize')));
    await tester.pumpAndSettle();
    expect(writer.calls, isEmpty);
    await _to(tester, const Key('ai-config-write-status'));
    expect(find.byKey(const Key('ai-config-write-status')), findsOneWidget);
  });

  testWidgets('no writer keeps the hub read-only with an honest message', (
    tester,
  ) async {
    await _pump(tester, null);
    expect(find.textContaining('未连接宿主'), findsOneWidget);
    // No writer blocks editing but is not a failed read or write: warning tone.
    final line = find.byKey(const Key('ai-config-no-writer'));
    expect(line, findsOneWidget);
    final palette = JyPalette.of(tester.element(line));
    final icon = tester.widget<Icon>(
      find.descendant(of: line, matching: find.byType(Icon)),
    );
    expect(icon.icon, Icons.warning_amber_outlined);
    expect(icon.color, palette.warning);
    expect(
      tester
          .widget<Text>(
            find.descendant(of: line, matching: find.textContaining('未连接宿主')),
          )
          .style
          ?.color,
      palette.warning,
    );
    await _to(tester, const Key('provider-create'));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('provider-create')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('each section explains its own rules', (tester) async {
    await _pump(tester, _FakeWriter());
    await _to(tester, const Key('help-persona'));
    expect(find.byKey(const Key('help-persona')), findsOneWidget);
    expect(find.textContaining('P0'), findsWidgets);
    expect(find.textContaining('历史可回滚'), findsOneWidget);

    await _to(tester, const Key('help-provider'));
    expect(find.byKey(const Key('help-provider')), findsOneWidget);
    expect(find.textContaining('key_mask'), findsOneWidget);

    await _to(tester, const Key('help-binding'));
    expect(find.byKey(const Key('help-binding')), findsOneWidget);
    expect(find.textContaining('Provider ID 与模型 ID'), findsOneWidget);

    await _to(tester, const Key('help-budget'));
    expect(find.byKey(const Key('help-budget')), findsOneWidget);
    expect(find.textContaining('预算四字段'), findsOneWidget);
    expect(find.textContaining('能力限额'), findsOneWidget);
  });

  testWidgets('success, denied and unknown states are labeled distinctly', (
    tester,
  ) async {
    final writer = _FakeWriter();
    await _pump(tester, writer);
    await _to(tester, const Key('binding-provider'));
    await tester.enterText(find.byKey(const Key('binding-provider')), 'prov-1');
    await tester.enterText(find.byKey(const Key('binding-model')), 'gpt-x');
    await tester.tap(find.byKey(const Key('binding-save')));
    await tester.pumpAndSettle();
    await _to(tester, const Key('ai-config-write-status'));
    expect(find.text('成功'), findsOneWidget);
    expect(find.byKey(const Key('ai-config-write-state')), findsOneWidget);

    final denied = _ErrorWriter(FailureCode.forbidden);
    await _pump(tester, denied);
    await _to(tester, const Key('binding-provider'));
    await tester.enterText(find.byKey(const Key('binding-provider')), 'prov-1');
    await tester.enterText(find.byKey(const Key('binding-model')), 'gpt-x');
    await tester.tap(find.byKey(const Key('binding-save')));
    await tester.pumpAndSettle();
    await _to(tester, const Key('ai-config-write-status'));
    expect(find.text('失败/未知'), findsOneWidget);
    expect(find.textContaining('未认证或无权限'), findsOneWidget);

    final unknown = _ErrorWriter(FailureCode.unavailable);
    await _pump(tester, unknown);
    await _to(tester, const Key('binding-provider'));
    await tester.enterText(find.byKey(const Key('binding-provider')), 'prov-1');
    await tester.enterText(find.byKey(const Key('binding-model')), 'gpt-x');
    await tester.tap(find.byKey(const Key('binding-save')));
    await tester.pumpAndSettle();
    await _to(tester, const Key('ai-config-write-status'));
    expect(find.text('失败/未知'), findsOneWidget);
    expect(find.textContaining('操作失败或结果未知'), findsOneWidget);
  });

  testWidgets('write status sits under the action of the group that wrote', (
    tester,
  ) async {
    const status = Key('ai-config-write-status');
    Finder anywhere(Key key) => find.byKey(key, skipOffstage: false);
    Finder inGroup(String group) => find.descendant(
      of: anywhere(Key('ai-config-group-$group')),
      matching: anywhere(status),
      skipOffstage: false,
    );
    double bottomOf(Key key) => tester.getBottomLeft(find.byKey(key)).dy;
    double statusTop() => tester.getTopLeft(find.byKey(status)).dy;
    Icon icon() =>
        tester.widget<Icon>(find.byKey(const Key('ai-config-write-icon')));
    Color? stateColor() => tester
        .widget<Text>(find.byKey(const Key('ai-config-write-state')))
        .style
        ?.color;
    final liveRegion = find.ancestor(
      of: find.byKey(const Key('ai-config-write-state')),
      matching: find.byWidgetPredicate(
        (w) => w is Semantics && (w.properties.liveRegion ?? false),
      ),
    );

    // _ErrorWriter only fails setChatBinding, so Provider writes succeed.
    await _pump(tester, _ErrorWriter(FailureCode.forbidden));
    await _to(tester, const Key('provider-name'));
    await tester.enterText(find.byKey(const Key('provider-name')), 'P');
    await tester.enterText(
      find.byKey(const Key('provider-base-url')),
      'https://provider.example/v1',
    );
    await tester.enterText(
      find.byKey(const Key('provider-api-key')),
      'super-secret-key',
    );
    await tester.enterText(
      find.byKey(const Key('provider-capabilities')),
      'chat',
    );
    await _to(tester, const Key('provider-create'));
    await tester.tap(find.byKey(const Key('provider-create')));
    await tester.pumpAndSettle();
    await _to(tester, status);
    expect(anywhere(status), findsOneWidget);
    expect(inGroup('provider'), findsOneWidget);
    expect(
      statusTop(),
      greaterThanOrEqualTo(bottomOf(const Key('provider-create'))),
    );
    final palette = JyPalette.of(tester.element(find.byKey(status)));
    expect(icon().color, palette.success);
    expect(stateColor(), palette.success);
    expect(liveRegion, findsOneWidget);
    final successIcon = icon().icon;

    // A failed binding write moves the single status into the binding group.
    await _to(tester, const Key('binding-provider'));
    await tester.enterText(find.byKey(const Key('binding-provider')), 'p1');
    await tester.enterText(find.byKey(const Key('binding-model')), 'gpt-4o');
    await tester.tap(find.byKey(const Key('binding-save')));
    await tester.pumpAndSettle();
    await _to(tester, status);
    expect(anywhere(status), findsOneWidget);
    expect(inGroup('binding'), findsOneWidget);
    expect(inGroup('provider'), findsNothing);
    expect(
      statusTop(),
      greaterThanOrEqualTo(bottomOf(const Key('binding-save'))),
    );
    expect(find.textContaining('未认证或无权限'), findsOneWidget);
    expect(icon().color, palette.danger);
    expect(stateColor(), palette.danger);
    expect(icon().icon, isNot(successIcon));
  });

  testWidgets('settings exposes the write hub entry and opens it', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(model: TestShellModel(), onBack: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('open-ai-config-write'));
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('AI 运行配置'), findsWidgets);
    expect(find.textContaining('未连接宿主'), findsOneWidget);
  });
}
