import 'package:client_flutter/app/app_theme.dart';
import 'package:client_flutter/ui/jy_motion.dart';
import 'package:client_flutter/ui/jy_overlays.dart';
import 'package:client_flutter/ui/jy_palette.dart';
import 'package:client_flutter/ui/jy_tokens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// An app on [buildAppTheme] with one button, 'open', that calls [onOpen];
/// [reduceMotion] stands in for the system setting.
Widget _app(
  void Function(BuildContext context) onOpen, {
  bool reduceMotion = false,
}) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.dark),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (BuildContext context) => Center(
          child: TextButton(
            onPressed: () => onOpen(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Widget _alert(BuildContext context) {
  return AlertDialog(
    title: const Text('确认？'),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('好'),
      ),
    ],
  );
}

/// Product of the opacities the route puts around the dialog.
double _opacity(WidgetTester tester) {
  double value = 1;
  for (final FadeTransition fade in tester.widgetList<FadeTransition>(
    find.ancestor(
      of: find.byType(AlertDialog),
      matching: find.byType(FadeTransition),
    ),
  )) {
    value *= fade.opacity.value;
  }
  return value;
}

/// Product of the scales the route puts around the dialog.
double _scale(WidgetTester tester) {
  double value = 1;
  for (final ScaleTransition scale in tester.widgetList<ScaleTransition>(
    find.ancestor(
      of: find.byType(AlertDialog),
      matching: find.byType(ScaleTransition),
    ),
  )) {
    value *= scale.scale.value;
  }
  return value;
}

ModalRoute<Object?> _routeOf(WidgetTester tester, Finder finder) =>
    ModalRoute.of(tester.element(finder))!;

void main() {
  group('showJyDialog', () {
    testWidgets('opens an AlertDialog that a barrier tap closes in 300ms', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(
          (BuildContext context) =>
              showJyDialog<void>(context: context, builder: _alert),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tapAt(const Offset(8, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
    });

    testWidgets('stays open on a barrier tap when not barrierDismissible', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(
          (BuildContext context) => showJyDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: _alert,
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(8, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.text('好'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
    });

    testWidgets('grows from 0.94 to 1 while it fades in over 360ms', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(
          (BuildContext context) =>
              showJyDialog<void>(context: context, builder: _alert),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(_scale(tester), closeTo(0.94, 1e-9));
      expect(_opacity(tester), 0);

      await tester.pump(const Duration(milliseconds: 180));
      expect(_scale(tester), inExclusiveRange(0.94, 1));
      expect(_opacity(tester), inExclusiveRange(0, 1));

      await tester.pump(const Duration(milliseconds: 180));
      expect(_scale(tester), 1);
      expect(_opacity(tester), 1);
    });

    testWidgets('uses the scrim, 360ms in and 252ms out', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(
          (BuildContext context) =>
              showJyDialog<void>(context: context, builder: _alert),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final ModalRoute<Object?> route = _routeOf(
        tester,
        find.byType(AlertDialog),
      );
      expect(route, isA<JyDialogRoute<void>>());
      expect(route.barrierColor, JyPalette.dark.scrim);
      expect(route.transitionDuration, JyDurations.emphasized);
      expect(
        route.reverseTransitionDuration,
        const Duration(milliseconds: 252),
      );
    });

    testWidgets('only fades with reduced motion, opaque after 120ms', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(
          (BuildContext context) =>
              showJyDialog<void>(context: context, builder: _alert),
          reduceMotion: true,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(_scale(tester), 1);
      expect(_opacity(tester), 0);

      await tester.pump(const Duration(milliseconds: 120));
      expect(_scale(tester), 1);
      expect(_opacity(tester), 1);
      await tester.pumpAndSettle();

      final ModalRoute<Object?> route = _routeOf(
        tester,
        find.byType(AlertDialog),
      );
      expect(route.transitionDuration, JyDurations.reduced);
      expect(route.reverseTransitionDuration, JyDurations.reduced);

      // A controller only finishes on the first frame past its duration.
      await tester.tapAt(const Offset(8, 8));
      await tester.pump();
      await tester.pump(JyDurations.reduced + const Duration(milliseconds: 1));
      expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
    });
  });

  group('JyDialogRoute', () {
    testWidgets('removeRoute takes the dialog down in one frame', (
      WidgetTester tester,
    ) async {
      late JyDialogRoute<bool> route;
      await tester.pumpWidget(
        _app((BuildContext context) {
          final NavigatorState navigator = Navigator.of(context);
          route = JyDialogRoute<bool>(
            context: context,
            builder: _alert,
            themes: InheritedTheme.capture(
              from: context,
              to: navigator.context,
            ),
          );
          navigator.push(route);
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(route.barrierColor, JyPalette.dark.scrim);
      expect(route.barrierDismissible, isTrue);

      route.navigator!.removeRoute(route);
      await tester.pump();
      expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
    });
  });

  group('showJySheet', () {
    testWidgets('has a drag handle, the overlay colour, xl corners, a scrim', (
      WidgetTester tester,
    ) async {
      late BuildContext sheetContext;
      await tester.pumpWidget(
        _app(
          (BuildContext context) => showJySheet<void>(
            context: context,
            builder: (BuildContext context) {
              sheetContext = context;
              return const SizedBox(height: 120, child: Text('面板'));
            },
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final BottomSheet sheet = tester.widget<BottomSheet>(
        find.byType(BottomSheet),
      );
      expect(sheet.showDragHandle, isTrue);
      expect(sheet.backgroundColor, JyPalette.dark.overlay);
      expect(sheet.shape, JyShapes.sheet);

      final ModalRoute<Object?> route = ModalRoute.of(sheetContext)!;
      expect(route, isA<ModalBottomSheetRoute<void>>());
      expect(
        (route as ModalBottomSheetRoute<void>).modalBarrierColor,
        JyPalette.dark.scrim,
      );
      expect(route.transitionDuration, JyDurations.emphasized);
      expect(
        route.reverseTransitionDuration,
        JyDurations.exit(JyDurations.emphasized),
      );
    });

    for (final bool scrollControlled in <bool>[false, true]) {
      testWidgets('height with isScrollControlled: $scrollControlled', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          _app(
            (BuildContext context) => showJySheet<void>(
              context: context,
              isScrollControlled: scrollControlled,
              builder: (BuildContext context) =>
                  const SizedBox(height: 2000, child: Text('面板')),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        final double screen = tester.getSize(find.byType(Scaffold)).height;
        final double height = tester.getSize(find.byType(BottomSheet)).height;
        if (scrollControlled) {
          expect(height, screen);
        } else {
          expect(height, lessThanOrEqualTo(screen * 9 / 16));
        }
      });
    }

    testWidgets('takes 120ms each way with reduced motion', (
      WidgetTester tester,
    ) async {
      late BuildContext sheetContext;
      await tester.pumpWidget(
        _app(
          (BuildContext context) => showJySheet<void>(
            context: context,
            builder: (BuildContext context) {
              sheetContext = context;
              return const SizedBox(height: 120);
            },
          ),
          reduceMotion: true,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final ModalRoute<Object?> route = ModalRoute.of(sheetContext)!;
      expect(route.transitionDuration, JyDurations.reduced);
      expect(route.reverseTransitionDuration, JyDurations.reduced);
      expect(
        tester.widget<BottomSheet>(find.byType(BottomSheet)).showDragHandle,
        isTrue,
      );
    });
  });
}
