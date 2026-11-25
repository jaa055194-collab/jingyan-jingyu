import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/settings/android_ai_directory_screen.dart';
import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Connection extends HostConnection {
  _Connection() : super(Uri.parse('http://fixture.invalid'), 'test-token');
}

class _Runtime extends ClientRuntime {
  _Runtime(_Connection host) {
    connection = host;
  }

  var interaction = Object();
  final created = <String>[];
  final removed = <String>[];
  bool onlineValue = true;
  bool lockedValue = false;

  @override
  bool get locked => lockedValue;

  void setLocked(bool value) {
    lockedValue = value;
    notifyListeners();
  }

  @override
  String get connectedAccountId => 'test-owner';
  @override
  Object get ownAiSessionContext => 1;
  @override
  Object get ownAiDirectContext => interaction;
  @override
  bool get online => onlineValue;
  @override
  bool get ownAiLoaded => true;
  @override
  String? get ownAiNotice => null;
  @override
  List<ShellOwnedAi> get ownAiAccounts => const [
    ShellOwnedAi(accountId: 'ai-a', displayName: 'Nora', disabled: false),
    ShellOwnedAi(accountId: 'ai-b', displayName: 'Jo', disabled: false),
    ShellOwnedAi(accountId: 'ai-c', displayName: 'Lin', disabled: true),
  ];
  @override
  Future<void> createOwnAi(String name) async => created.add(name);
  @override
  Future<void> removeOwnAi(String accountId) async => removed.add(accountId);
}

Future<void> _open(
  WidgetTester tester,
  _Runtime runtime,
  TargetPlatform platform,
) async {
  addTearDown(runtime.dispose);
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(375, 812);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SettingsScreen(model: runtime, onBack: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _to(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Android directory opens once and hides disabled AI actions', (
    tester,
  ) async {
    final runtime = _Runtime(_Connection());
    await _open(tester, runtime, TargetPlatform.android);
    final entry = find.byKey(const Key('open-android-ai-directory'));
    await _to(tester, entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(AndroidAiDirectoryScreen), findsOneWidget);
    expect(find.text('Lin'), findsOneWidget);
    expect(
      find.byKey(const Key('android-ai-open-config-ai-c')),
      findsNothing,
      reason: 'a disabled AI has no actionable rows',
    );
  });

  testWidgets('directory exposes private chat separately from host config', (
    tester,
  ) async {
    final runtime = _Runtime(_Connection());
    addTearDown(runtime.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 812);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AndroidAiDirectoryScreen(
          model: runtime,
          onOpenAi: (ai, _) => opened.add('config:${ai.accountId}'),
          onOpenPrivateChat: (ai, _) => opened.add('chat:${ai.accountId}'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _to(tester, find.byKey(const Key('android-ai-open-chat-ai-b')));
    await tester.tap(find.byKey(const Key('android-ai-open-chat-ai-b')));
    await tester.tap(find.byKey(const Key('android-ai-open-config-ai-a')));
    await tester.pumpAndSettle();
    expect(opened, ['chat:ai-b', 'config:ai-a']);
  });

  testWidgets('offline directory keeps local chat but disables host config', (
    tester,
  ) async {
    final runtime = _Runtime(_Connection())..onlineValue = false;
    addTearDown(runtime.dispose);
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AndroidAiDirectoryScreen(
          model: runtime,
          onOpenAi: (ai, _) => opened.add('config:${ai.accountId}'),
          onOpenPrivateChat: (ai, _) => opened.add('chat:${ai.accountId}'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final config = find.byKey(const Key('android-ai-open-config-ai-a'));
    expect(tester.widget<ListTile>(config).onTap, isNull);
    final chat = find.byKey(const Key('android-ai-open-chat-ai-a'));
    expect(tester.widget<ListTile>(chat).onTap, isNotNull);
    await tester.ensureVisible(chat);
    await tester.pumpAndSettle();
    await tester.tap(chat);
    await tester.pumpAndSettle();
    expect(opened, ['chat:ai-a']);
  });

  testWidgets('create validates a blank name and only sends a valid one', (
    tester,
  ) async {
    final runtime = _Runtime(_Connection());
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AndroidAiDirectoryScreen(model: runtime, onOpenAi: (_, _) {}),
      ),
    );
    await tester.pumpAndSettle();
    final create = find.byKey(const Key('android-ai-directory-create'));
    await _to(tester, create);
    await tester.tap(create);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-ai-create-confirm')));
    await tester.pumpAndSettle();
    expect(runtime.created, isEmpty);
    expect(find.text('名称须为 1–100 个字符'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('android-ai-create-name')),
      '新伙伴',
    );
    await tester.tap(find.byKey(const Key('android-ai-create-confirm')));
    await tester.pumpAndSettle();
    expect(runtime.created, ['新伙伴']);
  });

  testWidgets('removal requires confirmation and explains retained history', (
    tester,
  ) async {
    final runtime = _Runtime(_Connection());
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AndroidAiDirectoryScreen(model: runtime, onOpenAi: (_, _) {}),
      ),
    );
    await tester.pumpAndSettle();
    final remove = find.byKey(const Key('android-ai-remove-ai-a'));
    expect(remove, findsOneWidget);
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(find.textContaining('不会删除服务器上已有的聊天记录'), findsOneWidget);
    expect(runtime.removed, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(runtime.removed, isEmpty);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-ai-remove-confirm')));
    await tester.pumpAndSettle();
    expect(runtime.removed, ['ai-a']);
  });

  testWidgets(
    'lock invalidates an open removal confirmation and hides AI names',
    (tester) async {
      final runtime = _Runtime(_Connection());
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AndroidAiDirectoryScreen(model: runtime, onOpenAi: (_, _) {}),
        ),
      );
      await tester.pumpAndSettle();
      final remove = find.byKey(const Key('android-ai-remove-ai-a'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      final confirm = find.byKey(const Key('android-ai-remove-confirm'));
      expect(confirm, findsOneWidget);
      runtime.setLocked(true);
      runtime.setLocked(false);
      await tester.pumpAndSettle();
      expect(confirm, findsNothing);
      expect(find.textContaining('Nora'), findsNothing);
      expect(runtime.removed, isEmpty);
    },
  );

  testWidgets('desktop Settings has no Android directory entry', (
    tester,
  ) async {
    await _open(tester, _Runtime(_Connection()), TargetPlatform.windows);
    expect(find.byKey(const Key('open-android-ai-directory')), findsNothing);
    expect(find.text('Nora · 未停用'), findsNothing);
  });
}
