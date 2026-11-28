import 'package:client_flutter/app/app_theme.dart';
import 'package:client_flutter/ui/jy_dock.dart';
import 'package:client_flutter/ui/jy_motion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// One theme per brightness, so that pumping again does not start a theme
/// animation that would hide the dock's own.
final Map<Brightness, ThemeData> _themes = <Brightness, ThemeData>{};

const List<String> _labels = <String>['聊天', '联系人', '动态', '收件箱', '世界'];

const List<(IconData, IconData)> _icons = <(IconData, IconData)>[
  (Icons.chat_bubble_outline, Icons.chat_bubble),
  (Icons.people_outline, Icons.people),
  (Icons.photo_library_outlined, Icons.photo_library),
  (Icons.inbox_outlined, Icons.inbox),
  (Icons.public, Icons.public),
];

Widget _dock({
  required Brightness brightness,
  required int selected,
  ValueChanged<int>? onSelected,
  bool reduce = false,
  double textScale = 1,
  EdgeInsets padding = EdgeInsets.zero,
}) {
  return MaterialApp(
    theme: _themes.putIfAbsent(brightness, () => buildAppTheme(brightness)),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        padding: padding,
        viewPadding: padding,
        textScaler: TextScaler.linear(textScale),
      ),
      child: JyMotionScope(reduce: reduce, child: child!),
    ),
    home: Scaffold(
      body: const SizedBox.expand(),
      bottomNavigationBar: JyDock(
        items: <JyDockItem>[
          for (int i = 0; i < _labels.length; i++)
            JyDockItem(
              key: Key('dock-$i'),
              icon: _icons[i].$1,
              selectedIcon: _icons[i].$2,
              label: _labels[i],
            ),
        ],
        selectedIndex: selected,
        onSelected: onSelected ?? (int index) {},
      ),
    ),
  );
}

void _narrow(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Rect _cell(WidgetTester tester, int index) =>
    tester.getRect(find.byKey(Key('dock-$index')));

Rect _capsule(WidgetTester tester) => tester.getRect(
  find.descendant(
    of: find.byType(JyDock),
    matching: find.byType(FractionallySizedBox),
  ),
);

void main() {
  for (final Brightness brightness in Brightness.values) {
    group('${brightness.name}:', () {
      testWidgets('JyDock shows every label and reports taps', (
        WidgetTester tester,
      ) async {
        _narrow(tester);
        final List<int> taps = <int>[];
        await tester.pumpWidget(
          _dock(brightness: brightness, selected: 0, onSelected: taps.add),
        );
        for (final String label in _labels) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.byIcon(Icons.chat_bubble), findsOneWidget);
        expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
        expect(find.byIcon(Icons.people_outline), findsOneWidget);
        await tester.tap(find.text('收件箱'));
        await tester.tap(find.byKey(const Key('dock-0')));
        await tester.pumpAndSettle();
        expect(taps, <int>[3, 0]);
      });

      testWidgets('JyDock reads as buttons with the selected one marked and '
          'meets the tap target and contrast guidelines', (
        WidgetTester tester,
      ) async {
        _narrow(tester);
        final SemanticsHandle handle = tester.ensureSemantics();
        await tester.pumpWidget(_dock(brightness: brightness, selected: 1));
        expect(
          tester.getSemantics(find.text('联系人')),
          isSemantics(
            label: '联系人',
            isButton: true,
            isSelected: true,
            hasTapAction: true,
          ),
        );
        expect(
          tester.getSemantics(find.text('聊天')),
          isSemantics(
            label: '聊天',
            isButton: true,
            isSelected: false,
            hasTapAction: true,
          ),
        );
        for (int i = 0; i < _labels.length; i++) {
          final Rect cell = _cell(tester, i);
          expect(cell.width, greaterThanOrEqualTo(48));
          expect(cell.height, greaterThanOrEqualTo(48));
        }
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        handle.dispose();
      });

      testWidgets('JyDock slides its capsule with a spring that settles on '
          'the selected destination', (WidgetTester tester) async {
        _narrow(tester);
        await tester.pumpWidget(_dock(brightness: brightness, selected: 0));
        expect(tester.hasRunningAnimations, isFalse);
        expect(
          _capsule(tester).left,
          moreOrLessEquals(_cell(tester, 0).left, epsilon: 0.01),
        );
        await tester.pumpWidget(_dock(brightness: brightness, selected: 3));
        expect(tester.hasRunningAnimations, isTrue);
        await tester.pump(const Duration(milliseconds: 60));
        final double moving = _capsule(tester).left;
        expect(moving, greaterThan(_cell(tester, 0).left));
        expect(moving, lessThan(_cell(tester, 3).left));
        await tester.pumpAndSettle();
        expect(tester.hasRunningAnimations, isFalse);
        final Rect capsule = _capsule(tester);
        final Rect cell = _cell(tester, 3);
        expect(capsule.left, moreOrLessEquals(cell.left, epsilon: 0.01));
        expect(capsule.width, moreOrLessEquals(cell.width, epsilon: 0.01));
      });

      testWidgets('JyDock jumps to the selected destination when motion is '
          'reduced', (WidgetTester tester) async {
        _narrow(tester);
        await tester.pumpWidget(
          _dock(brightness: brightness, selected: 0, reduce: true),
        );
        await tester.pumpWidget(
          _dock(brightness: brightness, selected: 2, reduce: true),
        );
        expect(tester.hasRunningAnimations, isFalse);
        expect(
          _capsule(tester).left,
          moreOrLessEquals(_cell(tester, 2).left, epsilon: 0.01),
        );
      });

      testWidgets('JyDock floats above the safe area and keeps every label '
          'inside its button at large text sizes', (WidgetTester tester) async {
        _narrow(tester);
        await tester.pumpWidget(
          _dock(
            brightness: brightness,
            selected: 0,
            textScale: 2,
            padding: const EdgeInsets.only(bottom: 34),
          ),
        );
        expect(tester.takeException(), isNull);
        final Rect pill = tester.getRect(
          find
              .descendant(
                of: find.byType(JyDock),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(pill.bottom, moreOrLessEquals(844.0 - 12 - 34, epsilon: 0.01));
        for (int i = 0; i < _labels.length; i++) {
          final Rect label = tester.getRect(find.text(_labels[i]));
          final Rect cell = _cell(tester, i);
          expect(
            label.left,
            greaterThanOrEqualTo(cell.left),
            reason: _labels[i],
          );
          expect(
            label.right,
            lessThanOrEqualTo(cell.right),
            reason: _labels[i],
          );
          expect(label.top, greaterThanOrEqualTo(cell.top), reason: _labels[i]);
          expect(
            label.bottom,
            lessThanOrEqualTo(cell.bottom),
            reason: _labels[i],
          );
        }
      });
    });
  }
}
