import 'package:client_flutter/app/app_theme.dart';
import 'package:client_flutter/ui/jy_interaction.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Widget child, {bool reduce = false}) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.dark),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduce),
      child: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: <Widget>[child]),
        ),
      ),
    ),
  );
}

double _scaleIn(WidgetTester tester, Finder of) {
  final Transform transform = tester.widget<Transform>(
    find.descendant(of: of, matching: find.byType(Transform)).first,
  );
  // The x scale; getMaxScaleOnAxis would also count the unscaled z axis.
  return transform.transform.storage[0];
}

double _opacityIn(WidgetTester tester, Finder of) {
  return tester
      .widget<Opacity>(
        find.descendant(of: of, matching: find.byType(Opacity)).first,
      )
      .opacity;
}

void main() {
  group('JyPressable', () {
    testWidgets('taps, shrinks while held and springs back', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      await tester.pumpWidget(
        _app(
          JyPressable(
            onTap: () => taps++,
            child: const SizedBox(width: 120, height: 48, child: Text('row')),
          ),
        ),
      );
      final Finder pressable = find.byType(JyPressable);
      final Size size = tester.getSize(pressable);

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(pressable),
      );
      // Tap-down arrives after the press timeout; then the scale animates.
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 150));
      expect(_scaleIn(tester, pressable), closeTo(0.97, 0.001));
      expect(tester.getSize(pressable), size);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(_scaleIn(tester, pressable), closeTo(1, 0.001));
    });

    testWidgets('is a focusable button that Enter activates', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      int taps = 0;
      await tester.pumpWidget(
        _app(JyPressable(onTap: () => taps++, child: const Text('go'))),
      );
      expect(
        tester.getSemantics(find.text('go')),
        isSemantics(isButton: true, hasTapAction: true, isEnabled: true),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(taps, 2);
      handle.dispose();
    });

    testWidgets('disabled: no callback and a disabled button', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      int taps = 0;
      await tester.pumpWidget(
        _app(
          JyPressable(
            enabled: false,
            onTap: () => taps++,
            child: const Text('off'),
          ),
        ),
      );
      await tester.tap(find.text('off'));
      await tester.pumpAndSettle();
      expect(taps, 0);
      expect(
        tester.getSemantics(find.text('off')),
        isSemantics(isButton: true, isEnabled: false),
      );
      handle.dispose();
    });

    testWidgets('without callbacks it leaves taps to its children', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      await tester.pumpWidget(
        _app(
          JyPressable(
            child: TextButton(onPressed: () => taps++, child: const Text('in')),
          ),
        ),
      );
      await tester.tap(find.text('in'));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('reduced motion: no scaling', (WidgetTester tester) async {
      await tester.pumpWidget(
        _app(JyPressable(onTap: () {}, child: const Text('row')), reduce: true),
      );
      final Finder pressable = find.byType(JyPressable);
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(pressable),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(_scaleIn(tester, pressable), 1);
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('JyExpand', () {
    Widget expand(bool expanded, {bool maintainState = false}) => _app(
      JyExpand(
        expanded: expanded,
        maintainState: maintainState,
        child: const Text('details'),
      ),
    );

    testWidgets('a collapsed child leaves the tree', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(expand(false));
      expect(find.text('details', skipOffstage: false), findsNothing);

      await tester.pumpWidget(expand(true));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('details'), findsOneWidget);
      expect(_opacityIn(tester, find.byType(JyExpand)), lessThan(1));
      await tester.pumpAndSettle();
      expect(_opacityIn(tester, find.byType(JyExpand)), 1);

      await tester.pumpWidget(expand(false));
      await tester.pumpAndSettle();
      expect(find.text('details', skipOffstage: false), findsNothing);
    });

    testWidgets('maintainState keeps the collapsed child offstage', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(expand(true, maintainState: true));
      await tester.pumpWidget(expand(false, maintainState: true));
      await tester.pumpAndSettle();
      expect(find.text('details'), findsNothing);
      expect(find.text('details', skipOffstage: false), findsOneWidget);
    });

    testWidgets('reduced motion: no movement, short fade', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const JyExpand(expanded: false, child: Text('details')),
          reduce: true,
        ),
      );
      await tester.pumpWidget(
        _app(
          const JyExpand(expanded: true, child: Text('details')),
          reduce: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 130));
      expect(_opacityIn(tester, find.byType(JyExpand)), 1);
    });
  });

  testWidgets('JyChevron turns half a turn when expanded', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(const JyChevron(expanded: false)));
    expect(
      tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
      0,
    );
    await tester.pumpWidget(_app(const JyChevron(expanded: true)));
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
      0.5,
    );
  });

  group('JyEntrance', () {
    testWidgets('only the first eight items animate, once', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(
          Column(
            children: <Widget>[
              for (int i = 0; i < 10; i++)
                JyEntrance(index: i, child: Text('item $i')),
            ],
          ),
        ),
      );
      Finder entrance(int i) => find.ancestor(
        of: find.text('item $i'),
        matching: find.byType(JyEntrance),
      );
      expect(_opacityIn(tester, entrance(0)), lessThan(1));
      expect(
        find.descendant(of: entrance(8), matching: find.byType(Opacity)),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(_opacityIn(tester, entrance(7)), 1);
    });

    testWidgets('reduced motion shows items at once', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(const JyEntrance(index: 0, child: Text('item')), reduce: true),
      );
      expect(
        find.descendant(
          of: find.byType(JyEntrance),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
    });
  });

  group('JySwitcher', () {
    for (final JySwitcherStyle style in JySwitcherStyle.values) {
      testWidgets('${style.name}: old child goes in the same frame', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          _app(
            JySwitcher(
              style: style,
              child: const Text('a', key: ValueKey<String>('a')),
            ),
          ),
        );
        await tester.pumpWidget(
          _app(
            JySwitcher(
              style: style,
              child: const Text('b', key: ValueKey<String>('b')),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 40));
        expect(find.text('a'), findsNothing);
        expect(find.text('b'), findsOneWidget);
        expect(_opacityIn(tester, find.byType(JySwitcher)), lessThan(1));
        await tester.pumpAndSettle();
        expect(_opacityIn(tester, find.byType(JySwitcher)), 1);
        expect(_scaleIn(tester, find.byType(JySwitcher)), closeTo(1, 0.001));
      });
    }

    testWidgets('same key: no transition', (WidgetTester tester) async {
      const Key key = ValueKey<String>('a');
      await tester.pumpWidget(
        _app(const JySwitcher(child: Text('a', key: key))),
      );
      await tester.pumpWidget(
        _app(const JySwitcher(child: Text('a2', key: key))),
      );
      await tester.pump();
      expect(_opacityIn(tester, find.byType(JySwitcher)), 1);
    });
  });
}
