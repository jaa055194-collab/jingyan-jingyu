import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';

import '../ui/jy_motion.dart';
import '../ui/jy_dock.dart';
import '../ui/jy_presence.dart';
import '../ui/jy_surfaces.dart';
import '../ui/jy_tokens.dart';
import '../net/creative_api.dart';
import '../net/host_connection.dart';
import '../net/notification_api.dart';
import 'runtime.dart';
import 'shell_view_model.dart';
import 'module_catalog.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/chat/chat_pane.dart';
import '../features/settings/settings_screen.dart';
import '../features/world/street3d_android_surface.dart';
import '../features/world/street3d_screen.dart';
import '../features/world/street3d_source.dart';
import '../features/world/world_screen.dart';
import '../features/contacts/contacts_screen.dart';
import '../net/friends_api.dart';
import '../features/inbox/foreground_message_notice.dart';
import '../features/inbox/inbox_screen.dart';
import '../features/creative/creative_screen.dart';
import '../features/share/shared_text_panel.dart';
import 'app_theme.dart';

class WhaleChatApp extends StatefulWidget {
  const WhaleChatApp({super.key, required this.model});
  final ShellViewModel model;

  @override
  State<WhaleChatApp> createState() => _WhaleChatAppState();
}

class _WhaleChatAppState extends State<WhaleChatApp> {
  // Built once and shared: the shell rebuilds on every model notification.
  static final _lightTheme = buildAppTheme(Brightness.light);
  static final _darkTheme = buildAppTheme(Brightness.dark);
  final _navigation = _NavigationIntentObserver();
  ShellViewModel get model => widget.model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => MaterialApp(
      title: '鲸言鲸语',
      navigatorObservers: [_navigation],
      debugShowCheckedModeBanner: false,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: model.themeMode,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(
            MediaQuery.textScalerOf(context).scale(1) * model.fontScale,
          ),
          disableAnimations:
              MediaQuery.maybeDisableAnimationsOf(context) == true ||
              model.reduceMotion,
        ),
        // Above the Navigator, so routes, dialogs and sheets also see it.
        child: JyMotionScope(reduce: model.reduceMotion, child: child!),
      ),
      home: !model.ready
          ? const ShellSplash()
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
/// Shown while the app starts: the companion's light core breathes above the
/// app name (MASTER.md section 7). With reduced motion the core is still.
class ShellSplash extends StatelessWidget {
  /// Creates the start-up screen.
  const ShellSplash({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Semantics(
        label: '正在启动鲸言鲸语',
        liveRegion: true,
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const JyPresenceOrb(size: 72, state: JyPresence.thinking),
              const SizedBox(height: 20),
              Text('鲸言鲸语', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
      ),
    ),
  );
}

class _NavigationIntentObserver extends NavigatorObserver with ChangeNotifier {
  int generation = 0;

  void advance() {
    generation++;
    notifyListeners();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      advance();
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => advance();
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      advance();
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      advance();
  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) => advance();
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
  int _chatOpenRevision = 0;
  static const labels = ['聊天', '联系人', '动态', '收件箱', '世界'];
  static const icons = [
    Icons.chat_bubble_outline,
    Icons.people_outline,
    Icons.photo_library_outlined,
    Icons.inbox_outlined,
    Icons.public,
  ];
  static const iconsSelected = [
    Icons.chat_bubble,
    Icons.people,
    Icons.photo_library,
    Icons.inbox,
    Icons.public,
  ];
  void select(String id) async {
    final model = widget.model;
    final account = model.connectedAccountId;
    final session = model.ownAiSessionContext;
    await model.selectConversation(id);
    if (mounted &&
        identical(widget.model, model) &&
        model.connectedAccountId == account &&
        model.ownAiSessionContext == session &&
        model.selectedConversationId == id) {
      setState(() {
        mobileChat = true;
        _chatOpenRevision++;
      });
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
            if (!model.ready) return const ShellSplash();
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

  /// The 3D street opens above the shell, so it follows the session itself:
  /// the unlock screen covers it while the app is locked, and another
  /// signed-in account or connection gets a new street.
  void openStreet3D() {
    final model = widget.model;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ListenableBuilder(
          listenable: model,
          builder: (_, _) {
            if (!model.ready) return const ShellSplash();
            if (model.locked) return UnlockScreen(model: model);
            final connection = model is ClientRuntime ? model.connection : null;
            final selfId = model.connectedAccountId;
            return Street3DScreen(
              key: ValueKey((connection, selfId)),
              source: connection == null || selfId == null
                  ? null
                  : HostStreet3DDataSource.connected(
                      connection,
                      selfId: selfId,
                      ownAis: model.ownAiAccounts,
                    ),
              surfaceBuilder: defaultTargetPlatform == TargetPlatform.android
                  ? Street3DAndroidSurface.build
                  : null,
            );
          },
        ),
      ),
    );
  }

  Widget world() => WorldScreen(
    model: widget.model,
    onOpenSetup: openWorldSetup,
    onOpenStreet: openStreet3D,
  );

  /// Report data stays inside the authenticated session that opened 动态.
  /// Expanding a row reuses the authorized list payload, not another request.
  Widget creative() {
    final model = widget.model;
    if (model is! ClientRuntime) return const CreativeScreen();
    final connection = model.connection;
    if (connection == null) return const CreativeScreen();
    final api = CreativeApi(connection);
    return CreativeScreen(
      loadReports: api.listReports,
      loadRadio: api.listRadio,
      sessionChanges: model,
      sessionContext: () {
        final epoch = model.ownAiSessionContext;
        if (!model.authenticated ||
            model.locked ||
            epoch == null ||
            !identical(model.connection, connection)) {
          return null;
        }
        return (model.connectedAccountId, epoch, connection);
      },
    );
  }

  /// Wire the existing Contacts reads and writes to the live connection.
  Widget contacts() {
    final model = widget.model;
    if (model is! ClientRuntime) return const ContactsScreen();
    final connection = model.connection;
    if (connection == null) return const ContactsScreen();
    final api = FriendsApi(connection);
    final owner = model.connectedAccountId;
    final session = model.ownAiSessionContext;
    final navigation = widget.navigation;

    ({String accountId, Object session})? requestContext() {
      // Use the existing explicit-confirmation epoch so even a lock followed
      // by an unlock of the same account invalidates an older confirmation.
      final lockEpoch = model.ownAiDirectContext;
      if (!mounted ||
          !identical(widget.model, model) ||
          destination != 1 ||
          settings ||
          !model.authenticated ||
          model.locked ||
          owner == null ||
          model.connectedAccountId != owner ||
          session == null ||
          model.ownAiSessionContext != session ||
          lockEpoch == null ||
          !identical(model.connection, connection)) {
        return null;
      }
      return (
        accountId: owner,
        session: (model, connection, session, lockEpoch),
      );
    }

    return ContactsScreen(
      key: ValueKey((model, connection, owner, session)),
      loadFriends: api.list,
      acceptFriend: api.acceptFriend,
      denyFriend: api.denyFriend,
      requestFriend: requestContext() == null ? null : api.requestFriend,
      requestContext: requestContext,
      requestChanges: Listenable.merge([model, navigation]),
      navigationGeneration: () => navigation.generation,
    );
  }

  /// Host-backed notifications loader with the same semantics as [creative]:
  /// wire [NotificationApi.readNotifications] only when the runtime exposes a
  /// live connection; otherwise the inbox keeps its honest gap state.
  ///
  /// Pending friend-request rows additionally reuse the existing
  /// [FriendsApi.acceptFriend]/[FriendsApi.denyFriend] writes — the same
  /// transport the contacts tab uses, never a second one — and only while the
  /// runtime reports an authenticated, unlocked session. The epoch is the
  /// runtime-issued session/lock identity: it becomes null on lock or logout and
  /// changes on an account switch, so a pending confirmation or an in-flight
  /// result is discarded instead of being published as a stale success. The
  /// shell only wires these callbacks; tab layout and settings are untouched.
  Widget inbox() {
    final model = widget.model;
    final HostConnection? connection = model is ClientRuntime
        ? model.connection
        : null;
    if (connection == null) return const InboxScreen();
    final notifications = NotificationApi(connection);
    final friends = FriendsApi(connection);
    Object? actionContext() => model.authenticated && !model.locked
        ? '${model.connectedAccountId}|${model.ownAiSessionContext}'
        : null;
    return InboxScreen(
      key: ObjectKey(connection),
      loadNotifications: () => notifications.readNotifications(),
      acceptFriend: friends.acceptFriend,
      denyFriend: friends.denyFriend,
      actionContext: actionContext,
      actionChanges: model,
    );
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

  int? _noticeViewGeneration() =>
      mounted && !settings && (destination == 1 || destination == 3)
      ? widget.navigation.generation
      : null;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 720;
      final model = widget.model;
      final activity = model.foregroundMessageActivity;
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
          // Wide: the conversation list and the chat are separate boards
          // with a 12dp gap that shows the canvas (MASTER.md section 9).
          ? Padding(
              padding: const EdgeInsets.fromLTRB(
                0,
                JySpace.md,
                JySpace.md,
                JySpace.md,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 320,
                    child: JySlab(
                      key: const Key('shell-list-board'),
                      padding: EdgeInsets.zero,
                      child: ConversationList(model: model, onSelected: select),
                    ),
                  ),
                  const SizedBox(width: JySpace.md),
                  Expanded(
                    child: JySlab(
                      key: const Key('shell-chat-board'),
                      padding: EdgeInsets.zero,
                      child: ChatPane(
                        model: model,
                        openRevision: _chatOpenRevision,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : showChat
          ? ChatPane(
              model: model,
              openRevision: _chatOpenRevision,
              onBack: () => setState(() => mobileChat = false),
            )
          : ConversationList(model: model, onSelected: select);
      // System back steps out of the shell's own levels before leaving the
      // app: settings, then an open narrow-screen chat, then a non-home tab.
      final backToChat = showChat && !wide;
      final canLeave = !settings && !backToChat && destination == 0;
      return PopScope(
        canPop: canLeave,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop || !mounted) return;
          setState(() {
            widget.navigation.generation++;
            if (settings) {
              settings = false;
            } else if (backToChat) {
              mobileChat = false;
            } else {
              destination = 0;
            }
          });
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(settings ? '鲸言鲸语' : labels[destination]),
            actions: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      JyStatusDot(online: model.online),
                      const SizedBox(width: 6),
                      Text(
                        model.online ? '在线' : '离线',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ],
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
                  Padding(
                    padding: const EdgeInsets.all(JySpace.md),
                    child: JySlab(
                      key: const Key('shell-nav-board'),
                      padding: EdgeInsets.zero,
                      child: NavigationRail(
                        backgroundColor: Colors.transparent,
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
                              selectedIcon: Icon(iconsSelected[i]),
                              label: Text(labels[i]),
                            ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: Column(
                    children: [
                      if (model.authenticated && !model.locked)
                        SharedTextPanel(
                          model: model,
                          navigationGeneration: () =>
                              widget.navigation.generation,
                          navigationChanges: widget.navigation,
                          onApplied: () async {
                            if (!mounted ||
                                !model.authenticated ||
                                model.locked) {
                              return;
                            }
                            setState(() {
                              destination = 0;
                              settings = false;
                              if (!wide) mobileChat = true;
                              _chatOpenRevision++;
                            });
                          },
                        ),
                      if (model.busy)
                        const JyBusyIndicator(label: '正在处理', linear: true),
                      if (model.error != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            JySpace.lg,
                            JySpace.sm,
                            JySpace.lg,
                            0,
                          ),
                          child: JyBanner(
                            message: model.error!,
                            onClose: model.clearError,
                          ),
                        ),
                      if (activity != null &&
                          model.authenticated &&
                          !model.locked &&
                          _noticeViewGeneration() != null)
                        ForegroundMessageNotice(
                          key: ValueKey(destination),
                          model: model,
                          activity: activity,
                          navigation: widget.navigation,
                          activeViewGeneration: _noticeViewGeneration,
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
              : JyDock(
                  selectedIndex: destination,
                  onSelected: (value) => setState(() {
                    widget.navigation.generation++;
                    destination = value;
                    mobileChat = false;
                  }),
                  items: [
                    for (var i = 0; i < labels.length; i++)
                      JyDockItem(
                        icon: icons[i],
                        selectedIcon: iconsSelected[i],
                        label: labels[i],
                      ),
                  ],
                ),
        ),
      );
    },
  );
}
