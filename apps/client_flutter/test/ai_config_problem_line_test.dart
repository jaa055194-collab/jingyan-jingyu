import 'package:client_flutter/features/ai_config/ai_config_problem_line.dart';
import 'package:client_flutter/ui/jy_palette.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _message = '读取失败：连接已断开，请稍后重试';

Future<void> _pump(
  WidgetTester tester, {
  required ThemeData theme,
  String message = _message,
  Key? textKey,
  bool warning = false,
}) {
  const key = Key('problem');
  return tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: warning
            ? AiConfigProblemLine.warning(message, key: key, textKey: textKey)
            : AiConfigProblemLine(message, key: key, textKey: textKey),
      ),
    ),
  );
}

Finder _inLine(Finder matching) =>
    find.descendant(of: find.byKey(const Key('problem')), matching: matching);

void main() {
  testWidgets('a problem shows an error icon and danger text', (tester) async {
    await _pump(
      tester,
      theme: ThemeData(extensions: const [JyPalette.light]),
      textKey: const Key('problem-text'),
    );

    final icon = tester.widget<Icon>(_inLine(find.byType(Icon)));
    expect(icon.icon, Icons.error_outline);
    expect(icon.color, JyPalette.light.danger);
    final text = tester.widget<Text>(find.byKey(const Key('problem-text')));
    expect(text.data, _message);
    expect(text.style?.color, JyPalette.light.danger);
    expect(
      _inLine(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.liveRegion == true,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('without a palette extension it follows the theme brightness', (
    tester,
  ) async {
    await _pump(tester, theme: ThemeData(brightness: Brightness.dark));

    final danger = JyPalette.fallback(Brightness.dark).danger;
    expect(tester.widget<Icon>(_inLine(find.byType(Icon))).color, danger);
    expect(tester.widget<Text>(find.text(_message)).style?.color, danger);
  });

  testWidgets('a warning shows a warning icon and warning text', (
    tester,
  ) async {
    await _pump(
      tester,
      theme: ThemeData(extensions: const [JyPalette.light]),
      textKey: const Key('problem-text'),
      warning: true,
    );

    final icon = tester.widget<Icon>(_inLine(find.byType(Icon)));
    expect(icon.icon, Icons.warning_amber_outlined);
    expect(icon.color, JyPalette.light.warning);
    final text = tester.widget<Text>(find.byKey(const Key('problem-text')));
    expect(text.data, _message);
    expect(text.style?.color, JyPalette.light.warning);
    expect(
      _inLine(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.liveRegion == true,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a warning without a palette extension follows the theme', (
    tester,
  ) async {
    await _pump(
      tester,
      theme: ThemeData(brightness: Brightness.dark),
      warning: true,
    );

    final warning = JyPalette.fallback(Brightness.dark).warning;
    expect(tester.widget<Icon>(_inLine(find.byType(Icon))).color, warning);
    expect(tester.widget<Text>(find.text(_message)).style?.color, warning);
  });

  testWidgets('a long problem wraps instead of overflowing', (tester) async {
    tester.view.physicalSize = const Size(240, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      theme: ThemeData(extensions: const [JyPalette.light]),
      message: List.filled(12, '人格卡解析失败').join('，'),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('a notice stays plain text until it is a problem', (
    tester,
  ) async {
    Future<void> pumpNotice({required bool problem}) => tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [JyPalette.light]),
        home: Scaffold(
          body: AiConfigNoticeLine(
            _message,
            textKey: const Key('notice-text'),
            problem: problem,
          ),
        ),
      ),
    );
    final text = find.byKey(const Key('notice-text'));
    Finder around(Finder matching) =>
        find.ancestor(of: text, matching: matching);

    await pumpNotice(problem: false);
    expect(tester.widget<Text>(text).data, _message);
    expect(tester.widget<Text>(text).style, isNull);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(
      around(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.liveRegion == true,
        ),
      ),
      findsOneWidget,
    );

    await pumpNotice(problem: true);
    expect(tester.widget<Text>(text).data, _message);
    expect(around(find.byType(AiConfigProblemLine)), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });
}
