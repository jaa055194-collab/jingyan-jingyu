import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/world/street3d_entry.dart';
import 'package:client_flutter/features/world/world_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Model extends ChangeNotifier implements ShellViewModel {
  _Model({this.connectedAccountId = 'alice'});
  @override
  bool onboarded = true;
  @override
  bool busy = false;
  @override
  String? connectedAccountId;
  @override
  bool get authenticated => connectedAccountId != null;
  // Read by the Live2D import panel that shares the World page.
  @override
  bool appLockEnabled = false;
  @override
  Object? get ownAiSessionContext => connectedAccountId;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpWorld(
  WidgetTester tester,
  _Model model, {
  VoidCallback? onOpenStreet,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 2200);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: WorldScreen(
          model: model,
          onOpenSetup: () {},
          onOpenStreet: onOpenStreet,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'world page mounts the 3D street section once and opens the street',
    (tester) async {
      var opened = 0;
      await _pumpWorld(tester, _Model(), onOpenStreet: () => opened++);
      expect(find.byType(Street3DEntry), findsOneWidget);
      expect(find.text('3D 街区'), findsOneWidget);
      expect(find.textContaining('只有 Android 端接入'), findsOneWidget);
      expect(find.textContaining('渲染尚未接入'), findsNothing);
      await tester.tap(find.byKey(const Key('world-open-street3d')));
      expect(opened, 1);
    },
  );

  testWidgets(
    'without a street callback the section explains but has no button',
    (tester) async {
      await _pumpWorld(tester, _Model());
      expect(find.text('3D 街区'), findsOneWidget);
      expect(find.textContaining('只有 Android 端接入'), findsOneWidget);
      expect(find.byKey(const Key('world-open-street3d')), findsNothing);
    },
  );

  testWidgets('the street button waits for a signed-in account', (
    tester,
  ) async {
    var opened = 0;
    await _pumpWorld(
      tester,
      _Model(connectedAccountId: null),
      onOpenStreet: () => opened++,
    );
    await tester.tap(find.byKey(const Key('world-open-street3d')));
    expect(opened, 0);
  });
}
