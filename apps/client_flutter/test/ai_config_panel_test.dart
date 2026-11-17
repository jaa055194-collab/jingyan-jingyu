import 'package:client_flutter/features/ai_config/ai_config_panel.dart';
import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:client_flutter/net/owner_ai_readiness_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

AiConfigSnapshot _snapshot() => const AiConfigSnapshot([
  AiConfigEntry('人格', ConfigurationReadStatus.configurationPresent, [
    '档案：p1 · 版本 3',
    '人格未锁定',
    'p0 字段：identity',
  ]),
  AiConfigEntry('绑定', ConfigurationReadStatus.configurationPresent, [
    'chat → prov-1 · gpt-x',
  ]),
  AiConfigEntry('预算', ConfigurationReadStatus.unconfigured, ['未配置']),
  AiConfigEntry('Provider', ConfigurationReadStatus.configurationPresent, [
    'My Provider',
    'https://provider.example/v1',
    '掩码：****abcd（不是密钥）',
    '已启用',
    '能力：chat',
  ]),
]);

void main() {
  testWidgets('renders read-only configuration metadata with statuses', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: AiConfigPanel(load: () async => _snapshot())),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI 运行配置体检'), findsOneWidget);
    expect(find.textContaining('不等于模型可用'), findsOneWidget);
    expect(find.textContaining('人格 · 已配置'), findsOneWidget);
    expect(find.textContaining('chat → prov-1 · gpt-x'), findsOneWidget);
    expect(find.textContaining('预算 · 未配置'), findsOneWidget);
    expect(find.textContaining('掩码：****abcd（不是密钥）'), findsOneWidget);
    // Read-only: no inputs, toggles or submit actions.
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('unknown state when no loader is available', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AiConfigPanel()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai-config-unknown')), findsOneWidget);
    expect(find.textContaining('不会自动重试'), findsOneWidget);
    expect(find.textContaining('未知不代表未配置'), findsOneWidget);
  });

  testWidgets('unknown state when load fails, without leaking details', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AiConfigPanel(
          load: () async => throw const FormatException('secret-detail-xyz'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai-config-unknown')), findsOneWidget);
    expect(find.textContaining('secret-detail-xyz'), findsNothing);
  });

  testWidgets('settings developer entry opens the read-only panel', (
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

    final entry = find.byKey(const Key('open-ai-config'));
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.text('AI 运行配置体检'), findsWidgets);
    // The test model is not the runtime, so there is no host connection.
    expect(find.byKey(const Key('ai-config-unknown')), findsOneWidget);
  });

  testWidgets('selects an owned AI and renders its readiness snapshot', (
    tester,
  ) async {
    final loaded = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AiConfigPanel(
          ownedAiAccountIds: const ['ai-one', 'ai-two'],
          loadForAccount: (id) async {
            loaded.add(id);
            return _snapshot();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(loaded, ['ai-one']); // first owned AI auto-selected
    expect(find.textContaining('人格 · 已配置'), findsOneWidget);
    expect(find.byKey(const Key('ai-config-unknown')), findsNothing);

    await tester.tap(find.byKey(const Key('ai-config-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ai-two').last);
    await tester.pumpAndSettle();
    expect(loaded, ['ai-one', 'ai-two']);
  });

  testWidgets('empty owned AI list stays honest unknown', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AiConfigPanel(
          ownedAiAccountIds: const [],
          loadForAccount: (_) async {
            calls++;
            return _snapshot();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-config-unknown')), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets(
    'account loader failure becomes unknown without leaking details',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AiConfigPanel(
            ownedAiAccountIds: const ['ai-one'],
            loadForAccount: (_) async =>
                throw const FormatException('secret-detail-xyz'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai-config-unknown')), findsOneWidget);
      expect(find.textContaining('secret-detail-xyz'), findsNothing);
    },
  );
}
