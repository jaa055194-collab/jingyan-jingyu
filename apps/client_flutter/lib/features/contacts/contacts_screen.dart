import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/friends_api.dart';
import '../../net/host_connection.dart';
import '../../app/status_panel.dart';
import '../../ui/ui.dart';

/// Contacts surface.
///
/// When a [loadFriends] loader is injected it GETs the host friend list and
/// renders it, reporting loading/empty/denied/unknown honestly. Without a
/// loader the screen keeps the original honest empty state instead of
/// fabricating contacts. A read-only per-account lookup ([lookupState]) remains
/// available. Incoming pending invitations can be explicitly accepted/denied
/// only when [acceptFriend]/[denyFriend] are wired; every action is
/// user-triggered, refreshes the list afterwards and reports failures honestly.
/// Outgoing requests require a known account ID and a separate confirmation.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({
    super.key,
    this.lookupState,
    this.loadFriends,
    this.acceptFriend,
    this.denyFriend,
    this.requestFriend,
    this.requestContext,
    this.requestChanges,
    this.navigationGeneration,
  });

  final Future<FriendState> Function(String accountId)? lookupState;
  final Future<List<FriendContact>> Function()? loadFriends;
  final Future<void> Function(String accountId)? acceptFriend;
  final Future<void> Function(String accountId)? denyFriend;
  final Future<void> Function(String accountId)? requestFriend;

  /// Live signed-in identity and session/lock scope (null when unavailable).
  final ({String accountId, Object session})? Function()? requestContext;

  /// Notifies on either session or navigation changes.
  final Listenable? requestChanges;
  final int Function()? navigationGeneration;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _account = TextEditingController();
  final _requestAccount = TextEditingController();
  bool _requestActive = false;
  bool _requestSending = false;
  String? _requestIdError;
  ({String text, Object scope, bool ok})? _requestResult;
  String? _result;
  bool _busy = false;
  List<FriendContact>? _friends;
  bool _loadingFriends = false;
  String? _friendsMessage;

  /// Whether [_friendsMessage] reports a failed invitation action rather
  /// than a failed read. It only picks the panel title.
  bool _friendsActionFailed = false;
  String? _friendActionBusy;

  /// Whether the deck of incoming requests is open; kept across reloads.
  bool _requestsExpanded = false;

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  @override
  void dispose() {
    _account.dispose();
    _requestAccount.dispose();
    super.dispose();
  }

  Future<void> _loadFriends() async {
    final load = widget.loadFriends;
    if (load == null) return;
    setState(() {
      _loadingFriends = true;
      _friendsMessage = null;
    });
    try {
      final contacts = await load();
      if (!mounted) return;
      setState(() {
        _friends = contacts;
        _friendsMessage = null;
        _loadingFriends = false;
      });
    } catch (error) {
      if (!mounted) return;
      final denied =
          error is HostRequestException &&
          (error.failure.code == FailureCode.forbidden ||
              error.failure.code == FailureCode.unauthenticated);
      setState(() {
        _friends = null;
        _friendsActionFailed = false;
        _friendsMessage = denied
            ? '未认证或无权限读取好友列表；不会自动重试'
            : '好友列表读取失败或结果未知；不会自动重试';
        _loadingFriends = false;
      });
    }
  }

  static String _label(FriendState state) => switch (state) {
    FriendState.none => '未添加',
    FriendState.outgoingPending => '已发出请求，待对方确认',
    FriendState.incomingPending => '对方请求添加你',
    FriendState.friends => '好友',
    FriendState.blocked => '已拉黑/被拉黑',
  };

  Future<void> _lookup() async {
    final lookup = widget.lookupState;
    final id = _account.text.trim();
    if (lookup == null || id.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final state = await lookup(id);
      if (!mounted) return;
      setState(() => _result = '关系状态：${_label(state)}');
    } catch (_) {
      // Never surface upstream/response material.
      if (!mounted) return;
      setState(() => _result = '查询失败，请稍后重试；不会自动重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _respondFriend(
    FriendContact contact, {
    required bool accept,
  }) async {
    final action = accept ? widget.acceptFriend : widget.denyFriend;
    if (action == null || _friendActionBusy != null || _requestActive) return;
    setState(() => _friendActionBusy = contact.accountId);
    try {
      await action(contact.accountId);
      if (!mounted) return;
      setState(() {
        _friendActionBusy = null;
        _friendsMessage = null;
      });
      await _loadFriends();
    } catch (error) {
      if (!mounted) return;
      final denied =
          error is HostRequestException &&
          (error.failure.code == FailureCode.forbidden ||
              error.failure.code == FailureCode.unauthenticated);
      setState(() {
        _friendActionBusy = null;
        _friendsActionFailed = true;
        _friendsMessage = denied
            ? '未认证或无权限处理邀请；不会自动重试'
            : error is FormatException
            ? '好友操作响应无效；不会自动重试'
            : '好友操作失败或结果未知；不会自动重试';
      });
    }
  }

  Future<void> _reviewRequest() async {
    final send = widget.requestFriend;
    final scope = widget.requestContext?.call();
    final navigationGeneration = widget.navigationGeneration;
    final source = ModalRoute.of(context);
    if (send == null ||
        scope == null ||
        source?.isCurrent != true ||
        _requestActive ||
        _friendActionBusy != null) {
      return;
    }
    final String target;
    try {
      target = AccountId.parse(_requestAccount.text).value;
    } on FormatException {
      setState(() => _requestIdError = '请输入有效账号 ID（1–64 位字母、数字、下划线或连字符）。');
      return;
    }
    if (target == scope.accountId) {
      setState(() => _requestIdError = '不能向当前账号发送好友请求。');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _requestActive = true;
      _requestResult = null;
    });
    final changes = widget.requestChanges;
    final navigator = Navigator.of(context, rootNavigator: true);
    var invalidated = false;
    var confirming = true;
    var confirmedInDialog = false;
    final openedAt = navigationGeneration?.call();
    final dialogAt = openedAt == null ? null : openedAt + 1;
    final returnedAt = openedAt == null ? null : openedAt + 2;
    late final JyDialogRoute<bool> dialog;

    bool sameSession() => mounted && widget.requestContext?.call() == scope;
    bool currentSource() =>
        sameSession() &&
        source!.isCurrent &&
        navigationGeneration?.call() == returnedAt;

    void invalidate() {
      if (invalidated) return;
      invalidated = true;
      if (confirming) {
        scheduleMicrotask(() {
          // Remove only this confirmation, not whatever route is above it.
          if (navigator.mounted && dialog.isActive) {
            navigator.removeRoute(dialog, false);
          }
        });
      }
    }

    void onChange() {
      if (!sameSession()) {
        invalidate();
        return;
      }
      final generation = navigationGeneration?.call();
      if (confirming) {
        // Only our confirm button's pop may advance the generation back to
        // the source. A push above this dialog can also increment it once.
        final returning =
            confirmedInDialog && generation == returnedAt && source!.isCurrent;
        if (generation != dialogAt && !returning) invalidate();
      } else if (!currentSource()) {
        invalidate();
      }
    }

    dialog = JyDialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor: DialogTheme.of(context).barrierColor,
      builder: (_) => AlertDialog(
        key: const Key('contacts-request-confirmation'),
        title: const Text('发送好友请求？'),
        scrollable: true,
        content: Text('从 ${scope.accountId} 向 $target 发送好友请求。对方同意后才会成为好友。'),
        actions: [
          TextButton(
            key: const Key('contacts-request-cancel'),
            onPressed: () {
              if (dialog.isCurrent && !invalidated) navigator.pop(false);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('contacts-request-send'),
            onPressed: () {
              if (!dialog.isCurrent || invalidated || confirmedInDialog) return;
              if (!sameSession() ||
                  navigationGeneration?.call() != dialogAt ||
                  _requestAccount.text != target) {
                invalidate();
                return;
              }
              confirmedInDialog = true;
              navigator.pop(true);
            },
            child: const Text('确认发送'),
          ),
        ],
      ),
    );

    changes?.addListener(onChange);
    try {
      final confirmed = await navigator.push(dialog);
      confirming = false;
      if (confirmed != true ||
          !confirmedInDialog ||
          invalidated ||
          !currentSource() ||
          _requestAccount.text != target) {
        return;
      }
      setState(() => _requestSending = true);
      var message = '宿主已确认收到发给 $target 的请求；不代表对方已同意。';
      var ok = true;
      try {
        await send(target);
      } on HostRequestException catch (error) {
        ok = false;
        message = switch (error.failure.code) {
          FailureCode.unauthenticated ||
          FailureCode.forbidden => '未认证或无权限发送好友请求；不会自动重试。',
          FailureCode.invalidArgument ||
          FailureCode.notFound ||
          FailureCode.conflict => '宿主未受理此好友请求；请核对账号 ID 或关系状态。不会自动重试。',
          _ => '好友请求结果未确认；不会自动重试。',
        };
      } catch (_) {
        ok = false;
        message = '好友请求结果未确认；不会自动重试。';
      }
      if (!invalidated && currentSource()) {
        setState(() => _requestResult = (text: message, scope: scope, ok: ok));
      }
    } finally {
      changes?.removeListener(onChange);
      if (mounted) {
        setState(() {
          _requestSending = false;
          _requestActive = false;
        });
      }
    }
  }

  Widget _sectionGap() => const SizedBox(height: JySpace.lg);

  InputDecoration _pillInput(
    BuildContext context, {
    required String labelText,
    String? errorText,
  }) {
    final palette = JyPalette.of(context);
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(JyRadius.pill),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      labelText: labelText,
      errorText: errorText,
      border: border(palette.outline),
      enabledBorder: border(palette.outline),
      focusedBorder: border(palette.signal, 2),
      errorBorder: border(palette.danger),
      focusedErrorBorder: border(palette.danger, 2),
      disabledBorder: border(palette.hairline),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: JySpace.lg,
        vertical: JySpace.md,
      ),
    );
  }

  Widget _resultStrip(BuildContext context, String text, bool ok) {
    final palette = JyPalette.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        decoration: ShapeDecoration(
          color: ok ? palette.signalSoft : palette.dangerSoft,
          shape: JyShapes.rounded(JyRadius.md),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: JySpace.md,
          vertical: JySpace.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              ok
                  ? Icons.check_circle_outline_rounded
                  : Icons.error_outline_rounded,
              size: 18,
              color: ok ? palette.onSignalSoft : palette.onDangerSoft,
            ),
            const SizedBox(width: JySpace.sm),
            Expanded(
              child: Text(
                text,
                key: const Key('contacts-request-result'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: ok ? palette.onSignalSoft : palette.onDangerSoft,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _requestForm(BuildContext context, Object scope) {
    final palette = JyPalette.of(context);
    final result = _requestResult;
    final shown = result != null && result.scope == scope ? result : null;
    return JySlab(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '发起好友请求',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(color: palette.text1),
          ),
          const SizedBox(height: JySpace.sm),
          Text(
            '输入对方提供的账号 ID。请求需对方同意，不会自动开启聊天。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: palette.text2),
          ),
          const SizedBox(height: JySpace.md),
          TextField(
            key: const Key('contacts-request-account'),
            controller: _requestAccount,
            enabled: !_requestActive,
            autocorrect: false,
            enableSuggestions: false,
            decoration: _pillInput(
              context,
              labelText: '对方的账号 ID',
              errorText: _requestIdError,
            ),
            onChanged: (_) => setState(() {
              _requestIdError = null;
              _requestResult = null;
            }),
          ),
          const SizedBox(height: JySpace.md),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: JyPressable(
              borderRadius: BorderRadius.circular(JyRadius.md),
              child: FilledButton(
                key: const Key('contacts-request-review'),
                onPressed: _requestActive || _friendActionBusy != null
                    ? null
                    : _reviewRequest,
                child: Text(_requestSending ? '正在发送…' : '核对好友请求'),
              ),
            ),
          ),
          JySwitcher(
            child: shown == null
                ? const SizedBox.shrink(key: ValueKey('request-result-none'))
                : Padding(
                    key: const ValueKey('request-result-shown'),
                    padding: const EdgeInsets.only(top: JySpace.md),
                    child: _resultStrip(context, shown.text, shown.ok),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _lookupForm(BuildContext context) {
    final palette = JyPalette.of(context);
    return JySlab(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('contacts-account-id'),
            controller: _account,
            decoration: _pillInput(context, labelText: '按账号 ID 查询关系'),
          ),
          const SizedBox(height: JySpace.md),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: JyPressable(
              borderRadius: BorderRadius.circular(JyRadius.md),
              child: FilledButton(
                key: const Key('contacts-query'),
                onPressed: _busy ? null : _lookup,
                child: const Text('查询关系'),
              ),
            ),
          ),
          if (_result != null) ...[
            const SizedBox(height: JySpace.sm),
            Text(
              _result!,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: palette.text2),
            ),
          ],
        ],
      ),
    );
  }

  Widget _friendRow(BuildContext context, FriendContact friend) {
    final palette = JyPalette.of(context);
    final text = Theme.of(context).textTheme;
    return ListTile(
      key: Key('contacts-friend-${friend.accountId}'),
      minTileHeight: JySpace.rowMinHeight,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: JySpace.lg,
        vertical: JySpace.xs,
      ),
      leading: JyAvatar(label: _contactTitle(friend)),
      title: Text(
        _contactTitle(friend),
        style: text.titleMedium?.copyWith(color: palette.text1),
      ),
      subtitle: Text(
        '${friend.accountId} · ${_label(friend.state)}',
        style: text.bodyMedium?.copyWith(color: palette.text2),
      ),
    );
  }

  Widget _requestCard(BuildContext context, FriendContact friend) {
    final palette = JyPalette.of(context);
    final busy = _requestActive || _friendActionBusy != null;
    return JySlab(
      tone: JyTone.raised,
      padding: const EdgeInsets.all(JySpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _friendRow(context, friend),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: JySpace.sm,
            overflowSpacing: JySpace.sm,
            children: [
              JyPressable(
                borderRadius: BorderRadius.circular(JyRadius.md),
                child: TextButton(
                  key: Key('friend-deny-${friend.accountId}'),
                  onPressed: !busy && widget.denyFriend != null
                      ? () => _respondFriend(friend, accept: false)
                      : null,
                  child: const Text('拒绝'),
                ),
              ),
              JyPressable(
                borderRadius: BorderRadius.circular(JyRadius.md),
                child: TextButton(
                  key: Key('friend-accept-${friend.accountId}'),
                  style: TextButton.styleFrom(
                    backgroundColor: palette.signalSoft,
                    foregroundColor: palette.onSignalSoft,
                  ),
                  onPressed: !busy && widget.acceptFriend != null
                      ? () => _respondFriend(friend, accept: true)
                      : null,
                  child: const Text('接受'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _friendsList(BuildContext context) {
    final friends = _friends!;
    final pending = [
      for (final f in friends)
        if (f.state == FriendState.incomingPending) f,
    ];
    final mine = [
      for (final f in friends)
        if (f.state == FriendState.friends) f,
    ];
    final others = [
      for (final f in friends)
        if (f.state != FriendState.incomingPending &&
            f.state != FriendState.friends)
          f,
    ];
    final sections = <Widget>[];
    if (pending.isNotEmpty) {
      final cards = [for (final f in pending) _requestCard(context, f)];
      sections.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const JySectionHeader(title: '好友申请'),
            if (cards.length == 1)
              cards.first
            else
              JyStackDeck(
                children: cards,
                summary: '${cards.length} 条好友申请',
                expanded: _requestsExpanded,
                onExpandedChanged: (open) =>
                    setState(() => _requestsExpanded = open),
              ),
          ],
        ),
      );
    }
    var entranceIndex = 0;
    Widget group(String header, List<FriendContact> list) {
      final rows = <Widget>[];
      for (final f in list) {
        rows.add(
          JyEntrance(index: entranceIndex, child: _friendRow(context, f)),
        );
        entranceIndex++;
      }
      return JyGroup(header: header, children: rows);
    }

    if (mine.isNotEmpty) sections.add(group('我的好友', mine));
    if (others.isNotEmpty) sections.add(group('其他关系', others));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final section in sections)
          Padding(
            padding: const EdgeInsets.only(bottom: JySpace.lg),
            child: section,
          ),
      ],
    );
  }

  Widget _friendsSection(BuildContext context) {
    final Widget body;
    if (widget.loadFriends == null) {
      body = const StatusPanel(
        key: ValueKey('contacts-offline'),
        tone: StatusTone.offline,
        icon: Icons.link_off_rounded,
        title: '当前未连接宿主，无法读取联系人。',
      );
    } else if (_loadingFriends) {
      body = const Padding(
        key: ValueKey('contacts-loading'),
        padding: EdgeInsets.symmetric(vertical: JySpace.xl),
        child: JyBusyIndicator(label: '正在读取联系人'),
      );
    } else if (_friendsMessage != null) {
      body = StatusPanel(
        key: const ValueKey('contacts-error'),
        tone: StatusTone.error,
        icon: _friendsActionFailed
            ? Icons.person_off_outlined
            : Icons.error_outline_rounded,
        title: _friendsActionFailed ? '没能处理好友申请' : '没能读取联系人',
        detail: _friendsMessage,
        action: TextButton(
          key: const Key('contacts-retry'),
          onPressed: _friendActionBusy == null ? _loadFriends : null,
          child: const Text('重新读取'),
        ),
      );
    } else if (_friends == null) {
      body = const SizedBox.shrink(key: ValueKey('contacts-idle'));
    } else if (_friends!.isEmpty) {
      body = const StatusPanel(
        key: ValueKey('contacts-empty'),
        icon: Icons.group_outlined,
        title: '暂无联系人或待处理的好友邀请。',
      );
    } else {
      body = KeyedSubtree(
        key: const ValueKey('contacts-list'),
        child: _friendsList(context),
      );
    }
    return JySwitcher(child: body);
  }

  // Account names may contain controls per the host contract. Only the
  // rendered label changes; the DTO and account ID are kept intact.
  static final _displayControls = RegExp(r'[\x00-\x1f\x7f-\x9f]');

  static String _contactTitle(FriendContact friend) {
    final display = friend.displayName.replaceAll(_displayControls, ' ');
    return display.trim().isEmpty ? friend.accountId : display;
  }

  @override
  Widget build(BuildContext context) {
    final palette = JyPalette.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final pagePad = width < 720 ? JySpace.pageNarrow : JySpace.pageWide;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: pagePad,
                  vertical: JySpace.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: JySpace.lg),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Icon(
                              Icons.info_outline_rounded,
                              size: 16,
                              color: palette.text3,
                            ),
                          ),
                          const SizedBox(width: JySpace.sm),
                          Expanded(
                            child: Text(
                              widget.requestFriend == null
                                  ? '数据来自宿主实时读取；仅显式点击「接受/拒绝」处理好友邀请，其余只读。'
                                  : '数据来自宿主实时读取；可接受或拒绝来信，也可核对账号 ID 后确认发送好友请求。',
                              key: const Key('contacts-live-note'),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: palette.text3),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _friendsSection(context),
                    if (widget.requestFriend != null)
                      if (widget.requestContext?.call() case final scope?) ...[
                        _sectionGap(),
                        _requestForm(context, scope),
                      ],
                    if (widget.lookupState != null) ...[
                      _sectionGap(),
                      _lookupForm(context),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
