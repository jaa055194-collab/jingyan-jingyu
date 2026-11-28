import 'package:client_flutter/app/app_theme.dart';
import 'package:client_flutter/ui/jy_interaction.dart';
import 'package:client_flutter/ui/jy_stack_deck.dart';
import 'package:client_flutter/ui/jy_tokens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Widget child, {bool reduce = false}) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.dark),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduce),
      child: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    ),
  );
}

List<Widget> _cards(int count, {VoidCallback? onAccept}) => <Widget>[
  for (int i = 0; i < count; i++)
    SizedBox(
      height: 72,
      child: Row(
        children: <Widget>[
          Expanded(child: Text('card $i')),
          TextButton(onPressed: onAccept, child: Text('accept $i')),
        ],
      ),
    ),
];

void main() {
  testWidgets('collapsed: back cards stay in the tree but are inert', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    int accepted = 0;
    await tester.pumpWidget(
      _app(
        JyStackDeck(
          summary: '3 条好友邀请',
          children: _cards(3, onAccept: () => accepted++),
        ),
      ),
    );
    expect(find.text('card 1'), findsOneWidget);
    expect(find.text('card 2'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('card 1'),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
    expect(find.bySemanticsLabel('card 1'), findsNothing);
    expect(find.bySemanticsLabel('card 0'), findsOneWidget);

    // A button on the top card still works.
    await tester.tap(find.text('accept 0'));
    await tester.pumpAndSettle();
    expect(accepted, 1);
    handle.dispose();
  });

  testWidgets('summary row toggles and reports expanded state', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final List<bool> changes = <bool>[];
    await tester.pumpWidget(
      _app(
        JyStackDeck(
          summary: '3 条好友邀请',
          onExpandedChanged: changes.add,
          children: _cards(3),
        ),
      ),
    );
    final Finder summary = find.text('3 条好友邀请');
    final Finder summaryButton = find.ancestor(
      of: summary,
      matching: find.byType(JyPressable),
    );
    expect(
      tester.getSize(summaryButton).height,
      greaterThanOrEqualTo(JySpace.touchTarget),
    );
    expect(
      tester.getSemantics(summary),
      isSemantics(isButton: true, hasExpandedState: true, isExpanded: false),
    );
    final double collapsedHeight = tester
        .getSize(find.byType(JyStackDeck))
        .height;

    await tester.tap(summary);
    await tester.pumpAndSettle();
    expect(changes, <bool>[true]);
    expect(
      tester.getSemantics(summary),
      isSemantics(isButton: true, hasExpandedState: true, isExpanded: true),
    );
    expect(find.bySemanticsLabel('card 2'), findsOneWidget);
    expect(
      tester.getSize(find.byType(JyStackDeck)).height,
      greaterThan(collapsedHeight),
    );

    await tester.tap(summary);
    await tester.pumpAndSettle();
    expect(changes, <bool>[true, false]);
    expect(find.bySemanticsLabel('card 2'), findsNothing);
    handle.dispose();
  });

  testWidgets('controlled: follows expanded from outside', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(JyStackDeck(summary: 's', expanded: true, children: _cards(2))),
    );
    await tester.pumpAndSettle();
    final double open = tester.getSize(find.byType(JyStackDeck)).height;

    await tester.pumpWidget(
      _app(JyStackDeck(summary: 's', expanded: false, children: _cards(2))),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(JyStackDeck)).height, lessThan(open));
  });

  testWidgets('one card shows just the card; none shows nothing', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(JyStackDeck(summary: 's', children: _cards(1))),
    );
    expect(find.text('s'), findsNothing);
    expect(find.text('card 0'), findsOneWidget);

    await tester.pumpWidget(
      _app(const JyStackDeck(summary: 's', children: <Widget>[])),
    );
    expect(find.text('s'), findsNothing);
  });

  testWidgets('reduced motion: opens with a short fade', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(JyStackDeck(summary: 's', children: _cards(3)), reduce: true),
    );
    await tester.tap(find.text('s'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    final Iterable<Opacity> fades = tester.widgetList<Opacity>(
      find.descendant(
        of: find.byType(JyStackDeck),
        matching: find.byType(Opacity),
      ),
    );
    expect(fades.every((Opacity o) => o.opacity == 1), isTrue);
    expect(
      find.ancestor(
        of: find.text('card 1'),
        matching: find.descendant(
          of: find.byType(JyStackDeck),
          matching: find.byType(Transform),
        ),
      ),
      findsNothing,
    );
  });
}
