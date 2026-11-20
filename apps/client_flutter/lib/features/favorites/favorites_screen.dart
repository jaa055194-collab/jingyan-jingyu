import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/runtime.dart';
import '../../app/shell_view_model.dart';
import '../../net/favorites_api.dart';
import '../../net/host_connection.dart';

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
          child: !_current
              ? ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _status(
                      'favorites-invalidated',
                      '已离开此页面或当前会话已变化。请返回后重新打开收藏。',
                    ),
                  ],
                )
              : _list(),
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
      padding: const EdgeInsets.all(16),
      itemCount: favorites.length + 1,
      itemBuilder: (context, index) => index == 0
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('只读显示宿主返回的当前可见收藏，不打开消息、链接或文件。'),
                const SizedBox(height: 16),
                if (!_submitted)
                  FilledButton.icon(
                    key: const Key('load-favorites'),
                    onPressed: _load,
                    icon: const Icon(Icons.bookmark_outline),
                    label: const Text('读取收藏'),
                  )
                else if (outcome == null)
                  const LinearProgressIndicator(semanticsLabel: '正在读取收藏')
                else if (outcome is FavoritesDenied)
                  _status('favorites-denied', '宿主拒绝读取收藏。请确认登录后重新打开。')
                else if (outcome is FavoritesUnavailable)
                  _status('favorites-unavailable', '暂时无法读取收藏。请检查连接后重新打开。')
                else if (outcome is FavoritesMalformed)
                  _status('favorites-malformed', '收藏响应无效或过大，未显示任何条目。')
                else if (favorites.isEmpty)
                  _status('favorites-empty', '宿主没有返回当前可见的收藏。'),
              ],
            )
          : _FavoriteTile(favorites[index - 1]),
    );
  }

  Widget _status(String key, String message) =>
      Semantics(liveRegion: true, child: Text(message, key: Key(key)));
}

class _FavoriteTile extends StatelessWidget {
  const _FavoriteTile(this.item);

  final FavoriteSummary item;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (item.kind) {
      FavoriteKind.message => (Icons.chat_bubble_outline, '消息收藏'),
      FavoriteKind.text => (Icons.notes, '文本收藏'),
      FavoriteKind.link => (Icons.link, '链接收藏'),
      FavoriteKind.file => (Icons.insert_drive_file_outlined, '文件收藏'),
    };
    final time = item.createdAt
        .toIso8601String()
        .substring(0, 16)
        .replaceFirst('T', ' ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(
        item.title ?? label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.title == null ? '$time UTC' : '$label · $time UTC'),
          if (item.kind case FavoriteKind.message || FavoriteKind.text)
            Text(
              item.preview ?? '无可展示的文字摘要',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}
