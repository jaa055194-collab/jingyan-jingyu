import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

class _Model extends TestShellModel {
  _Model() {
    connectedAccountId = 'alice';
    online = true;
  }
  final rows = <ShellOwnedAi>[];
  final names = <String>[];
  int loads = 0;
  int contextRevision = 1;
  bool failAfterConfirmedCreate = false;
  String? notice;
  @override
  String? get ownAiNotice => notice;
  @override
  Object? get ownAiSessionContext => contextRevision;
  @override
  List<ShellOwnedAi> get ownAiAccounts => rows;
  @override
  Future<void> loadOwnAi() async {
    loads++;
    notifyListeners();
  }

  @override
  Future<void> createOwnAi(String name) async {
    names.add(name);
    rows.add(
      ShellOwnedAi(
        accountId: 'canonical-ai',
        displayName: name,
        disabled: false,
      ),
    );
    if (failAfterConfirmedCreate) {
      notice = 'AI账户已创建：canonical-ai；列表刷新失败，请刷新我的AI。';
      error = '登录续期暂不可用，请稍后重试';
    }
    notifyListeners();
  }
}

Future<void> reveal(WidgetTester tester, Key key) async {
  await tester.scrollUntilVisible(find.byKey(key), 300);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('settings owns AI create refresh and canonical account ID', (
    tester,
  ) async {
    final model = _Model();
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: model,
          builder: (_, _) => Scaffold(
            body: SettingsScreen(model: model, onBack: () {}),
          ),
        ),
      ),
    );
    await reveal(tester, const Key('own-ai-refresh'));
    await tester.tap(find.byKey(const Key('own-ai-refresh')));
    await tester.pumpAndSettle();
    expect(model.loads, 1);
    await reveal(tester, const Key('own-ai-create'));
    await tester.tap(find.byKey(const Key('own-ai-create')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('own-ai-name')), 'Nora');
    await tester.tap(find.byKey(const Key('own-ai-confirm')));
    await tester.pumpAndSettle();
    expect(model.names, ['Nora']);
    expect(find.text('canonical-ai'), findsOneWidget);
    expect(find.textContaining('回复仍需宿主配置'), findsWidgets);
  });
  testWidgets(
    'confirmed creation closes dialog when list refresh is temporarily unauthorized',
    (tester) async {
      final model = _Model()..failAfterConfirmedCreate = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: model,
            builder: (_, _) => Scaffold(
              body: SettingsScreen(model: model, onBack: () {}),
            ),
          ),
        ),
      );
      await reveal(tester, const Key('own-ai-create'));
      await tester.tap(find.byKey(const Key('own-ai-create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('own-ai-name')), 'Nora');
      await tester.tap(find.byKey(const Key('own-ai-confirm')));
      await tester.pumpAndSettle();
      expect(model.names, ['Nora']);
      expect(find.byKey(const Key('own-ai-name')), findsNothing);
      expect(find.textContaining('canonical-ai'), findsOneWidget);
    },
  );

  testWidgets(
    'same account new session context shields stale private creation input',
    (tester) async {
      final model = _Model();
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: model,
            builder: (_, _) => Scaffold(
              body: SettingsScreen(model: model, onBack: () {}),
            ),
          ),
        ),
      );
      await reveal(tester, const Key('own-ai-create'));
      await tester.tap(find.byKey(const Key('own-ai-create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('own-ai-name')),
        'private-same-account',
      );
      model.contextRevision++;
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('private-same-account'), findsNothing);
      expect(find.byKey(const Key('own-ai-name')), findsNothing);
      expect(model.names, isEmpty);
    },
  );
  testWidgets(
    'own AI creation dialog cancels invalid names and shields on logout',
    (tester) async {
      final model = _Model();
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: model,
            builder: (_, _) => Scaffold(
              body: SettingsScreen(model: model, onBack: () {}),
            ),
          ),
        ),
      );
      await reveal(tester, const Key('own-ai-create'));
      await tester.tap(find.byKey(const Key('own-ai-create')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('own-ai-confirm')));
      await tester.pumpAndSettle();
      expect(model.names, isEmpty);
      await tester.enterText(
        find.byKey(const Key('own-ai-name')),
        'private-name',
      );
      model.connectedAccountId = null;
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('private-name'), findsNothing);
      expect(find.byKey(const Key('own-ai-name')), findsNothing);
      expect(model.names, isEmpty);
    },
  );
}
