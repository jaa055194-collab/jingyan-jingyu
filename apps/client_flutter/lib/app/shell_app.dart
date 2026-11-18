import 'package:material_ui/material_ui.dart';

import '../net/creative_api.dart';
import '../net/host_connection.dart';
import '../net/notification_api.dart';
import 'runtime.dart';
import 'shell_view_model.dart';
import 'module_catalog.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/chat/chat_pane.dart';
import '../features/settings/settings_screen.dart';
import '../features/world/world_screen.dart';
import '../features/contacts/contacts_screen.dart';
import '../net/friends_api.dart';
import '../features/inbox/inbox_screen.dart';
import '../features/creative/creative_screen.dart';

class WhaleChatApp extends StatefulWidget {
  const WhaleChatApp({super.key, required this.model});
  final ShellViewModel model;

  @override
  State<WhaleChatApp> createState() => _WhaleChatAppState();
}

class _WhaleChatAppState extends State<WhaleChatApp> {
  final _navigation = _NavigationIntentObserver();
  ShellViewModel get model => widget.model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => MaterialApp(
      title: '鲸言鲸语',
      navigatorObservers: [_navigation],
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff16776e)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff16776e),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: model.themeMode,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(
            MediaQuery.textScalerOf(context).scale(1) * model.fontScale,
          ),
        ),
        child: child!,
      ),
      home: !model.ready
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : model.locked
          ? UnlockScreen(model: model)
          : !model.onboarded && !(model.authenticated && model.chatEntered)
          ? OnboardingScreen(
              model: model,
              initialStep: model.authenticated ? 1 : 0,
            )
          : _ShellHome(model: model, navigation: _navigation),
    ),
  );
}

// Observes route intent without altering any push, pop, or back behavior. A
// generation tracks transient dialogs/pages even if the source is current again.
class _NavigationIntentObserver extends NavigatorObserver {
  int generation = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      generation++;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      generation++;
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      generation++;
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      generation++;
  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) => generation++;
}

class _ShellHome extends StatefulWidget {
  const _ShellHome({required this.model, required this.navigation});
  final ShellViewModel model;
  final _NavigationIntentObserver navigation;
  @override
  State<_ShellHome> createState() => _ShellHomeState();
}

class _ShellHomeState extends State<_ShellHome> {
  int destination = 0;
  bool settings = false;
  bool mobileChat = false;
  static const labels = ['聊天', '联系人', '动态', '收件箱', '世界'];
  static const icons = [
    Icons.chat_bubble_outline,
    Icons.people_outline,
    Icons.photo_library_outlined,
    Icons.inbox_outlined,
    Icons.public,
  ];
  void select(String id) async {
    await widget.model.selectConversation(id);
    if (mounted && widget.model.selectedConversationId == id) {
      setState(() => mobileChat = true);
    }
  }

  String? _openingOwnAiAccount;

  Future<void> openOwnAiChat(BuildContext source, String accountId) async {
    final route = ModalRoute.of(source);
    final navigation = widget.navigation;
    final intent = navigation.generation;
    final model = widget.model;
    final owner = model.connectedAccountId;
    final session = model.ownAiSessionContext;
    final epoch = model.ownAiDirectContext;
    final initial = model.ownAiDirectState(accountId);
    final id = initial.conversationId;
    if (_openingOwnAiAccount != null ||
        route == null ||
        !route.isCurrent ||
        owner == null ||
        session == null ||
        epoch == null ||
        initial.phase != ShellOwnAiDirectPhase.ready ||
        initial.enabled != true ||
        initial.profileId?.isNotEmpty != true ||
        initial.revision == null ||
        id == null ||
        id.isEmpty) {
      return;
    }

    bool current() {
      if (!mounted ||
          !source.mounted ||
          !route.isCurrent ||
          navigation.generation != intent ||
          !settings ||
          !identical(widget.model, model) ||
          !model.authenticated ||
          model.locked ||
          model.connectedAccountId != owner ||
          model.ownAiSessionContext != session ||
          !identical(model.ownAiDirectContext, epoch) ||
          !model.ownAiAccounts.any(
            (ai) => ai.accountId == accountId && !ai.disabled,
          )) {
        return false;
      }
      final state = model.ownAiDirectState(accountId);
      return state.phase == ShellOwnAiDirectPhase.ready &&
          state.enabled == true &&
          state.profileId == initial.profileId &&
          state.revision == initial.revision &&
          state.conversationId == id;
    }

    if (!current() || !model.online) return;
    setState(() => _openingOwnAiAccount = accountId);
    try {
      final result = await model.checkOwnAiChatEntry(accountId);
      if (!mounted || !current() || result == OwnAiChatEntry.cancelled) return;
      final notice = switch (result) {
        OwnAiChatEntry.busy => '正在更新会话，请稍后再试。',
        OwnAiChatEntry.unavailable => '暂时无法核对私聊，请检查连接或登录状态后再试。',
        OwnAiChatEntry.notVisible => '此私聊在当前会话列表中不可见。',
        OwnAiChatEntry.consentChanged => '宿主的私聊授权已变化，未打开会话。',
        OwnAiChatEntry.ready || OwnAiChatEntry.cancelled => null,
      };
      if (notice != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(notice)));
        return;
      }
      if (model.busy ||
          !model.online ||
          !model.conversations.any((c) => c.id == id && c.kind == 'direct')) {
        return;
      }
      await model.selectConversation(id);
      if (current() &&
          !model.busy &&
          model.online &&
          model.selectedConversationId == id) {
        setState(() {
          destination = 0;
          settings = false;
          mobileChat = true;
        });
      }
    } finally {
      if (mounted) setState(() => _openingOwnAiAccount = null);
    }
  }

  void openWorldSetup() {
    final model = widget.model;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => ListenableBuilder(
          listenable: model,
          builder: (_, _) {
            if (!model.ready) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (model.locked) return UnlockScreen(model: model);
            if (!model.authenticated) {
              return OnboardingScreen(
                key: const ValueKey('route-login'),
                model: model,
              );
            }
            return OnboardingScreen(
              key: const ValueKey('route-world-setup'),
              model: model,
              initialStep: 1,
              onClose: () => Navigator.of(routeContext).pop(),
            );
          },
        ),
      ),
    );
  }

  Widget world() =>
      WorldScreen(model: widget.model, onOpenSetup: openWorldSetup);

  /// Host-backed read-only creative loaders only when the runtime exposes a live
  /// connection; otherwise the screen keeps its honest unbound/unknown state.
  /// The shell only wires loaders here — tab layout and settings are untouched.
  Widget creative() {
    final model = widget.model;
    final HostConnection? connection = model is ClientRuntime
        ? model.connection
        : null;
    if (connection == null) return const CreativeScreen();
    final api = CreativeApi(connection);
    return CreativeScreen(
      loadReports: api.listReports,
      loadRadio: api.listRadio,
    );
  }

  /// Wire the contacts list and explicit invite actions only when the runtime
  /// has a host connection. The screen never submits an action on load.
  Widget contacts() {
    final model = widget.model;
    final HostConnection? connection = model is ClientRuntime
        ? model.connection
        : null;
    if (connection == null) return const ContactsScreen();
    final api = FriendsApi(connection);
    return ContactsScreen(
      loadFriends: api.list,
      acceptFriend: api.acceptFriend,
      denyFriend: api.denyFriend,
    );
  }

  /// Host-backed read-only notifications loader with the same semantics as
  /// [creative]: wire [NotificationApi.readNotifications] only when the runtime
  /// exposes a live connection; otherwise the inbox keeps its honest gap state.
  /// The shell only wires loaders here — tab layout and settings are untouched.
  Widget inbox() {
    final model = widget.model;
    final HostConnection? connection = model is ClientRuntime
        ? model.connection
        : null;
    if (connection == null) return const InboxScreen();
    final api = NotificationApi(connection);
    return InboxScreen(loadNotifications: () => api.readNotifications());
  }

  Widget empty() {
    const titles = ['', '暂无联系人', '暂无动态', '暂无通知', '世界尚未开放'];
    const details = [
      '',
      '宿主尚未提供联系人数据。',
      '宿主尚未提供动态内容。',
      '新的邀请和通知将在这里显示。',
      '宿主接入世界服务后可在这里进入。',
    ];
    const moduleIds = {1: 'contacts', 2: 'moments', 3: 'inbox'};
    final module = findModule(moduleIds[destination] ?? '');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icons[destination], size: 40),
            const SizedBox(height: 16),
            Text(
              titles[destination],
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(details[destination], textAlign: TextAlign.center),
            if (module != null) ...[
              const SizedBox(height: 12),
              Chip(
                key: Key('module-status-${module.id}'),
                label: Text('模块状态：${module.availabilityLabel}'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 720;
      final model = widget.model;
      final showChat = destination == 0 && mobileChat && !settings;
      final content = settings
          ? SettingsScreen(
              model: model,
              onBack: () => setState(() {
                widget.navigation.generation++;
                settings = false;
              }),
              onOpenOwnAiChat: openOwnAiChat,
              checkingOwnAiAccount: _openingOwnAiAccount,
            )
          : destination == 4
          ? world()
          : destination == 1
          ? contacts()
          : destination == 2
          ? creative()
          : destination == 3
          ? inbox()
          : destination != 0
          ? empty()
          : wide
          ? Row(
              children: [
                SizedBox(
                  width: 280,
                  child: ConversationList(model: model, onSelected: select),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: ChatPane(model: model)),
              ],
            )
          : showChat
          ? ChatPane(
              model: model,
              onBack: () => setState(() => mobileChat = false),
            )
          : ConversationList(model: model, onSelected: select);
      return Scaffold(
        appBar: AppBar(
          title: Text(settings ? '鲸言鲸语' : labels[destination]),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: Text(
                  model.online ? '在线' : '离线',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ),
            IconButton(
              tooltip: '设置',
              onPressed: () => setState(() {
                widget.navigation.generation++;
                settings = !settings;
              }),
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        body: SafeArea(
          child: Row(
            children: [
              if (wide)
                NavigationRail(
                  labelType: NavigationRailLabelType.all,
                  selectedIndex: destination,
                  onDestinationSelected: (value) => setState(() {
                    widget.navigation.generation++;
                    destination = value;
                    settings = false;
                  }),
                  destinations: [
                    for (var i = 0; i < labels.length; i++)
                      NavigationRailDestination(
                        icon: Icon(icons[i]),
                        label: Text(labels[i]),
                      ),
                  ],
                ),
              if (wide) const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    if (model.busy) const LinearProgressIndicator(),
                    if (model.error != null)
                      Material(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Semantics(
                                  liveRegion: true,
                                  child: Text(model.error!),
                                ),
                              ),
                              IconButton(
                                tooltip: '关闭提示',
                                onPressed: model.clearError,
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Expanded(child: content),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: wide || showChat || settings
            ? null
            : NavigationBar(
                selectedIndex: destination,
                onDestinationSelected: (value) => setState(() {
                  widget.navigation.generation++;
                  destination = value;
                  mobileChat = false;
                }),
                destinations: [
                  for (var i = 0; i < labels.length; i++)
                    NavigationDestination(
                      icon: Icon(icons[i]),
                      label: labels[i],
                    ),
                ],
              ),
      );
    },
  );
}
