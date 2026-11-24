import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/world/world_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Model extends ChangeNotifier implements ShellViewModel {
  _Model({this.onboarded = false});
  @override
  bool onboarded;
  @override
  bool busy = false;
  @override
  String? connectedAccountId = 'alice';
  @override
  bool get authenticated => connectedAccountId != null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  // v2 shell members (an `implements` double does not inherit the
  // ShellViewModel defaults).
  @override
  bool get reduceMotion => false;
  @override
  Future<void> setReduceMotion(bool value) async {}
  @override
  bool get conversationsLoaded => true;
  @override
  String? get partnerConversationId => null;
}

void main() {
  testWidgets('world module is honest about pending 3D and offers setup/perf entries', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 2200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = _Model();
    var setup = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorldScreen(model: model, onOpenSetup: () => setup++),
        ),
      ),
    );
    expect(find.text('世界与形象'), findsOneWidget);
    expect(find.textContaining('尚未接入'), findsOneWidget); // honest 3D-pending
    expect(find.textContaining('各端本地'), findsOneWidget); // per-device model
    expect(find.byKey(const Key('world-open-perf')), findsOneWidget);
    await tester.tap(find.byKey(const Key('world-open-setup')));
    expect(setup, 1);
  });

  testWidgets('onboarded world hides setup button', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 2200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = _Model(onboarded: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorldScreen(model: model, onOpenSetup: () {}),
        ),
      ),
    );
    expect(find.byKey(const Key('world-open-setup')), findsNothing);
  });
}
