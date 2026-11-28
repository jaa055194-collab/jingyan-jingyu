import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/runtime.dart';
import '../../app/shell_view_model.dart';
import '../../app/status_panel.dart';
import '../../net/favorites_api.dart';
import '../../net/host_connection.dart';
import '../../ui/ui.dart';

/// A private, read-only view of the current account's host favorites.
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen._(this._scope);

  static bool canOpen(ShellViewModel model) =>
      model is ClientRuntime &&
      model.connection != null &&
      model.authenticated &&
      !model.locked &&
      model.connectedAccountId != null &&
      model.ownAiSessionContext != null;

  static void open(BuildContext context, ShellViewModel model) {
    if (!context.mounted ||
        ModalRoute.of(context)?.isCurrent != true ||
        model is! ClientRuntime ||
        !canOpen(model)) {
      return;
    }
    final scope = _FavoritesScope(
      model,
      model.connection!,
      model.connectedAccountId!,
      model.ownAiSessionContext!,
    );
    unawaited(Navigator.of(context).push<void>(_FavoritesRoute(scope)));
  }

  final _FavoritesScope _scope;

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

/// Start listening at the tap (not the first frame of the pushed route). A
/// transient lock/switch still makes that route unusable after it ends.
class _FavoritesScope extends ChangeNotifier {
  _FavoritesScope(this._model, this.connection, this._account, this._epoch) {
    _model.addListener(_onSessionChanged);
  }

  final ClientRuntime _model;
  final HostConnection connection;
  final String _account;
  final Object _epoch;
  final cancellation = HostReadCancellation();
  bool _invalidated = false;

  bool get current =>
      !_invalidated &&
      _model.authenticated &&
      !_model.locked &&
      _model.connectedAccountId == _account &&
      _model.ownAiSessionContext == _epoch &&
      identical(_model.connection, connection);

  void _onSessionChanged() {
    if (!current) invalidate();
  }

  void invalidate() {
    if (_invalidated) return;
    _invalidated = true;
    cancellation.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _model.removeListener(_onSessionChanged);
    cancellation.cancel();
    super.dispose();
  }
}

class _FavoritesRoute extends MaterialPageRoute<void> {
  _FavoritesRoute(this._scope)
    : super(
        allowSnapshotting: false,
        builder: (_) => FavoritesScreen._(_scope),
      );

  final _FavoritesScope _scope;

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    if (nextRoute != null) _scope.invalidate();
  }

  @override
  void didComplete(void result) {
    _scope.invalidate();
    super.didComplete(null);
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  FavoritesOutcome? _outcome;
  bool _submitted = false;

  _FavoritesScope get _scope => widget._scope;
  bool get _current =>
      mounted && _scope.current && ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    _scope.addListener(_clear);
  }

  @override
  void dispose() {
    _scope.removeListener(_clear);
    super.dispose();
  }

  void _clear() => setState(() => _outcome = null);

  Future<void> _load() async {
    if (!_current || _submitted) return;
    setState(() => _submitted = true);
    final outcome = await FavoritesApi(_scope.connection)
        .readFavorites(cancellation: _scope.cancellation);
    if (!_current) return;
    setState(() => _outcome = outcome);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('我的收藏')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: _list(),
        ),
      ),
    ),
  );

  Widget _list() {
    final outcome = _outcome;
    final favorites = outcome is FavoritesLoaded
        ? outcome.favorites
        : <FavoriteSummary>[];
    return ListView.builder(
      padding: const EdgeInsets.all(JySpace.lg),
      itemCount: favorites.length + 1,
      itemBuilder: (context, index) => index == 0
          ? _header(context, outcome, favorites)
          : Padding(
              padding: const EdgeInsets.only(bottom: JySpace.sm),
              child: JyEntrance(
                index: index - 1,
                child: _FavoriteTile(favorites[index - 1]),
              ),
            ),
    );
  }

  Widget _header(
    BuildContext context,
    FavoritesOutcome? outcome,
    List<FavoriteSummary> favorites,
  ) {
    final palette = JyPalette.of(context);
    final Widget state;
    if (!_current) {
      state = _status(
        context,
        'favorites-invalidated',
        '已离开此页面或当前会话已变化。请返回后重新打开收藏。',
        Icons.lock_outline_rounded,
      );
    } else if (!_submitted) {
      state = Align(
        key: const ValueKey('favorites-not-loaded'),
        alignment: AlignmentDirectional.centerStart,
        child: FilledButton.icon(
          key: const Key('load-favorites'),
          onPressed: _load,
          icon: const Icon(Icons.bookmark_outline),
          label: const Text('读取收藏'),
        ),
      );
    } else if (outcome == null) {
      state = const Padding(
        key: ValueKey('favorites-loading'),
        padding: EdgeInsets.symmetric(vertical: JySpace.md),
        child: JyBusyIndicator(label: '正在读取收藏', linear: true),
      );
    } else if (outcome is FavoritesDenied) {
      state = _status(
        context,
        'favorites-denied',
        '宿主拒绝读取收藏。请确认登录后重新打开。',
        Icons.lock_outline_rounded,
      );
    } else if (outcome is FavoritesUnavailable) {
      state = _status(
        context,
        'favorites-unavailable',
        '暂时无法读取收藏。请检查连接后重新打开。',
        Icons.cloud_off_rounded,
      );
    } else if (outcome is FavoritesMalformed) {
      state = _status(
        context,
        'favorites-malformed',
        '收藏响应无效或过大，未显示任何条目。',
        Icons.error_outline_rounded,
      );
    } else if (favorites.isEmpty) {
      state = _status(
        context,
        'favorites-empty',
        '宿主没有返回当前可见的收藏。',
        Icons.bookmark_border_rounded,
      );
    } else {
      state = const SizedBox.shrink(key: ValueKey('favorites-loaded'));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: JySpace.md),
      child: JySlab(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '只读显示宿主返回的当前可见收藏，不打开消息、链接或文件。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: palette.text2),
            ),
            const SizedBox(height: JySpace.md),
            JySwitcher(child: state),
          ],
        ),
      ),
    );
  }

  Widget _status(
    BuildContext context,
    String key,
    String message,
    IconData icon,
  ) => Semantics(
    liveRegion: true,
    child: StatusPanel(key: Key(key), icon: icon, title: message),
  );
}

class _FavoriteTile extends StatefulWidget {
  const _FavoriteTile(this.item);

  final FavoriteSummary item;

  @override
  State<_FavoriteTile> createState() => _FavoriteTileState();
}

class _FavoriteTileState extends State<_FavoriteTile> {
  bool _expanded = false;

  static (IconData, String) _kind(FavoriteKind kind) => switch (kind) {
    FavoriteKind.message => (Icons.chat_bubble_outline, '消息收藏'),
    FavoriteKind.text => (Icons.notes, '文本收藏'),
    FavoriteKind.link => (Icons.link, '链接收藏'),
    FavoriteKind.file => (Icons.insert_drive_file_outlined, '文件收藏'),
  };

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final palette = JyPalette.of(context);
    final text = Theme.of(context).textTheme;
    final (icon, label) = _kind(item.kind);
    final time = item.createdAt
        .toIso8601String()
        .substring(0, 16)
        .replaceFirst('T', ' ');
    final preview = switch (item.kind) {
      FavoriteKind.message || FavoriteKind.text => item.preview,
      _ => null,
    };
    final expandable = preview != null;
    final body = JySlab(
      padding: const EdgeInsets.all(JySpace.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          JyIconTile(icon: icon, color: palette.signal),
          const SizedBox(width: JySpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title ?? label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleMedium?.copyWith(color: palette.text1),
                ),
                const SizedBox(height: JySpace.xs),
                Text(
                  item.title == null ? '$time UTC' : '$label · $time UTC',
                  style: text.labelSmall?.copyWith(
                    color: palette.text3,
                    fontFeatures: JyTypography.tabularFigures,
                  ),
                ),
                if (preview != null) ...[
                  const SizedBox(height: JySpace.sm),
                  AnimatedSize(
                    duration: JyMotion.of(context, JyDurations.standard),
                    curve: JyCurves.enter,
                    alignment: AlignmentDirectional.topStart,
                    child: Text(
                      preview,
                      maxLines: _expanded ? null : 3,
                      overflow: _expanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(color: palette.text2),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (expandable) ...[
            const SizedBox(width: JySpace.sm),
            JyChevron(expanded: _expanded),
          ],
        ],
      ),
    );
    if (!expandable) {
      return body;
    }
    return JyPressable(
      borderRadius: BorderRadius.circular(JyRadius.lg),
      onTap: () => setState(() => _expanded = !_expanded),
      child: body,
    );
  }
}
