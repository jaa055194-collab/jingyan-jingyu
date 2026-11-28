import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

/// Records saves; keeps the in-memory value like the runtime's preference.
class _ReduceMotionModel extends TestShellModel {
  final List<bool> saves = <bool>[];

  @override
  bool reduceMotion = false;

  @override
  Future<void> setReduceMotion(bool value) async {
    if (busy) {
      return;
    }
    saves.add(value);
    reduceMotion = value;
    notifyListeners();
  }
}

final Finder _switchTile = find.byKey(const Key('reduce-motion'));

void main() {
  Future<_ReduceMotionModel> pumpSettings(WidgetTester tester) async {
    final model = _ReduceMotionModel();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: model,
            builder: (context, child) =>
                SettingsScreen(model: model, onBack: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(_switchTile, 300);
    await tester.pumpAndSettle();
    return model;
  }

  testWidgets('toggling 减少动效 saves the value and updates the switch', (
    tester,
  ) async {
    final model = await pumpSettings(tester);
    expect(tester.widget<SwitchListTile>(_switchTile).value, isFalse);

    await tester.tap(_switchTile);
    await tester.pumpAndSettle();

    expect(model.saves, <bool>[true]);
    expect(tester.widget<SwitchListTile>(_switchTile).value, isTrue);

    await tester.tap(_switchTile);
    await tester.pumpAndSettle();
    expect(model.saves, <bool>[true, false]);
    expect(tester.widget<SwitchListTile>(_switchTile).value, isFalse);
  });

  testWidgets('a busy model disables the switch', (tester) async {
    final model = await pumpSettings(tester);
    model.busy = true;
    model.notifyListeners();
    await tester.pump();
    expect(tester.widget<SwitchListTile>(_switchTile).onChanged, isNull);
  });
}
