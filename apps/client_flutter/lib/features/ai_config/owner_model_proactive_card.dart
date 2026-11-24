import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/owner_model_proactive_api.dart';
import '../../ui/jy_tokens.dart';
import 'ai_config_problem_line.dart';

typedef _Schedule = ({
  int local,
  int? offset,
  int start,
  int end,
  int interval,
});
typedef _Review = ({OwnerModelProactiveSettings state, _Schedule schedule});

/// A profile-scoped permission editor for model-driven proactive contact.
/// The host alone can invoke the model and send a message; this widget never
/// initiates a message or changes direct-chat consent.
class OwnerModelProactiveCard extends StatefulWidget {
  const OwnerModelProactiveCard({
    super.key,
    required this.api,
    required this.profileId,
    required this.aiLabel,
    required this.isCurrent,
    required this.canContactHost,
  });

  final OwnerModelProactiveApi api;
  final String profileId;
  final String aiLabel;
  final bool Function() isCurrent;
  final bool Function() canContactHost;

  @override
  State<OwnerModelProactiveCard> createState() =>
      _OwnerModelProactiveCardState();
}

class _OwnerModelProactiveCardState extends State<OwnerModelProactiveCard>
    with AutomaticKeepAliveClientMixin<OwnerModelProactiveCard> {
  final _local = TextEditingController();
  final _offset = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  final _interval = TextEditingController();
  OwnerModelProactiveSettings? _state;
  _Review? _review;
  bool _globalReview = false;
  bool _busy = false;
  bool _readFailed = false;
  ProactiveProblem? _writeProblem;
  String? _notice;

  @override
  bool get wantKeepAlive => true;

  bool get _current => mounted && widget.isCurrent();
  bool get _canRequest =>
      _current &&
      widget.canContactHost() &&
      ModalRoute.isCurrentOf(context) == true;

  @override
  void dispose() {
    for (final field in [_local, _offset, _start, _end, _interval]) {
      field.dispose();
    }
    super.dispose();
  }

  static int? _minute(String raw) {
    final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(raw);
    if (match == null) return null;
    final hour = int.parse(match[1]!);
    final minute = int.parse(match[2]!);
    return hour < 24 && minute < 60 ? hour * 60 + minute : null;
  }

  static int? _fixedOffset(String raw) {
    final match = RegExp(r'^([+-])(\d{2}):(\d{2})$').firstMatch(raw);
    if (match == null) return null;
    final hours = int.parse(match[2]!);
    final minutes = int.parse(match[3]!);
    final total = hours * 60 + minutes;
    if (minutes >= 60 || total > 840) return null;
    return match[1] == '-' ? -total : total;
  }

  static int? _intervalMinutes(String raw) {
    final value = int.tryParse(raw);
    return value != null && value >= 60 && value <= 10080 ? value : null;
  }

  static String _time(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
  static String _signed(int minute) =>
      '${minute < 0 ? '-' : '+'}${_time(minute.abs())}';

  static _Schedule _saved(OwnerModelProactiveSettings state) => (
    local: state.localMinute,
    offset: state.offsetMinutes,
    start: state.quietStartMinute,
    end: state.quietEndMinute,
    interval: state.intervalMinutes,
  );

  _Schedule? get _draft {
    final local = _minute(_local.text);
    final offset = _fixedOffset(_offset.text);
    final start = _minute(_start.text);
    final end = _minute(_end.text);
    final interval = _intervalMinutes(_interval.text);
    if (local == null ||
        offset == null ||
        start == null ||
        end == null ||
        interval == null ||
        start == end) {
      return null;
    }
    return (
      local: local,
      offset: offset,
      start: start,
      end: end,
      interval: interval,
    );
  }

  void _remember(OwnerModelProactiveSettings state) {
    _state = state;
    _local.text = _time(state.localMinute);
    _offset.text = state.offsetMinutes == null
        ? ''
        : _signed(state.offsetMinutes!);
    _start.text = _time(state.quietStartMinute);
    _end.text = _time(state.quietEndMinute);
    _interval.text = '${state.intervalMinutes}';
    _writeProblem = null;
    _readFailed = false;
  }

  void _anchor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current && ModalRoute.isCurrentOf(context) == true) {
        Scrollable.ensureVisible(context, alignment: 0.03);
      }
    });
  }

  Future<void> _load({
    OwnerModelProactiveSettings? expected,
    _Schedule? schedule,
  }) async {
    if (!_canRequest || _busy || _review != null) return;
    final reviewing = schedule != null;
    if (reviewing &&
        (!identical(expected, _state) ||
            expected == null ||
            !expected.prerequisitesReady ||
            !expected.budgetReady ||
            _draft != schedule)) {
      return;
    }
    setState(() {
      _busy = true;
      _state = null;
      _readFailed = false;
      _notice = null;
      _globalReview = false;
    });
    final result = await widget.api.readSettings(widget.profileId);
    if (!_current) return;
    setState(() {
      _busy = false;
      if (!_canRequest || result is! ProactiveSettingsLoaded) {
        _readFailed = true;
        return;
      }
      final fresh = result.state;
      if (reviewing) {
        final original = expected!;
        if (fresh.revision != original.revision ||
            fresh.enabled != original.enabled ||
            fresh.chatRevision != original.chatRevision ||
            fresh.globalRevision != original.globalRevision ||
            fresh.socialLevel != original.socialLevel ||
            _saved(fresh) != _saved(original) ||
            !fresh.prerequisitesReady ||
            !fresh.budgetReady) {
          _writeProblem = ProactiveProblem.conflict;
          return;
        }
        _state = fresh;
        _review = (state: fresh, schedule: schedule);
      } else {
        _remember(fresh);
      }
    });
    _anchor();
  }

  Future<void> _write(
    OwnerModelProactiveSettings expected, {
    _Review? approval,
  }) async {
    if (!_canRequest || _busy || !identical(expected, _state)) return;
    final enabled = approval != null;
    if (enabled) {
      if (!identical(approval, _review) ||
          !identical(approval.state, expected) ||
          !expected.prerequisitesReady ||
          !expected.budgetReady) {
        return;
      }
    } else if (!expected.enabled || _review != null) {
      return;
    }
    final schedule = approval?.schedule ?? _saved(expected);
    setState(() {
      _busy = true;
      _state = null;
      _review = null;
      _notice = null;
      _globalReview = false;
    });
    final result = await widget.api.writeSettings(
      widget.profileId,
      current: expected,
      enabled: enabled,
      localMinute: schedule.local,
      offsetMinutes: schedule.offset,
      quietStartMinute: schedule.start,
      quietEndMinute: schedule.end,
      intervalMinutes: schedule.interval,
    );
    if (!_current) return;
    setState(() {
      _busy = false;
      if (result is ProactiveSettingsWritten) {
        _remember(result.state);
        _notice = enabled ? '授权已保存；不保证发送。' : '已关闭此 AI 的授权；原时间与频率设置已保留。';
      } else {
        _writeProblem = result is ProactiveUnavailable
            ? result.problem
            : ProactiveProblem.unknown;
      }
    });
    _anchor();
  }

  Future<void> _saveGlobal(OwnerModelProactiveSettings expected) async {
    if (!_canRequest ||
        _busy ||
        !_globalReview ||
        !identical(_state, expected)) {
      return;
    }
    setState(() {
      _busy = true;
      _state = null;
      _review = null;
      _globalReview = false;
      _notice = null;
    });
    final result = await widget.api.writeGlobalStop(
      current: GlobalProactiveStop(
        revision: expected.globalRevision,
        blocked: expected.globalBlocked,
      ),
      blocked: !expected.globalBlocked,
    );
    if (!_current) return;
    setState(() {
      _busy = false;
      if (result is! GlobalProactiveStopWritten) {
        _writeProblem = result is ProactiveUnavailable
            ? result.problem
            : ProactiveProblem.unknown;
        return;
      }
    });
    // Global stop also revokes the per-AI grant; re-read the fresh state.
    await _load();
  }

  String? _gate(OwnerModelProactiveSettings state) {
    if (state.globalBlocked) return '账户级停止已开启；解除后也不会自动恢复授权。';
    if (state.chatRevision == null) return '缺少有效的本人 AI 私聊许可。';
    if (!state.prerequisitesReady) return '仅社交等级 L3 或 L4 可授权。';
    if (!state.budgetReady) {
      return state.enabled ? '预算暂不可用；已保存授权不变，条件不满足的时段会跳过。' : '预算暂不可用；目前不能授权。';
    }
    return null;
  }

  Widget _field(
    String key,
    TextEditingController controller,
    String label,
    String hint, {
    required bool editable,
    String? error,
    bool offset = false,
    bool numeric = false,
  }) => TextField(
    key: Key('owner-model-proactive-$key'),
    controller: controller,
    enabled: editable,
    keyboardType: numeric ? TextInputType.number : TextInputType.text,
    autocorrect: false,
    enableSuggestions: false,
    inputFormatters: [
      LengthLimitingTextInputFormatter(
        offset
            ? 6
            : numeric
            ? 5
            : 5,
      ),
      if (numeric) FilteringTextInputFormatter.digitsOnly,
    ],
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      errorText: error,
    ),
    onChanged: (_) => setState(() => _notice = null),
  );

  Widget _note(String text, String key, {bool error = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: JySpace.xs),
    child: AiConfigNoticeLine(
      text,
      textKey: Key('owner-model-proactive-$key'),
      problem: error,
    ),
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!_current) return const SizedBox.shrink();
    final state = _state;
    final approval = _review;
    final draft = _draft;
    final canRequest = _canRequest && !_busy;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        key: const Key('owner-model-proactive-card'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('本人模型主动联系', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text(
                '默认关闭。开启后该 AI 会在 B3 预算内，于本人私聊中主动发出简短问候；使用模型但不会读取记忆或聊天历史，不保证发送，错过不补发。',
              ),
              if (_busy)
                const LinearProgressIndicator(semanticsLabel: '正在读取或提交模型主动联系'),
              if (!widget.canContactHost() && !_busy)
                _note('连接宿主后才能读取或修改。', 'offline'),
              if (_notice case final note?) _note(note, 'saved'),
              if (_writeProblem case final problem?)
                switch (problem) {
                  ProactiveProblem.unknown => _note(
                    '提交结果未知，可能已生效。请重新读取；不会自动重试。',
                    'unknown',
                    error: true,
                  ),
                  ProactiveProblem.conflict => _note(
                    '宿主状态或私聊条件已变化。请重新读取并再次确认。',
                    'conflict',
                    error: true,
                  ),
                  _ => _note('宿主拒绝更改。请检查权限并重新读取。', 'refused', error: true),
                },
              if (_readFailed)
                _note(
                  '无法验证宿主状态。宿主可能不支持该设置，或当前无法访问。',
                  'unavailable',
                  error: true,
                ),
              if (state == null &&
                  !_busy &&
                  !_readFailed &&
                  _writeProblem == null)
                const Text('尚未读取宿主授权状态。'),
              if (approval == null && state == null)
                TextButton.icon(
                  key: const Key('owner-model-proactive-read'),
                  onPressed: canRequest ? _load : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('读取当前主动联系设置'),
                ),
              if (state != null && approval == null) ...[
                _note(state.enabled ? '已授权模型主动联系' : '未授权模型主动联系', 'state'),
                if (_gate(state) case final gate?) _note(gate, 'gate'),
                _note(
                  '上次发送：${state.lastSentAt == null ? '尚未发送' : state.lastSentAt!.toLocal().toIso8601String()}',
                  'last-sent',
                ),
                _note(
                  '预算：${state.budgetReady ? 'B3 可用' : '暂不可用'} · 等级：${state.socialLevel ?? '未设置'}',
                  'budget-level',
                ),
                _note(
                  '静默窗：${_time(state.quietStartMinute)}–${_time(state.quietEndMinute)}${state.quietStartMinute > state.quietEndMinute ? '（跨午夜）' : ''}',
                  'quiet-status',
                ),
                const SizedBox(height: 8),
                _field(
                  'local',
                  _local,
                  '每日本地时间',
                  'HH:MM',
                  editable: canRequest,
                  error: _minute(_local.text) == null
                      ? '请输入 24 小时制时间，例如 09:00'
                      : null,
                ),
                const SizedBox(height: 8),
                _field(
                  'offset',
                  _offset,
                  '固定 UTC 偏移（必填）',
                  '+08:00',
                  editable: canRequest,
                  offset: true,
                  error:
                      _offset.text.isNotEmpty &&
                          _fixedOffset(_offset.text) == null
                      ? '请输入 ±HH:MM，范围为 ±14:00'
                      : null,
                ),
                const SizedBox(height: 4),
                const Text('请手动填写偏移；不会随旅行或夏令时自动调整。'),
                const SizedBox(height: 8),
                _field(
                  'quiet-start',
                  _start,
                  '静默开始',
                  'HH:MM',
                  editable: canRequest,
                  error: _minute(_start.text) == null ? '请输入 24 小时制时间' : null,
                ),
                const SizedBox(height: 8),
                _field(
                  'quiet-end',
                  _end,
                  '静默结束',
                  'HH:MM',
                  editable: canRequest,
                  error: _minute(_end.text) == null
                      ? '请输入 24 小时制时间'
                      : _minute(_start.text) == _minute(_end.text)
                      ? '结束必须不同于开始'
                      : null,
                ),
                const SizedBox(height: 4),
                const Text('静默可跨午夜。设定时刻落在静默内时，延至静默结束再判断；错过不补发。'),
                const SizedBox(height: 8),
                _field(
                  'interval',
                  _interval,
                  '最短间隔（分钟）',
                  '1440',
                  editable: canRequest,
                  numeric: true,
                  error: _intervalMinutes(_interval.text) == null
                      ? '请输入 60–10080 之间的整数分钟'
                      : null,
                ),
                const SizedBox(height: 4),
                const Text('两次主动联系之间的最短间隔，默认 1440（每天一次）。'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      key: const Key('owner-model-proactive-review'),
                      onPressed:
                          canRequest &&
                              draft != null &&
                              state.prerequisitesReady &&
                              state.budgetReady &&
                              (!state.enabled || draft != _saved(state))
                          ? () => _load(expected: state, schedule: draft)
                          : null,
                      child: Text(state.enabled ? '复核并保存设置' : '复核并授权'),
                    ),
                    if (state.enabled)
                      OutlinedButton(
                        key: const Key('owner-model-proactive-disable'),
                        onPressed: canRequest ? () => _write(state) : null,
                        child: const Text('关闭授权（保留设置）'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                const Divider(),
                SwitchListTile(
                  key: const Key('owner-model-proactive-global-stop'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('账户级停止全部模型主动联系'),
                  subtitle: Text(
                    state.globalBlocked
                        ? '已停止；解除后仍须逐个授权。'
                        : '未全局停止；不代表任何 AI 已获得授权。',
                  ),
                  value: state.globalBlocked,
                  onChanged: canRequest
                      ? (_) {
                          if (_canRequest &&
                              !_busy &&
                              !_globalReview &&
                              identical(_state, state)) {
                            setState(() => _globalReview = true);
                          }
                        }
                      : null,
                ),
              ],
              if (approval != null) ...[
                const SizedBox(height: 8),
                Text(
                  '确认本人私聊授权',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'AI：${widget.aiLabel} · ${widget.profileId}\n范围：仅当前符合条件的本人 AI 私聊\n等级：${approval.state.socialLevel} · 预算当前可用',
                ),
                const SizedBox(height: 8),
                Text(
                  '每日 ${_time(approval.schedule.local)}（UTC${_signed(approval.schedule.offset!)}）\n静默 ${_time(approval.schedule.start)}–${_time(approval.schedule.end)}${approval.schedule.start > approval.schedule.end ? '（跨午夜）' : ''}\n最短间隔 ${approval.schedule.interval} 分钟',
                ),
                const SizedBox(height: 8),
                const Text('静默内到期会延至静默结束再判断。仅保存使用模型的许可，不保证发送，错过不补发。'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      key: const Key('owner-model-proactive-cancel'),
                      onPressed: () {
                        setState(() => _review = null);
                        _anchor();
                      },
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      key: const Key('owner-model-proactive-confirm'),
                      onPressed: canRequest
                          ? () => _write(approval.state, approval: approval)
                          : null,
                      child: Text(approval.state.enabled ? '确认保存设置' : '确认授权'),
                    ),
                  ],
                ),
              ],
              if (_globalReview && state != null) ...[
                const SizedBox(height: 8),
                Text(
                  state.globalBlocked ? '解除账户级停止？' : '停止全部模型主动联系？',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  state.globalBlocked
                      ? '只解除账户级阻断，不会开启任何 AI 的主动联系。'
                      : '撤回所有 AI 当前的主动联系授权，保留时间与频率设置。再次开启须逐个确认。',
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      key: const Key('owner-model-proactive-global-cancel'),
                      onPressed: () => setState(() => _globalReview = false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      key: const Key('owner-model-proactive-global-confirm'),
                      onPressed: canRequest ? () => _saveGlobal(state) : null,
                      child: Text(state.globalBlocked ? '确认解除' : '确认停止'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
