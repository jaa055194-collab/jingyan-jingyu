import 'package:client_flutter/app/app_theme.dart';
import 'package:client_flutter/ui/jy_motion.dart';
import 'package:client_flutter/ui/jy_palette.dart';
import 'package:client_flutter/ui/jy_presence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final Map<Brightness, ThemeData> _themes = <Brightness, ThemeData>{};

/// Reuses one theme per brightness. A new theme object on every pump makes
/// MaterialApp animate between the two, which would hide whether the
/// components themselves are still animating.
Widget _app(Brightness brightness, Widget child, {bool reduce = false}) {
  return MaterialApp(
    theme: _themes.putIfAbsent(brightness, () => buildAppTheme(brightness)),
    home: JyMotionScope(
      reduce: reduce,
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  for (final Brightness brightness in Brightness.values) {
    group('${brightness.name}:', () {
      testWidgets('JyPresenceOrb plays one finite event per state change', (
        WidgetTester tester,
      ) async {
        Widget orb(JyPresence state) =>
            _app(brightness, JyPresenceOrb(state: state));
        await tester.pumpWidget(orb(JyPresence.idle));
        expect(tester.hasRunningAnimations, isFalse);
        await tester.pumpWidget(orb(JyPresence.attention));
        expect(tester.hasRunningAnimations, isTrue);
        await tester.pumpAndSettle();
        await tester.pumpWidget(orb(JyPresence.speaking));
        expect(tester.hasRunningAnimations, isTrue);
        await tester.pumpAndSettle();
        await tester.pumpWidget(orb(JyPresence.offline));
        expect(tester.hasRunningAnimations, isFalse);
      });

      testWidgets('JyPresenceOrb breathes only while thinking', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          _app(brightness, const JyPresenceOrb(state: JyPresence.thinking)),
        );
        await tester.pump(const Duration(seconds: 3));
        expect(tester.hasRunningAnimations, isTrue);
        await tester.pumpWidget(_app(brightness, const JyPresenceOrb()));
        await tester.pumpAndSettle();
        expect(tester.hasRunningAnimations, isFalse);
      });

      testWidgets('JyPresenceOrb is still when motion is reduced', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          _app(
            brightness,
            const JyPresenceOrb(state: JyPresence.thinking),
            reduce: true,
          ),
        );
        expect(tester.hasRunningAnimations, isFalse);
        await tester.pumpWidget(
          _app(
            brightness,
            const JyPresenceOrb(state: JyPresence.speaking),
            reduce: true,
          ),
        );
        expect(tester.hasRunningAnimations, isFalse);
      });

      testWidgets('JyPresenceOrb reads its label', (WidgetTester tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        await tester.pumpWidget(
          _app(
            brightness,
            const JyPresenceOrb(size: 64, semanticsLabel: '鲸鱼伙伴，在线'),
          ),
        );
        expect(find.bySemanticsLabel('鲸鱼伙伴，在线'), findsOneWidget);
        expect(tester.getSize(find.byType(JyPresenceOrb)), const Size(64, 64));
        handle.dispose();
      });

      testWidgets('JySonarPulse sends one wave when the trigger changes', (
        WidgetTester tester,
      ) async {
        Widget pulse(int trigger, {bool reduce = false}) => _app(
          brightness,
          JySonarPulse(
            trigger: trigger,
            child: const SizedBox(width: 48, height: 48),
          ),
          reduce: reduce,
        );
        await tester.pumpWidget(pulse(0));
        expect(tester.hasRunningAnimations, isFalse);
        await tester.pumpWidget(pulse(0));
        expect(tester.hasRunningAnimations, isFalse);
        await tester.pumpWidget(pulse(1));
        expect(tester.hasRunningAnimations, isTrue);
        await tester.pumpAndSettle();
        expect(tester.hasRunningAnimations, isFalse);
        await tester.pumpWidget(pulse(2, reduce: true));
        expect(tester.hasRunningAnimations, isFalse);
      });

      testWidgets('JySonarRings spread once and then stay still', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          _app(brightness, const JySonarRings(child: Icon(Icons.wifi_off))),
        );
        expect(tester.hasRunningAnimations, isTrue);
        await tester.pumpAndSettle();
        expect(tester.hasRunningAnimations, isFalse);
        expect(find.byIcon(Icons.wifi_off), findsOneWidget);
        expect(tester.getSize(find.byType(JySonarRings)), const Size(96, 96));
        await tester.pumpWidget(
          _app(brightness, const SizedBox.shrink(), reduce: true),
        );
        await tester.pumpWidget(
          _app(brightness, const JySonarRings(), reduce: true),
        );
        expect(tester.hasRunningAnimations, isFalse);
      });

      testWidgets('JyBusyIndicator reads its label, also when motion is '
          'reduced', (WidgetTester tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        Widget busy({
          bool linear = false,
          double? value,
          bool reduce = false,
        }) => _app(
          brightness,
          SizedBox(
            width: 200,
            child: JyBusyIndicator(label: '正在处理', linear: linear, value: value),
          ),
          reduce: reduce,
        );
        await tester.pumpWidget(busy());
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.bySemanticsLabel('正在处理'), findsOneWidget);
        await tester.pumpWidget(busy(linear: true));
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.bySemanticsLabel('正在处理'), findsOneWidget);
        await tester.pumpWidget(busy(linear: true, reduce: true));
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.bySemanticsLabel('正在处理'), findsOneWidget);
        expect(tester.hasRunningAnimations, isFalse);
        await tester.pumpWidget(busy(reduce: true));
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.bySemanticsLabel('正在处理'), findsOneWidget);
        await tester.pumpWidget(busy(value: 0.5, reduce: true));
        expect(
          tester
              .widget<CircularProgressIndicator>(
                find.byType(CircularProgressIndicator),
              )
              .value,
          0.5,
        );
        handle.dispose();
      });

      testWidgets('JyStatusDot colours online and offline differently', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          _app(
            brightness,
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                JyStatusDot(key: Key('on'), online: true),
                JyStatusDot(key: Key('off'), online: false),
              ],
            ),
          ),
        );
        final JyPalette palette = JyPalette.of(
          tester.element(find.byKey(const Key('on'))),
        );
        Color colorOf(String key) {
          final DecoratedBox box = tester.widget<DecoratedBox>(
            find.descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(DecoratedBox),
            ),
          );
          return (box.decoration as BoxDecoration).color!;
        }

        expect(colorOf('on'), palette.success);
        expect(colorOf('off'), palette.text3);
        expect(tester.getSize(find.byKey(const Key('on'))), const Size(8, 8));
      });

      testWidgets('JyAvatar draws an initial, two discs for a group and the '
          'orb for the AI', (WidgetTester tester) async {
        await tester.pumpWidget(
          _app(
            brightness,
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                JyAvatar(key: Key('person'), label: 'alice'),
                JyAvatar(
                  key: Key('group'),
                  label: '周末小队',
                  kind: JyAvatarKind.group,
                ),
                JyAvatar(key: Key('ai'), label: '鲸鱼', kind: JyAvatarKind.ai),
              ],
            ),
          ),
        );
        expect(find.text('A'), findsOneWidget);
        expect(find.text('周'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('ai')),
            matching: find.byType(JyPresenceOrb),
          ),
          findsOneWidget,
        );
        for (final String key in <String>['person', 'group', 'ai']) {
          expect(tester.getSize(find.byKey(Key(key))), const Size(44, 44));
        }
      });
    });
  }
}
