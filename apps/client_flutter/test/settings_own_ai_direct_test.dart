import 'dart:async';

import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Model extends ChangeNotifier implements ShellViewModel {
  @override
  String? connectedAccountId;
  @override
  bool online = false, locked = false, busy = false;
  @override
  String? error;
  @override
  bool get authenticated => connectedAccountId != null;
  @override
  bool get appLockEnabled => false;
  @override
  bool get hideNotificationBody => true;
  @override
  String? get selectedConversationId => null;
  @override
  bool get aiConsentGranted => false;
  @override
  bool get autoStart => false;
  @override
  ThemeMode get themeMode => ThemeMode.system;
  @override
  double get fontScale => 1;
  @override
  String? get ownAiNotice => null;
  @override
  bool get ownAiLoaded => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  _Model() {
    connectedAccountId = 'owner';
    online = true;
  }
  Object epoch = Object();
  Object session = Object();
  @override
  Object get ownAiSessionContext => session;
  bool conflict = false;
  int loads = 0, mutations = 0, sends = 0;
  Completer<void>? barrier;
  bool uncertain = false;
  Map<String, Object?>? submitted;
  List<ShellOwnedAi> rows = const [
    ShellOwnedAi(accountId: 'ai-account', displayName: 'Nora', disabled: false),
  ];
  ShellOwnAiDirectState state = const ShellOwnAiDirectState();
  @override
  Object get ownAiDirectContext => epoch;
  @override
  List<ShellOwnedAi> get ownAiAccounts => rows;
  @override
  ShellOwnAiDirectState ownAiDirectState(String account) => state;

  // v2 shell members (an `implements` double does not inherit the
  // ShellViewModel defaults).
  @override
  bool reduceMotion = false;
  @override
  Future<void> setReduceMotion(bool value) async {
    reduceMotion = value;
    notifyListeners();
  }

  @override
  bool get conversationsLoaded => true;
  @override
  String? get partnerConversationId {
    for (final ai in ownAiAccounts) {
      final id = ownAiDirectState(ai.accountId).conversationId;
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  @override
  Future<void> loadOwnAiDirectConsent(String account) async {
    loads++;
  }

  @override
  Future<void> sendMessage() async {
    sends++;
  }

  @override
  Future<void> setOwnAiDirectConsent(
    String account, {
    required String profileId,
    required int expectedRevision,
    required bool enabled,
    required Object interactionContext,
  }) async {
    mutations++;
    submitted = {
      'account': account,
      'profile': profileId,
      'revision': expectedRevision,
      'enabled': enabled,
      'context': interactionContext,
    };
    // Match runtime: one-shot interaction is consumed before loading notifies.
    epoch = Object();
    busy = true;
    state = const ShellOwnAiDirectState(phase: ShellOwnAiDirectPhase.loading);
    notifyListeners();
    await barrier?.future;
    busy = false;
    if (conflict) error = '授权版本已变化，请重新确认';
    state = uncertain
        ? const ShellOwnAiDirectState(
            phase: ShellOwnAiDirectPhase.uncertain,
            notice: '结果未确认',
          )
        : ShellOwnAiDirectState(
            phase: ShellOwnAiDirectPhase.ready,
            profileId: profileId,
            revision: expectedRevision + 1,
            enabled: enabled,
          );
    notifyListeners();
  }

  void grantReady({bool enabled = false}) {
    state = ShellOwnAiDirectState(
      phase: ShellOwnAiDirectPhase.ready,
      profileId: 'profile-id',
      revision: 7,
      enabled: enabled,
    );
  }
}

const _refresh = Key('own-ai-direct-refresh-ai-account');
const _toggle = Key('own-ai-direct-toggle-ai-account');
const _confirm = Key('own-ai-direct-confirm');

Future<void> _pump(
  WidgetTester tester,
  _Model model, {
  double width = 768,
  bool dark = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: ListenableBuilder(
        listenable: model,
        builder: (_, _) => Scaffold(
          body: SettingsScreen(model: model, onBack: () {}),
        ),
      ),
    ),
  );
  await tester.scrollUntilVisible(
    find.byKey(_refresh),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('existing Material ownAI row and consent fit width $width', (
      tester,
    ) async {
      final model = _Model()..grantReady();
      await _pump(tester, model, width: width);
      expect(find.text('ai-account'), findsOneWidget);
      expect(find.textContaining('Nora'), findsOneWidget);
      expect(find.byKey(const Key('own-ai-create')), findsOneWidget);
      await tester.tap(find.byKey(_toggle));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前单条文本'), findsOneWidget);
      expect(find.textContaining('历史、记忆'), findsOneWidget);
      expect(find.textContaining('已保存的人格'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(model.mutations, 0);
    });
  }
  testWidgets('dark narrow consent dialog has no overflow', (tester) async {
    final model = _Model()..grantReady();
    await _pump(tester, model, width: 375, dark: true);
    await tester.tap(find.byKey(_toggle));
    await tester.pumpAndSettle();
    expect(find.byKey(_confirm), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    '409 authoritative refresh is not mistaken for mutation success',
    (tester) async {
      final model = _Model()..grantReady();
      model.conflict = true;
      await _pump(tester, model);
      await tester.tap(find.byKey(_toggle));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_confirm));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byKey(_confirm), findsNothing);
      expect(model.mutations, 1);
    },
  );
  testWidgets(
    'lock while mutation awaits result hides details even after unlock',
    (tester) async {
      final model = _Model()..grantReady();
      model.barrier = Completer<void>();
      await _pump(tester, model);
      await tester.tap(find.byKey(_toggle));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_confirm));
      await tester.pump();
      model.locked = true;
      model.notifyListeners();
      model.locked = false;
      model.notifyListeners();
      model.barrier!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(_confirm), findsNothing);
      expect(find.text('授权操作已失效'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('profile-id'),
        ),
        findsNothing,
      );
      expect(model.mutations, 1);
    },
  );

  for (final change in ['rename', 'replace', 'disable', 'remove', 'session']) {
    testWidgets('submitted confirmation hides latched details after $change', (
      tester,
    ) async {
      final model = _Model()..grantReady();
      model.barrier = Completer<void>();
      await _pump(tester, model);
      await tester.tap(find.byKey(_toggle));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_confirm));
      await tester.pump();
      final originalRows = model.rows;
      final originalSession = model.session;
      if (change == 'session') {
        model.session = Object();
      } else if (change == 'remove') {
        model.rows = [];
      } else {
        model.rows = [
          ShellOwnedAi(
            accountId: change == 'replace' ? 'different-ai' : 'ai-account',
            displayName: change == 'rename' ? 'Changed name' : 'Nora',
            disabled: change == 'disable',
          ),
        ];
      }
      model.notifyListeners();
      // Reappearance before a frame/result must not revive the old confirmation.
      model.rows = originalRows;
      model.session = originalSession;
      model.notifyListeners();
      model.barrier!.complete();
      await tester.pumpAndSettle();
      expect(find.text('授权操作已失效'), findsOneWidget);
      expect(find.byKey(_confirm), findsNothing);
      for (final detail in ['profile-id', 'ai-account', 'Nora']) {
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining(detail),
          ),
          findsNothing,
        );
      }
      expect(model.mutations, 1);
      expect(model.sends, 0);
    });
  }

  testWidgets('unknown and uncertain are not off; refresh is GET-only', (
    tester,
  ) async {
    final model = _Model();
    await _pump(tester, model);
    expect(find.textContaining('尚未确认'), findsOneWidget);
    expect(find.byKey(_toggle), findsNothing);
    await tester.tap(find.byKey(_refresh));
    await tester.pump();
    expect(model.loads, 1);
    expect(model.mutations, 0);
    model.state = const ShellOwnAiDirectState(
      phase: ShellOwnAiDirectPhase.uncertain,
    );
    model.notifyListeners();
    await tester.pump();
    expect(find.textContaining('结果未确认'), findsOneWidget);
    expect(find.byKey(_toggle), findsNothing);
  });
  testWidgets('opening and cancelling never mutate or send', (tester) async {
    final model = _Model()..grantReady();
    await _pump(tester, model);
    await tester.tap(find.byKey(_toggle));
    await tester.pumpAndSettle();
    expect(model.mutations, 0);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(model.mutations, 0);
    expect(model.sends, 0);
  });
  testWidgets(
    'confirm captures account/profile/revision/context exactly once',
    (tester) async {
      final model = _Model()..grantReady();
      model.barrier = Completer<void>();
      await _pump(tester, model);
      await tester.tap(find.byKey(_toggle));
      await tester.pumpAndSettle();
      final captured = model.epoch;
      await tester.tap(find.byKey(_confirm));
      await tester.pump();
      await tester.tap(find.byKey(_confirm));
      await tester.pump();
      expect(model.mutations, 1);
      expect(model.submitted, {
        'account': 'ai-account',
        'profile': 'profile-id',
        'revision': 7,
        'enabled': true,
        'context': captured,
      });
      model.barrier!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(model.sends, 0);
    },
  );
  testWidgets('revoke discloses retaining history and needs confirmation', (
    tester,
  ) async {
    final model = _Model()..grantReady(enabled: true);
    await _pump(tester, model);
    await tester.tap(find.byKey(_toggle));
    await tester.pumpAndSettle();
    expect(find.textContaining('保留已有历史'), findsOneWidget);
    expect(model.mutations, 0);
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(model.submitted!['enabled'], isFalse);
    expect(model.mutations, 1);
  });
  for (final reason in ['offline', 'busy', 'disabled', 'loading']) {
    testWidgets('$reason denies refresh and mutation', (tester) async {
      final model = _Model()..grantReady();
      if (reason == 'offline') model.online = false;
      if (reason == 'busy') model.busy = true;
      if (reason == 'disabled') {
        model.rows = const [
          ShellOwnedAi(
            accountId: 'ai-account',
            displayName: 'Nora',
            disabled: true,
          ),
        ];
      }
      if (reason == 'loading') {
        model.state = const ShellOwnAiDirectState(
          phase: ShellOwnAiDirectPhase.loading,
        );
      }
      await _pump(tester, model);
      expect(tester.widget<TextButton>(find.byKey(_refresh)).onPressed, isNull);
      final toggle = find.byKey(_toggle);
      if (toggle.evaluate().isNotEmpty) {
        expect(tester.widget<TextButton>(toggle).onPressed, isNull);
      }
      expect(model.mutations, 0);
    });
  }
  for (final reason in [
    'lock-cycle',
    'logout',
    'context',
    'profile',
    'revision',
    'removed',
  ]) {
    testWidgets('dialog latches invalidation and hides details on $reason', (
      tester,
    ) async {
      final model = _Model()..grantReady();
      await _pump(tester, model);
      await tester.tap(find.byKey(_toggle));
      await tester.pumpAndSettle();
      if (reason == 'lock-cycle') {
        model.locked = true;
        model.notifyListeners();
        model.locked = false;
        model.notifyListeners();
      } else if (reason == 'logout') {
        model.connectedAccountId = null;
      } else if (reason == 'context') {
        model.epoch = Object();
      } else if (reason == 'removed') {
        model.rows = [];
      } else {
        model.state = ShellOwnAiDirectState(
          phase: ShellOwnAiDirectPhase.ready,
          profileId: reason == 'profile' ? 'changed' : 'profile-id',
          revision: reason == 'revision' ? 8 : 7,
          enabled: false,
        );
      }
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(_confirm), findsNothing);
      final dialog = find.byType(AlertDialog);
      expect(
        find.descendant(
          of: dialog,
          matching: find.textContaining('profile-id'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.textContaining('ai-account'),
        ),
        findsNothing,
      );
      expect(model.mutations, 0);
    });
  }
  testWidgets('uncertain mutation result never permits an automatic retry', (
    tester,
  ) async {
    final model = _Model()..grantReady();
    model.uncertain = true;
    await _pump(tester, model);
    await tester.tap(find.byKey(_toggle));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(model.mutations, 1);
    expect(find.byKey(_confirm), findsNothing);
    expect(find.textContaining('请关闭后刷新状态'), findsOneWidget);
    expect(model.sends, 0);
  });
}
