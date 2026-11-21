import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../net/host_connection.dart' show HostReadCancellation;
import '../../net/scheduled_messages_api.dart';
import '../../net/scheduled_messages_scope.dart';

/// The group-only scheduling surface. It acts on the exact captured
/// conversation scope and never reads or rewrites the chat composer draft.
Future<void> openScheduledMessages(
  BuildContext context, {
  required ShellViewModel model,
  required String conversationId,
  required ScheduledMessagesScope scope,
}) {
  if (!scope.isCurrent() || !scope.canContactHost()) return Future.value();
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ScheduledMessagesScreen(
        model: model,
        scope: scope,
        conversationId: conversationId,
      ),
    ),
  );
}

class ScheduledMessagesScreen extends StatefulWidget {
  const ScheduledMessagesScreen({
    super.key,
    required this.model,
    required this.scope,
    required this.conversationId,
  });
  final ShellViewModel model;
  final ScheduledMessagesScope scope;
  final String conversationId;

  @override
  State<ScheduledMessagesScreen> createState() =>
      _ScheduledMessagesScreenState();
}

class _ScheduledMessagesScreenState extends State<ScheduledMessagesScreen> {
  final _text = TextEditingController();
  final _date = TextEditingController();
  final _time = TextEditingController();
  late final _api = ScheduledMessagesApi(widget.scope.transport);
  List<ScheduledMessage> _items = const [];
  bool _hasMore = false;
  bool _reading = false;
  bool _readFailed = false;
  bool _creating = false;
  String? _readProblem;
  ({String text, DateTime at})? _review;
  String? _confirmedCreateId;
  String? _unknownCreate;
  String? _unknownCancelId;
  bool _unknownCancel = false;
  bool _cancelled = false;
  String? _notice;
  bool _noticeError = false;
  String? _choiceError;
  bool _composing = false;
  bool _retired = false;
  HostReadCancellation? _read;

  bool get _current =>
      mounted &&
      !_retired &&
      widget.model.authenticated &&
      !widget.model.locked &&
      widget.model.selectedConversationId == widget.conversationId &&
      widget.scope.isCurrent() &&
      widget.scope.canContactHost();
  bool get _busy => _reading || _creating;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onModelChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModelChanged);
    _read?.cancel();
    _text.dispose();
    _date.dispose();
    _time.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    if (mounted) setState(() {});
  }

  bool get _draftValid {
    final text = _text.text.trim();
    return text.isNotEmpty &&
        _text.text.length <= 8000 &&
        _instant(_date.text.trim(), _time.text.trim()) != null;
  }

  bool _sameScope(ScheduledMessagesScope scope) => widget.scope == scope;

  Future<void> _load({String? knownId}) async {
    if (!_current || _busy) return;
    final cancellation = HostReadCancellation();
    final scope = widget.scope;
    setState(() {
      _read = cancellation;
      _reading = true;
      _readFailed = false;
      _readProblem = null;
      if (knownId == null) _items = const [];
    });
    final result = await _api.read(widget.conversationId, knownId: knownId);
    if (!mounted || !identical(_read, cancellation)) return;
    setState(() {
      _read = null;
      _reading = false;
      if (!_current || !_sameScope(scope)) return;
      if (result is ScheduleLoaded &&
          (knownId == null || result.items.any((item) => item.id == knownId))) {
        if (knownId == null) {
          _items = result.items;
          _hasMore = result.hasMore;
          _readFailed = false;
          _readProblem = null;
        } else {
          final known = result.items.single;
          _items = [
            for (final row in _items)
              if (row.id == known.id) known else row,
            if (!_items.any((row) => row.id == known.id)) known,
          ];
          if (_unknownCancelId == known.id) {
            _unknownCancelId = null;
            _unknownCancel = false;
            _notice = '已重新读取到该 ID 的当前状态，原始取消请求是否成功仍未知。';
            _noticeError = true;
          }
          _confirmedCreateId = null;
          if (known.status == ScheduleStatus.pending) _unknownCreate = null;
        }
      } else if (_items.isEmpty || _unknownCancelId != null) {
        _readFailed = true;
        _readProblem =
            result is ScheduleFailure &&
                result.problem == ScheduleProblem.refused
            ? '宿主未提供此群的定时消息，或当前无权访问。'
            : '无法验证定时消息；不会显示为已取消或已创建。';
        if (_unknownCancelId != null) _unknownCancel = true;
      }
    });
  }

  static int? _minute(String raw) {
    final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(raw);
    if (match == null) return null;
    final hour = int.parse(match[1]!);
    final minute = int.parse(match[2]!);
    return hour < 24 && minute < 60 ? hour * 60 + minute : null;
  }

  /// Strict local date components + exact round-trip. This rejects values Dart
  /// would otherwise normalize (for example a DST-gap wall time), and never
  /// derives a timezone from the device or claims local recurrence.
  static DateTime? _instant(String date, String time) {
    final d = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date);
    final minute = _minute(time);
    if (d == null || minute == null) return null;
    final year = int.parse(d[1]!);
    final month = int.parse(d[2]!);
    final day = int.parse(d[3]!);
    if (year < 1970 || year > 9998) return null;
    final local = DateTime(year, month, day, minute ~/ 60, minute % 60);
    if (local.year != year ||
        local.month != month ||
        local.day != day ||
        local.hour != minute ~/ 60 ||
        local.minute != minute % 60) {
      return null;
    }
    final instant = local.toUtc();
    if (!instant.isAfter(DateTime.now().toUtc())) return null;
    return instant;
  }

  String _formatLocal(DateTime at) {
    final local = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final offset = local.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final absolute = offset.abs();
    return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)} '
        '(UTC$sign${two(absolute.inHours)}:${two(absolute.inMinutes % 60)})';
  }

  ({String text, DateTime at})? _parseDraft() {
    final text = _text.text.trim();
    final at = _instant(_date.text.trim(), _time.text.trim());
    if (text.isEmpty) {
      _choiceError = '请输入要发送的普通文字。';
      return null;
    }
    if (_text.text.length > 8000) {
      _choiceError = '文字过长，请缩短后再安排。';
      return null;
    }
    if (at == null) {
      _choiceError = '请输入实际存在且晚于当前时刻的日期和时间（YYYY-MM-DD、HH:MM）。';
      return null;
    }
    _choiceError = null;
    return (text: text, at: at);
  }

  void _reviewDraft() {
    if (!_current || _busy) return;
    final draft = _parseDraft();
    if (draft == null) {
      setState(() {});
      return;
    }
    setState(() {
      _review = draft;
      _notice = null;
      _noticeError = false;
      _choiceError = null;
    });
  }

  Future<void> _create() async {
    final draft = _review;
    if (!_current || _busy || draft == null) return;
    final scope = widget.scope;
    setState(() {
      _creating = true;
      _notice = null;
      _noticeError = false;
      _unknownCreate = null;
    });
    final result = await _api.create(
      widget.conversationId,
      text: draft.text,
      at: draft.at,
    );
    if (!mounted) return;
    setState(() {
      _creating = false;
      if (!_current || !_sameScope(scope)) return;
      _review = null;
      if (result is ScheduleCreated &&
          result.item.at == draft.at &&
          result.item.conversationId == widget.conversationId) {
        _confirmedCreateId = result.item.id;
        _notice = '宿主已确认创建，状态为待发送（ID：${result.item.id}）。';
        _noticeError = false;
        _text.clear();
        _date.clear();
        _time.clear();
        _composing = false;
        _items = [
          result.item,
          ..._items.where((row) => row.id != result.item.id),
        ];
      } else if (result is ScheduleFailure &&
          result.problem == ScheduleProblem.unknown) {
        _unknownCreate =
            'The host did not provide a verifiable success receipt.';
        _notice = '提交结果未知，可能已创建。宿主没有返回可核对 ID；不会重试，也不能凭列表猜测。';
        _noticeError = true;
      } else if (result is ScheduleFailure &&
          result.problem == ScheduleProblem.refused) {
        _notice = '宿主拒绝创建。请确认当前群聊发送权限，未确认创建。';
        _noticeError = true;
      } else {
        _notice = '无法确认创建。请刷新已知状态后再操作，不会自动重试。';
        _noticeError = true;
      }
    });
  }

  void _chooseCancel(ScheduledMessage item) {
    if (!_current ||
        _busy ||
        _unknownCancelId != null ||
        item.status != ScheduleStatus.pending) {
      return;
    }
    showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('schedule-cancel-dialog'),
        title: const Text('取消这条定时消息？'),
        content: Text('仅取消本人待发送的消息。宿主确认前不会从列表移除。'),
        actions: [
          TextButton(
            key: const Key('schedule-cancel-dismiss'),
            onPressed: () => Navigator.pop(dialog),
            child: const Text('保留'),
          ),
          FilledButton(
            key: const Key('schedule-confirm-cancel'),
            onPressed: () {
              Navigator.pop(dialog);
              unawaited(_cancel(item));
            },
            child: const Text('确认取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _cancel(ScheduledMessage item) async {
    if (!_current || _busy || !_sameScope(widget.scope)) return;
    final scope = widget.scope;
    setState(() {
      _creating = true;
      _notice = null;
      _noticeError = false;
      _cancelled = false;
      _unknownCancel = false;
    });
    final result = await _api.cancel(widget.conversationId, item: item);
    if (!mounted) return;
    setState(() {
      _creating = false;
      if (!_current || !_sameScope(scope)) return;
      if (result is ScheduleCancelled) {
        _items = [
          for (final row in _items)
            if (row.id == item.id)
              ScheduledMessage(
                id: row.id,
                conversationId: row.conversationId,
                at: row.at,
                status: ScheduleStatus.cancelled,
              )
            else
              row,
        ];
        _notice = '宿主已确认取消。';
        _noticeError = false;
        _cancelled = true;
        return;
      }
      final refused =
          result is ScheduleFailure &&
          result.problem == ScheduleProblem.refused;
      _unknownCancelId = refused ? null : item.id;
      _unknownCancel = !refused;
      _notice = refused ? '宿主拒绝取消；列表未改动。' : '取消结果未知，可能已经生效。请刷新已知 ID；不会自动重试。';
      _noticeError = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) _retired = true;
    final canWrite = _current && !_busy && !_readFailed && !_reading;
    final items = _items;
    final title =
        widget.model.conversations
            .where((row) => row.id == widget.conversationId)
            .map((row) => row.title)
            .firstOrNull ??
        '当前群聊';
    return Scaffold(
      appBar: AppBar(title: const Text('定时消息')),
      body: !_current
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '会话、账号或连接已变化。请返回聊天后重新打开。',
                key: Key('schedule-retired'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('目标群聊：$title', key: const Key('schedule-target')),
                const Text('仅用于当前群聊的普通文字；一次定时发送。桌面端入口不会发送手机通知、附件或触发 AI。'),
                const SizedBox(height: 8),
                if (_busy)
                  const LinearProgressIndicator(key: Key('schedule-loading')),
                if (_readProblem != null)
                  Text(
                    _readProblem!,
                    key: const Key('schedule-read-unavailable'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (!_reading && _readFailed && _items.isEmpty)
                  TextButton.icon(
                    key: const Key('schedule-read-refresh'),
                    onPressed: _current && !_busy
                        ? () => _load(knownId: _unknownCancelId)
                        : null,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新读取'),
                  ),
                if (_unknownCancelId != null && !_reading)
                  TextButton.icon(
                    key: Key('schedule-refresh'),
                    onPressed: _current && !_busy
                        ? () => _load(knownId: _unknownCancelId)
                        : null,
                    icon: const Icon(Icons.refresh),
                    label: const Text('刷新该已知 ID'),
                  ),
                if (_notice != null)
                  Text(
                    _notice!,
                    key: Key(
                      _unknownCreate != null
                          ? 'schedule-create-unknown'
                          : _unknownCancel
                          ? 'schedule-cancel-unknown'
                          : _cancelled
                          ? 'schedule-cancelled'
                          : _confirmedCreateId != null
                          ? 'schedule-created'
                          : 'schedule-notice',
                    ),
                    style: _noticeError
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                  ),
                const SizedBox(height: 8),
                if (canWrite && !_composing && _unknownCreate == null)
                  FilledButton.icon(
                    key: const Key('schedule-compose'),
                    onPressed: () {
                      setState(() {
                        _choiceError = null;
                        _notice = null;
                        _composing = true;
                        if (_date.text.isEmpty) _date.text = _defaultDate();
                      });
                    },
                    icon: const Icon(Icons.add_alarm_outlined),
                    label: const Text('安排一条文字'),
                  ),
                if (_review != null) ...[
                  const Divider(),
                  Text('确认安排', style: Theme.of(context).textTheme.titleMedium),
                  Text('发送到：$title', key: const Key('schedule-review-target')),
                  Text(_review!.text, key: const Key('schedule-review-text')),
                  Text('发送时刻：${_formatLocal(_review!.at)}'),
                  Text('UTC：${_review!.at.toIso8601String()}'),
                  const Text('仅发送一次绝对时刻；不承诺本地重复、通知或送达。'),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        key: const Key('schedule-review-cancel'),
                        onPressed: canWrite
                            ? () => setState(() => _review = null)
                            : null,
                        child: const Text('返回修改'),
                      ),
                      TextButton(
                        key: const Key('schedule-review-abandon'),
                        onPressed: canWrite
                            ? () {
                                setState(() {
                                  _review = null;
                                  _composing = false;
                                  _text.clear();
                                  _date.clear();
                                  _time.clear();
                                });
                              }
                            : null,
                        child: const Text('收起'),
                      ),
                      FilledButton(
                        key: const Key('schedule-confirm'),
                        onPressed: canWrite ? _create : null,
                        child: const Text('确认安排'),
                      ),
                    ],
                  ),
                ],
                if (_choiceError != null)
                  Text(
                    _choiceError!,
                    key: const Key('schedule-choice-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_review == null && canWrite && _composing) ...[
                  TextField(
                    key: const Key('schedule-text'),
                    controller: _text,
                    maxLines: 3,
                    minLines: 1,
                    maxLength: 8000,
                    onChanged: (_) => setState(() {
                      _choiceError = null;
                    }),
                    decoration: const InputDecoration(labelText: '普通文字'),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('schedule-date'),
                          controller: _date,
                          onChanged: (_) => setState(() {
                            _choiceError = null;
                          }),
                          decoration: const InputDecoration(
                            labelText: '日期',
                            hintText: 'YYYY-MM-DD',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          key: const Key('schedule-time'),
                          controller: _time,
                          onChanged: (_) => setState(() {
                            _choiceError = null;
                          }),
                          decoration: const InputDecoration(
                            labelText: '本地时间',
                            hintText: 'HH:MM',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Text(
                    '日期与时间是本机当前显示的本地时刻；确认页同时显示该绝对时刻的 UTC。设备时区是固定偏移，不推断夏令时。',
                  ),
                  if (_date.text.isNotEmpty &&
                      _instant(_date.text.trim(), _time.text.trim()) == null)
                    Text(
                      '请输入实际存在且晚于当前时刻的时间。',
                      key: const Key('schedule-time-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        key: const Key('schedule-compose-cancel'),
                        onPressed: () {
                          setState(() {
                            _composing = false;
                            _choiceError = null;
                            _review = null;
                          });
                        },
                        child: const Text('取消编辑'),
                      ),
                      FilledButton(
                        key: const Key('schedule-review'),
                        onPressed: _draftValid ? _reviewDraft : null,
                        child: const Text('查看确认'),
                      ),
                    ],
                  ),
                ],
                const Divider(),
                Row(
                  children: [
                    Text(
                      '本人待发送',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    IconButton(
                      key: const Key('schedule-list-refresh'),
                      tooltip: '重新读取',
                      onPressed: canWrite ? () => _load() : null,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                if (_reading && _items.isEmpty) const Text('正在读取…'),
                if (!_reading && items.isEmpty && _readProblem == null)
                  const Text('没有本人待发送或历史定时消息。'),
                const Text(
                  '状态说明：待发送；已发送（已追加消息）；已取消/未发送（取消成功，或到期时权限/可见性已变化而终止）；已过期（超过 24 小时未投递，不补发）。',
                  key: Key('schedule-status-legend'),
                ),
                for (final item in items)
                  Card(
                    key: Key('schedule-row-${item.id}'),
                    child: ListTile(
                      title: Text(_formatLocal(item.at)),
                      subtitle: Text(
                        '${_statusLabel(item.status)} · ${item.at.toIso8601String()}',
                      ),
                      trailing:
                          item.status == ScheduleStatus.pending &&
                              item.id != _unknownCancelId
                          ? TextButton(
                              key: Key('schedule-cancel-${item.id}'),
                              onPressed: canWrite
                                  ? () => _chooseCancel(item)
                                  : null,
                              child: const Text('取消'),
                            )
                          : item.id == _unknownCancelId
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                '结果未知',
                                key: Key('schedule-cancel-unknown-row'),
                              ),
                            )
                          : null,
                    ),
                  ),
                if (_hasMore) const Text('只显示最近 50 条。'),
                if (_unknownCancelId != null)
                  TextButton(
                    key: const Key('schedule-cancel-refresh'),
                    onPressed: canWrite
                        ? () => _load(knownId: _unknownCancelId)
                        : null,
                    child: const Text('刷新已知 ID 状态'),
                  ),
              ],
            ),
    );
  }

  static String _statusLabel(ScheduleStatus status) => switch (status) {
    ScheduleStatus.pending => '待发送',
    ScheduleStatus.delivered => '已发送',
    ScheduleStatus.cancelled => '已取消/未发送',
    ScheduleStatus.expired => '已过期',
  };

  static String _defaultDate() {
    final now = DateTime.now();
    final next = now.add(const Duration(days: 1));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${next.year.toString().padLeft(4, '0')}-${two(next.month)}-${two(next.day)}';
  }
}
