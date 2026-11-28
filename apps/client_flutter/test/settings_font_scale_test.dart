import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

/// Records saves and, like AppRuntime._run, drops a save requested while
/// another operation holds the model busy.
class _FontScaleModel extends TestShellModel {
  final saves = <double>[];

  void setBusy(bool value) {
    busy = value;
    notifyListeners();
  }

  @override
  Future<void> setFontScale(double value) async {
    if (busy) return;
    saves.add(value);
    await super.setFontScale(value);
  }
}

final _fontSlider = find.byWidgetPredicate(
  (widget) => widget is Slider && widget.min == 0.85 && widget.max == 1.5,
);

void main() {
  Future<_FontScaleModel> pumpSettings(WidgetTester tester) async {
    final model = _FontScaleModel();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // Like the shell, rebuild the screen whenever the model notifies.
          body: ListenableBuilder(
            listenable: model,
            builder: (context, child) =>
                SettingsScreen(model: model, onBack: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(_fontSlider, 300);
    await tester.pumpAndSettle();
    return model;
  }

  double sliderWidth(WidgetTester tester) => tester.getSize(_fontSlider).width;

  testWidgets('dragging the font size slider saves once, on release', (
    tester,
  ) async {
    final model = await pumpSettings(tester);
    final gesture = await tester.startGesture(tester.getCenter(_fontSlider));
    await gesture.moveBy(Offset(sliderWidth(tester) / 4, 0));
    await tester.pump();
    await gesture.moveBy(Offset(sliderWidth(tester) / 8, 0));
    await tester.pump();

    expect(model.saves, isEmpty, reason: 'no save per step while dragging');
    expect(tester.widget<Slider>(_fontSlider).onChanged, isNotNull);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(model.saves, hasLength(1));
    final saved = model.saves.single;
    expect(saved, greaterThan(1));
    expect(tester.widget<Slider>(_fontSlider).value, saved);
    expect(find.text('字体大小 · ${(saved * 100).round()}%'), findsOneWidget);
  });

  testWidgets('a busy model neither disables the slider nor loses the save', (
    tester,
  ) async {
    final model = await pumpSettings(tester);
    // e.g. a sync started before the user touched the slider.
    model.setBusy(true);
    await tester.pump();

    expect(tester.widget<Slider>(_fontSlider).onChanged, isNotNull);
    await tester.drag(_fontSlider, Offset(sliderWidth(tester) / 4, 0));
    await tester.pump();
    expect(model.saves, isEmpty);
    final released = tester.widget<Slider>(_fontSlider).value;
    expect(released, greaterThan(1), reason: 'thumb keeps the released value');

    model.setBusy(false);
    await tester.pumpAndSettle();
    expect(model.saves, [released]);
  });

  testWidgets('the sample text previews the size before it is saved', (
    tester,
  ) async {
    final model = await pumpSettings(tester);
    final sample = find.byKey(const Key('font-scale-preview'));
    final before = tester.getSize(sample).height;

    final gesture = await tester.startGesture(tester.getCenter(_fontSlider));
    await gesture.moveBy(Offset(sliderWidth(tester) / 4, 0));
    await tester.pump();

    expect(model.saves, isEmpty);
    expect(tester.getSize(sample).height, greaterThan(before));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('screen readers hear the real font size percentage', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpSettings(tester);
      // The slider's own node is the only one here whose value is a
      // percentage. Without a semanticFormatterCallback it holds where the
      // thumb sits between min and max: 23% for a 100% font size.
      // tester.getSemantics(_fontSlider) misses it: the lookup starts above
      // the render object that owns the node and walks up, to a node whose own
      // value is empty.
      final own = find.semantics.byValue(RegExp(r'%$')).evaluate().single;
      // A screen reader announces that node, or the node it is merged into.
      var announced = own;
      while (announced.isMergedIntoParent) {
        announced = announced.parent!;
      }
      expect(announced.getSemanticsData().value, '100%');
    } finally {
      // Open handles are checked before tear-downs run, so dispose here.
      semantics.dispose();
    }
  });
}
