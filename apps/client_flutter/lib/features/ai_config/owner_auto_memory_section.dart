import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../net/host_connection.dart' show HostReadCancellation;
import '../../net/owner_auto_memory_api.dart';
import '../../ui/ui.dart';
import 'ai_config_problem_line.dart';

/// Default-off, per-AI opt-in auto chat-history memory. Only the owner's own
/// authorized private chat is collected; never group or third-party content.
/// This section reads the grant, toggles it with a second confirmation, lists
/// captured entries, deletes one, and clears all. No body is ever sent back.
class OwnerAutoMemorySection extends StatefulWidget {
  const OwnerAutoMemorySection({
    super.key,
    required this.api,
    required this.profile,
    required this.aiLabel,
    required this.isCurrent,
    required this.canContactHost,
  });

  final OwnerAutoMemoryApi api;
  final String profile;
  final String aiLabel;
  final bool Function() isCurrent;
  final bool Function() canContactHost;

  @override
  State<OwnerAutoMemorySection> createState() => _OwnerAutoMemorySectionState();
}

class _OwnerAutoMemorySectionState extends State<OwnerAutoMemorySection>
    with AutomaticKeepAliveClientMixin<OwnerAutoMemorySection> {
  OwnerAutoMemorySettings? _settings;
  OwnerAutoMemoryList? _entries;
  OwnerAutoMemoryProblem? _readProblem;
  OwnerAutoMemoryProblem? _writeProblem;
  OwnerAutoMemoryProblem? _unknownProblem;
  String? _notice;
  bool _busy = false;
  bool _saved = false;
  HostReadCancellation? _read;

  @override
  bool get wantKeepAlive => true;

  bool get _current => mounted && widget.isCurrent();
  bool get _canRequest =>
      _current &&
      widget.canContactHost() &&
      ModalRoute.isCurrentOf(context) == true;
  bool get _busyNow => _busy || _read != null;

  @override
  void dispose() {
    _read?.cancel();
    super.dispose();
  }

  void _remember(
    OwnerAutoMemorySettings settings,
    OwnerAutoMemoryList entries,
  ) {
    _settings = settings;
    _entries = entries;
    _readProblem = null;
    _writeProblem = null;
    _unknownProblem = null;
    _notice = null;
    _saved = false;
  }

  void _showProblem(OwnerAutoMemoryProblem? problem) {
    if (problem == null) return;
    if (problem == OwnerAutoMemoryProblem.unknown ||
        problem == OwnerAutoMemoryProblem.conflict) {
      _settings = null;
      _entries = null;
      _unknownProblem = problem;
    } else {
      _writeProblem = problem;
    }
    _saved = false;
  }

  Future<void> _load() async {
    if (!_canRequest || _busyNow) return;
    final cancellation = HostReadCancellation();
    final profile = widget.profile;
    setState(() {
      _read = cancellation;
      _settings = null;
      _entries = null;
      _readProblem = null;
      _writeProblem = null;
      _unknownProblem = null;
      _notice = null;
    });
    final settings = await widget.api.readSettings(
      profile,
      cancellation: cancellation,
    );
    if (!mounted || !identical(_read, cancellation)) return;
    if (settings.state == null) {
      setState(() {
        _read = null;
        _readProblem = settings.problem ?? OwnerAutoMemoryProblem.unavailable;
      });
      return;
    }
    final entries = await widget.api.readEntries(
      profile,
      cancellation: cancellation,
    );
    if (!mounted || !identical(_read, cancellation)) return;
    setState(() {
      _read = null;
      if (!_current) return;
      if (entries.state == null) {
        _readProblem = entries.problem ?? OwnerAutoMemoryProblem.unavailable;
        return;
      }
      if (settings.state!.revision != entries.state!.revision) {
        _unknownProblem = OwnerAutoMemoryProblem.conflict;
        return;
      }
      _remember(settings.state!, entries.state!);
    });
  }

  Future<void> _delete(OwnerAutoMemoryEntry entry) async {
    final entries = _entries;
    if (!_canRequest || _busyNow || entries == null) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('auto-memory-delete-dialog'),
        title: const Text('删除这条记忆？'),
        content: Text('将删除「${entry.text}」，不影响已开启的采集授权。'),
        actions: [
          TextButton(
            key: const Key('auto-memory-delete-cancel'),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('保留'),
          ),
          FilledButton(
            key: const Key('auto-memory-delete-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (approved != true || !_current || !identical(_entries, entries)) return;
    setState(() {
      _busy = true;
      _notice = null;
      _writeProblem = null;
    });
    final result = await widget.api.deleteEntry(
      widget.profile,
      current: entries,
      memoryId: entry.id,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!_current) return;
      if (result.state != null) {
        _entries = result.state;
        _syncSettingsRevision(result.state!.revision);
        _saved = true;
      } else {
        _showProblem(result.problem);
      }
    });
  }

  Future<void> _clear() async {
    final entries = _entries;
    if (!_canRequest ||
        _busyNow ||
        entries == null ||
        entries.entries.isEmpty) {
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('auto-memory-clear-dialog'),
        title: const Text('清空全部记忆？'),
        content: const Text('这会删除所有已采集的记忆，但不会关闭“自动记忆”采集授权。'),
        actions: [
          TextButton(
            key: const Key('auto-memory-clear-cancel'),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('保留'),
          ),
          FilledButton(
            key: const Key('auto-memory-clear-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (approved != true || !_current || !identical(_entries, entries)) return;
    setState(() {
      _busy = true;
      _notice = null;
      _writeProblem = null;
    });
    final result = await widget.api.clear(widget.profile, current: entries);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!_current) return;
      if (result.state != null) {
        _entries = result.state;
        _syncSettingsRevision(result.state!.revision);
        _saved = true;
      } else {
        _showProblem(result.problem);
      }
    });
  }

  Future<void> _toggle(bool enabled) async {
    final settings = _settings;
    if (!_canRequest || _busyNow || settings == null) return;
    if (enabled == settings.enabled) return;
    if (!enabled) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          key: const Key('auto-memory-disable-dialog'),
          title: const Text('关闭自动记忆采集？'),
          content: const Text('关闭后，后续消息不再自动采集；已采集的记忆会保留，不会自动重新开启。'),
          actions: [
            TextButton(
              key: const Key('auto-memory-disable-cancel'),
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('暂不关闭'),
            ),
            FilledButton(
              key: const Key('auto-memory-disable-confirm'),
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('确认关闭'),
            ),
          ],
        ),
      );
      if (approved == true && _current && identical(_settings, settings)) {
        await _setEnabled(settings, false);
      }
      return;
    }

    if (settings.target == null) return;
    final cancellation = HostReadCancellation();
    setState(() => _read = cancellation);
    final freshResult = await widget.api.readSettings(
      widget.profile,
      cancellation: cancellation,
    );
    if (!mounted || !identical(_read, cancellation)) return;
    setState(() => _read = null);
    if (!_current || freshResult.state == null) {
      setState(
        () => _readProblem =
            freshResult.problem ?? OwnerAutoMemoryProblem.unavailable,
      );
      return;
    }
    final fresh = freshResult.state!;
    setState(() => _settings = fresh);
    if (fresh.revision != settings.revision ||
        fresh.enabled != settings.enabled ||
        fresh.target == null ||
        !settings.target!.matches(fresh.target)) {
      setState(() {
        _settings = fresh;
        _showProblem(OwnerAutoMemoryProblem.conflict);
      });
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('auto-memory-enable-dialog'),
        title: const Text('允许自动记忆本人私聊？'),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('当前 AI：${widget.aiLabel}（${widget.profile}）'),
            const SizedBox(height: 8),
            const Text('范围：仅采集当前本人 AI 私聊中你本人的文字消息；不采集群聊或第三人内容，不主动发送或通知。'),
            const SizedBox(height: 8),
            const Text(
              '只有明确说“记住/记下/别忘了/以后/别忘”且长度有界的内容会立即生效；其余文字仅作为待确认保留，可在下方删除。',
            ),
            const SizedBox(height: 8),
            Text('接收方：${fresh.target!.providerId} / ${fresh.target!.model}'),
            Text('Origin：${fresh.target!.origin}'),
            const SizedBox(height: 8),
            const Text('授权只允许后续符合条件时采集与注入；不保证模型执行或送达。关闭后已采集内容保留。'),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('auto-memory-enable-cancel'),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('auto-memory-enable-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认允许'),
          ),
        ],
      ),
    );
    if (approved == true && _current && identical(_settings, fresh)) {
      await _setEnabled(fresh, true);
    }
  }

  Future<void> _setEnabled(
    OwnerAutoMemorySettings current,
    bool enabled,
  ) async {
    if (!_canRequest || _busyNow) return;
    setState(() {
      _busy = true;
      _notice = null;
      _writeProblem = null;
    });
    final result = await widget.api.setEnabled(
      widget.profile,
      current: current,
      enabled: enabled,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!_current) return;
      if (result.state != null) {
        _settings = result.state;
        _syncEntriesRevision(result.state!.revision);
        _saved = true;
      } else {
        _showProblem(result.problem);
      }
    });
  }

  /// Settings and entries share the same host revision; keep both in step so a
  /// later delete/clear CAS uses the revision the host actually recorded.
  void _syncSettingsRevision(int revision) {
    final settings = _settings;
    if (settings == null || settings.revision == revision) return;
    _settings = OwnerAutoMemorySettings(
      profileId: settings.profileId,
      revision: revision,
      enabled: settings.enabled,
      target: settings.target,
    );
  }

  void _syncEntriesRevision(int revision) {
    final entries = _entries;
    if (entries == null || entries.revision == revision) return;
    _entries = OwnerAutoMemoryList(
      profileId: entries.profileId,
      revision: revision,
      maxEntries: entries.maxEntries,
      entries: entries.entries,
    );
  }

  Widget _noticeText(String text, Key key, {bool error = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: JySpace.xs),
    child: AiConfigNoticeLine(text, textKey: key, problem: error),
  );

  String _problemText(OwnerAutoMemoryProblem problem) => switch (problem) {
    OwnerAutoMemoryProblem.conflict => '状态已发生变化。请重新读取；旧确认已作废。',
    OwnerAutoMemoryProblem.unknown => '提交结果未知，可能已经生效。请重新读取；不会自动重试。',
    OwnerAutoMemoryProblem.refused => '宿主拒绝更改，请检查权限后重新读取。',
    OwnerAutoMemoryProblem.unavailable => '无法读取或验证自动记忆状态。',
  };

  String _tierLabel(String tier) => tier == 't0' ? '明确记忆' : '普通陈述';
  String _statusLabel(String status) => status == 'active' ? '已生效' : '待确认';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!_current) return const SizedBox.shrink();
    final settings = _settings;
    final entries = _entries?.entries ?? const <OwnerAutoMemoryEntry>[];
    final canRequest = _canRequest && !_busyNow;
    final canWrite = canRequest && settings != null && _entries != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: JySlab(
        padding: EdgeInsets.zero,
        key: const Key('owner-auto-memory-section'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('自动记忆', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('默认关闭。开启后仅自动采集你本人与当前 AI 私聊中的文字；不采集群聊或第三人内容，不主动联系。'),
              const SizedBox(height: 8),
              if (_busyNow)
                const JyBusyIndicator(
                  key: Key('auto-memory-loading'),
                  label: '正在读取自动记忆',
                  linear: true,
                ),
              if (!widget.canContactHost() && !_busyNow)
                _noticeText(
                  '连接宿主后才能读取或修改自动记忆。',
                  const Key('auto-memory-offline'),
                  error: true,
                ),
              if (_notice != null)
                _noticeText(_notice!, const Key('auto-memory-saved')),
              if (_readProblem != null)
                _noticeText(
                  _problemText(_readProblem!),
                  const Key('auto-memory-read-error'),
                  error: true,
                ),
              if (_writeProblem != null)
                _noticeText(
                  _problemText(_writeProblem!),
                  const Key('auto-memory-write-error'),
                  error: true,
                ),
              if (_unknownProblem != null)
                _noticeText(
                  _problemText(_unknownProblem!),
                  const Key('auto-memory-unknown'),
                  error: true,
                ),
              if (settings == null &&
                  !_busyNow &&
                  _readProblem == null &&
                  _unknownProblem == null)
                const Text('尚未读取宿主状态。'),
              if (_saved)
                _noticeText('宿主已确认保存。', const Key('auto-memory-confirmed')),
              if (settings == null ||
                  _unknownProblem != null ||
                  _writeProblem == OwnerAutoMemoryProblem.conflict)
                OutlinedButton.icon(
                  key: const Key('auto-memory-read'),
                  onPressed: canRequest ? _load : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('读取当前设置'),
                ),
              if (settings != null) ...[
                SwitchListTile(
                  key: const Key('auto-memory-enabled'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('允许自动记忆本人私聊'),
                  subtitle: Text(
                    settings.enabled
                        ? '已授权；仅当前本人 AI 私聊采集，不保证执行或送达。'
                        : '未授权采集（默认关闭）。开启需单独确认当前接收条件。',
                  ),
                  value: settings.enabled,
                  onChanged:
                      canWrite && (settings.enabled || settings.target != null)
                      ? _toggle
                      : null,
                ),
                if (settings.target == null)
                  _noticeText(
                    '当前没有可用的本人私聊接收条件；可先读取，授权需等待条件出现。',
                    const Key('auto-memory-no-target'),
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '记忆 ${entries.length}/${_entries?.maxEntries ?? OwnerAutoMemoryApi.maxEntries} · 每条最多 ${OwnerAutoMemoryApi.maxEntryBytes} UTF-8 字节',
                      ),
                    ),
                  ],
                ),
                if (entries.isEmpty)
                  const Text('还没有采集到记忆。')
                else
                  for (final entry in entries)
                    ListTile(
                      key: Key('auto-memory-entry-${entry.id}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(entry.text),
                      subtitle: Text(
                        '${_tierLabel(entry.tier)} · ${_statusLabel(entry.status)} · ${entry.createdAt.toIso8601String()}',
                      ),
                      trailing: IconButton(
                        key: Key('auto-memory-delete-${entry.id}'),
                        tooltip: '删除记忆',
                        onPressed: canWrite ? () => _delete(entry) : null,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                if (entries.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const Key('auto-memory-clear'),
                      onPressed: canWrite ? _clear : null,
                      child: const Text('清空全部记忆'),
                    ),
                  ),
                const SizedBox(height: 4),
                const Text('关闭授权会保留已采集内容；清空不会关闭授权；重新开启必须再次确认当前接收条件。'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
