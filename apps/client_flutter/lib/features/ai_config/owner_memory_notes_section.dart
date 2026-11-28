import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../net/host_connection.dart' show HostReadCancellation;
import '../../net/owner_memory_notes_api.dart';
import '../../ui/ui.dart';
import 'ai_config_problem_line.dart';

/// Manual notes are independent from chat history, reply preferences and the
/// fixed rule greeting. The permission is default-off and only owner-private.
class OwnerMemoryNotesSection extends StatefulWidget {
  const OwnerMemoryNotesSection({
    super.key,
    required this.api,
    required this.profile,
    required this.aiLabel,
    required this.isCurrent,
    required this.canContactHost,
  });

  final OwnerMemoryNotesApi api;
  final String profile;
  final String aiLabel;
  final bool Function() isCurrent;
  final bool Function() canContactHost;

  @override
  State<OwnerMemoryNotesSection> createState() =>
      _OwnerMemoryNotesSectionState();
}

class _OwnerMemoryNotesSectionState extends State<OwnerMemoryNotesSection>
    with AutomaticKeepAliveClientMixin<OwnerMemoryNotesSection> {
  final _add = TextEditingController();
  final _edit = TextEditingController();
  OwnerMemoryNotes? _state;
  OwnerMemoryProblem? _readProblem;
  OwnerMemoryProblem? _writeProblem;
  OwnerMemoryProblem? _unknownProblem;
  String? _notice;
  String? _validation;
  String? _editingId;
  bool _addOpen = false;
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
    _add.dispose();
    _edit.dispose();
    super.dispose();
  }

  void _remember(OwnerMemoryNotes state) {
    _state = state;
    _readProblem = null;
    _writeProblem = null;
    _unknownProblem = null;
    _notice = null;
    _validation = null;
    _saved = false;
    _editingId = null;
  }

  void _showProblem(OwnerMemoryProblem? problem) {
    if (problem == null) return;
    if (problem == OwnerMemoryProblem.unknown ||
        problem == OwnerMemoryProblem.conflict) {
      _state = null;
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
      _state = null;
      _readProblem = null;
      _writeProblem = null;
      _unknownProblem = null;
      _notice = null;
      _validation = null;
      _editingId = null;
    });
    final result = await widget.api.read(profile, cancellation: cancellation);
    if (!mounted || !identical(_read, cancellation)) return;
    setState(() {
      _read = null;
      if (!_current || result.state == null) {
        _readProblem = result.problem ?? OwnerMemoryProblem.unavailable;
        return;
      }
      _remember(result.state!);
    });
  }

  Future<void> _addNote() async {
    final state = _state;
    if (!_canRequest || _busyNow || state == null) return;
    final normalized = OwnerMemoryNotes.normalizeText(
      _add.text,
      state.maxNoteBytes,
    );
    if (normalized == null) {
      setState(
        () => _validation =
            '请输入非空的单条便签，最多 ${state.maxNoteBytes} 个 UTF-8 字节，不能包含控制字符。',
      );
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
      _validation = null;
      _writeProblem = null;
    });
    final result = await widget.api.add(
      widget.profile,
      current: state,
      text: normalized,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!_current) return;
      if (result.state != null) {
        _remember(result.state!);
        _add.clear();
        _addOpen = false;
        _saved = true;
      } else {
        _showProblem(result.problem);
      }
    });
  }

  void _beginEdit(OwnerMemoryNote note) {
    if (!_canRequest || _busyNow || _editingId != null) return;
    setState(() {
      _editingId = note.id;
      _edit.text = note.text;
      _validation = null;
      _notice = null;
    });
  }

  Future<void> _saveEdit() async {
    final state = _state;
    final noteId = _editingId;
    if (!_canRequest || _busyNow || state == null || noteId == null) return;
    final normalized = OwnerMemoryNotes.normalizeText(
      _edit.text,
      state.maxNoteBytes,
    );
    if (normalized == null) {
      setState(
        () => _validation =
            '请输入非空的单条便签，最多 ${state.maxNoteBytes} 个 UTF-8 字节，不能包含控制字符。',
      );
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
      _validation = null;
      _writeProblem = null;
    });
    final result = await widget.api.edit(
      widget.profile,
      current: state,
      noteId: noteId,
      text: normalized,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!_current) return;
      if (result.state != null) {
        _remember(result.state!);
        _saved = true;
      } else {
        _showProblem(result.problem);
      }
    });
  }

  Future<void> _delete(OwnerMemoryNote note) async {
    final state = _state;
    if (!_canRequest || _busyNow || state == null) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('memory-notes-delete-dialog'),
        title: const Text('删除这条便签？'),
        content: Text('将删除「${note.text}」，不影响已保存的使用授权。'),
        actions: [
          TextButton(
            key: const Key('memory-notes-delete-cancel'),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('保留'),
          ),
          FilledButton(
            key: const Key('memory-notes-delete-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (approved != true || !_current || !identical(_state, state)) return;
    setState(() {
      _busy = true;
      _notice = null;
      _writeProblem = null;
    });
    final result = await widget.api.delete(
      widget.profile,
      current: state,
      noteId: note.id,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!_current) return;
      if (result.state != null) {
        _remember(result.state!);
        _saved = true;
      } else {
        _showProblem(result.problem);
      }
    });
  }

  Future<void> _clear() async {
    final state = _state;
    if (!_canRequest || _busyNow || state == null || state.notes.isEmpty) {
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('memory-notes-clear-dialog'),
        title: const Text('清空全部便签？'),
        content: const Text('这会删除所有手动便签，但不会关闭“允许在本人私聊回复中使用便签”的授权。'),
        actions: [
          TextButton(
            key: const Key('memory-notes-clear-cancel'),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('保留'),
          ),
          FilledButton(
            key: const Key('memory-notes-clear-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (approved != true || !_current || !identical(_state, state)) return;
    setState(() {
      _busy = true;
      _notice = null;
      _writeProblem = null;
    });
    final result = await widget.api.clear(widget.profile, current: state);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!_current) return;
      if (result.state != null) {
        _remember(result.state!);
        _saved = true;
      } else {
        _showProblem(result.problem);
      }
    });
  }

  Future<void> _toggle(bool enabled) async {
    final state = _state;
    if (!_canRequest || _busyNow || state == null) return;
    if (enabled == state.enabled) return;
    if (!enabled) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          key: const Key('memory-notes-disable-dialog'),
          title: const Text('关闭便签使用授权？'),
          content: const Text('关闭后，后续回复不会使用这些便签；便签本身会保留，不会自动重新开启。'),
          actions: [
            TextButton(
              key: const Key('memory-notes-disable-cancel'),
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('暂不关闭'),
            ),
            FilledButton(
              key: const Key('memory-notes-disable-confirm'),
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('确认关闭'),
            ),
          ],
        ),
      );
      if (approved == true && _current && identical(_state, state)) {
        await _setEnabled(state, false);
      }
      return;
    }

    // Enabling must be reviewed against a fresh target snapshot, not stale UI.
    if (state.target == null) return;
    final cancellation = HostReadCancellation();
    setState(() => _read = cancellation);
    final freshResult = await widget.api.read(
      widget.profile,
      cancellation: cancellation,
    );
    if (!mounted || !identical(_read, cancellation)) return;
    setState(() => _read = null);
    if (!_current || freshResult.state == null) {
      setState(
        () => _readProblem =
            freshResult.problem ?? OwnerMemoryProblem.unavailable,
      );
      return;
    }
    final fresh = freshResult.state!;
    setState(() => _state = fresh);
    if (fresh.revision != state.revision ||
        fresh.enabled != state.enabled ||
        fresh.target == null ||
        !state.target!.matches(fresh.target)) {
      setState(() {
        _state = fresh;
        _showProblem(OwnerMemoryProblem.conflict);
      });
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('memory-notes-enable-dialog'),
        title: const Text('允许在本人私聊回复中使用便签？'),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('当前 AI：${widget.aiLabel}（${widget.profile}）'),
            const SizedBox(height: 8),
            const Text('范围：仅当前本人 AI 私聊；不是聊天历史，不读取群聊或第三人内容，不会主动发送或通知。'),
            const SizedBox(height: 8),
            Text('接收方：${fresh.target!.providerId} / ${fresh.target!.model}'),
            Text('Origin：${fresh.target!.origin}'),
            const SizedBox(height: 8),
            const Text('授权只允许后续符合条件的回复使用这些便签；不保证模型执行或送达。关闭后便签保留。'),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('memory-notes-enable-cancel'),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('memory-notes-enable-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认允许'),
          ),
        ],
      ),
    );
    if (approved == true && _current && identical(_state, fresh)) {
      await _setEnabled(fresh, true);
    }
  }

  Future<void> _setEnabled(OwnerMemoryNotes current, bool enabled) async {
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
        _remember(result.state!);
        _saved = true;
      } else {
        _showProblem(result.problem);
      }
    });
  }

  Widget _noticeText(String text, Key key, {bool error = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: JySpace.xs),
    child: AiConfigNoticeLine(text, textKey: key, problem: error),
  );

  String _problemText(OwnerMemoryProblem problem) => switch (problem) {
    OwnerMemoryProblem.conflict => '状态已发生变化。请重新读取；旧确认已作废。',
    OwnerMemoryProblem.unknown => '提交结果未知，可能已经生效。请重新读取；不会自动重试。',
    OwnerMemoryProblem.refused => '宿主拒绝更改，请检查权限后重新读取。',
    OwnerMemoryProblem.unavailable => '无法读取或验证记忆便签状态。',
  };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!_current) return const SizedBox.shrink();
    final state = _state;
    final notes = state?.notes ?? const <OwnerMemoryNote>[];
    final canRequest = _canRequest && !_busyNow;
    final canWrite = canRequest && state != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: JySlab(
        padding: EdgeInsets.zero,
        key: const Key('owner-memory-notes-section'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('记忆便签', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('仅你手动保存的非敏感文字便签；不是聊天记录，也不会自动采集、读取历史、群聊或第三人内容，不会主动联系。'),
              const SizedBox(height: 8),
              if (_busyNow)
                const JyBusyIndicator(
                  key: Key('memory-notes-loading'),
                  label: '正在读取便签',
                  linear: true,
                ),
              if (!widget.canContactHost() && !_busyNow)
                _noticeText(
                  '连接宿主后才能读取或修改便签。',
                  const Key('memory-notes-offline'),
                  error: true,
                ),
              if (_notice != null)
                _noticeText(_notice!, const Key('memory-notes-saved')),
              if (_readProblem != null)
                _noticeText(
                  _problemText(_readProblem!),
                  const Key('memory-notes-read-error'),
                  error: true,
                ),
              if (_writeProblem != null)
                _noticeText(
                  _problemText(_writeProblem!),
                  const Key('memory-notes-write-error'),
                  error: true,
                ),
              if (_unknownProblem != null)
                _noticeText(
                  _problemText(_unknownProblem!),
                  const Key('memory-notes-unknown'),
                  error: true,
                ),
              if (state == null &&
                  !_busyNow &&
                  _readProblem == null &&
                  _unknownProblem == null)
                const Text('尚未读取宿主状态。'),
              if (_saved)
                _noticeText('宿主已确认保存。', const Key('memory-notes-confirmed')),
              if (state == null ||
                  _unknownProblem != null ||
                  _writeProblem == OwnerMemoryProblem.conflict)
                OutlinedButton.icon(
                  key: const Key('memory-notes-read'),
                  onPressed: canRequest ? _load : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('读取当前设置'),
                ),
              if (state != null) ...[
                SwitchListTile(
                  key: const Key('memory-notes-enabled'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('允许在本人私聊回复中使用这些便签'),
                  subtitle: Text(
                    state.enabled
                        ? '已授权；仅当前本人 AI 私聊使用，不保证执行或送达。'
                        : '未授权使用（默认关闭）。便签可先保存，授权需单独确认。',
                  ),
                  value: state.enabled,
                  onChanged: canWrite && (state.enabled || state.target != null)
                      ? _toggle
                      : null,
                ),
                if (state.target == null)
                  _noticeText(
                    '当前没有可用的本人私聊接收条件；可先保存便签，授权需等待条件出现。',
                    const Key('memory-notes-no-target'),
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '便签 ${notes.length}/${state.maxNotes} · 每条最多 ${state.maxNoteBytes} UTF-8 字节',
                      ),
                    ),
                    if (canWrite && !_addOpen && notes.length < state.maxNotes)
                      TextButton.icon(
                        key: const Key('memory-notes-add'),
                        onPressed: () => setState(() {
                          _addOpen = true;
                          _editingId = null;
                          _validation = null;
                        }),
                        icon: const Icon(Icons.add),
                        label: const Text('添加'),
                      ),
                  ],
                ),
                if (_addOpen) ...[
                  TextField(
                    key: const Key('memory-notes-add-text'),
                    controller: _add,
                    maxLines: 1,
                    onChanged: (_) => setState(() => _validation = null),
                    decoration: const InputDecoration(
                      labelText: '新便签（单行）',
                      hintText: '非敏感、可公开的简短文字',
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        key: const Key('memory-notes-add-cancel'),
                        onPressed: canWrite
                            ? () => setState(() => _addOpen = false)
                            : null,
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        key: const Key('memory-notes-add-save'),
                        onPressed: canWrite ? _addNote : null,
                        child: const Text('保存便签'),
                      ),
                    ],
                  ),
                ],
                if (_validation != null)
                  _noticeText(
                    _validation!,
                    const Key('memory-notes-validation'),
                    error: true,
                  ),
                if (notes.isEmpty)
                  const Text('还没有便签。')
                else
                  for (final note in notes) ...[
                    if (_editingId == note.id) ...[
                      TextField(
                        key: const Key('memory-notes-edit-text'),
                        controller: _edit,
                        maxLines: 1,
                        onChanged: (_) => setState(() => _validation = null),
                        decoration: const InputDecoration(
                          labelText: '编辑便签（单行）',
                        ),
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            key: const Key('memory-notes-edit-cancel'),
                            onPressed: canWrite
                                ? () => setState(() => _editingId = null)
                                : null,
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            key: const Key('memory-notes-edit-save'),
                            onPressed: canWrite ? _saveEdit : null,
                            child: const Text('保存修改'),
                          ),
                        ],
                      ),
                    ] else
                      ListTile(
                        key: Key('memory-notes-note-${note.id}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(note.text),
                        subtitle: Text(
                          '更新于 ${note.updatedAt.toIso8601String()}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: Key('memory-notes-edit-${note.id}'),
                              tooltip: '编辑便签',
                              onPressed: canWrite
                                  ? () => _beginEdit(note)
                                  : null,
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              key: Key('memory-notes-delete-${note.id}'),
                              tooltip: '删除便签',
                              onPressed: canWrite ? () => _delete(note) : null,
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                  ],
                if (notes.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const Key('memory-notes-clear'),
                      onPressed: canWrite ? _clear : null,
                      child: const Text('清空全部便签'),
                    ),
                  ),
                const SizedBox(height: 4),
                const Text('关闭授权会保留便签；清空便签不会关闭授权；重新开启必须再次确认当前接收条件。'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
