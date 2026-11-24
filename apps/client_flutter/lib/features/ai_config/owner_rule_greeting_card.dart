import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/owner_rule_greeting_api.dart';
import '../../ui/jy_tokens.dart';
import 'ai_config_problem_line.dart';

typedef _Schedule = ({int local, int? offset, int start, int end});
typedef _Review = ({OwnerRuleGreetingSettings state, _Schedule schedule});

/// A profile-scoped permission editor. The host alone can evaluate and send a
/// greeting; this widget never initiates a message or changes direct-chat consent.
class OwnerRuleGreetingCard extends StatefulWidget {
  const OwnerRuleGreetingCard({
    super.key,
    required this.api,
    required this.profileId,
    required this.aiLabel,
    required this.isCurrent,
    required this.canContactHost,
  });

  final OwnerRuleGreetingApi api;
  final String profileId;
  final String aiLabel;
  final bool Function() isCurrent;
  final bool Function() canContactHost;

  @override
  State<OwnerRuleGreetingCard> createState() => _OwnerRuleGreetingCardState();
}

class _OwnerRuleGreetingCardState extends State<OwnerRuleGreetingCard>
    with AutomaticKeepAliveClientMixin<OwnerRuleGreetingCard> {
  final _local = TextEditingController();
  final _offset = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  OwnerRuleGreetingSettings? _state;
  _Review? _review;
  bool _busy = false;
  bool _readFailed = false;
  GreetingProblem? _writeProblem;
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
    for (final field in [_local, _offset, _start, _end]) {
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

  static String _time(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
  static String _signed(int minute) =>
      '${minute < 0 ? '-' : '+'}${_time(minute.abs())}';

  static _Schedule _saved(OwnerRuleGreetingSettings state) => (
    local: state.localMinute,
    offset: state.offsetMinutes,
    start: state.quietStartMinute,
    end: state.quietEndMinute,
  );

  _Schedule? get _draft {
    final local = _minute(_local.text);
    final offset = _fixedOffset(_offset.text);
    final start = _minute(_start.text);
    final end = _minute(_end.text);
    if (local == null ||
        offset == null ||
        start == null ||
        end == null ||
        start == end) {
      return null;
    }
    return (local: local, offset: offset, start: start, end: end);
  }

  void _remember(OwnerRuleGreetingSettings state) {
    _state = state;
    _local.text = _time(state.localMinute);
    _offset.text = state.offsetMinutes == null
        ? ''
        : _signed(state.offsetMinutes!);
    _start.text = _time(state.quietStartMinute);
    _end.text = _time(state.quietEndMinute);
    _writeProblem = null;
    _readFailed = false;
  }

  // A review replaces the form. Keep the relevant controls on-screen when the
  // card changes height inside the existing editor's scroll view.
  void _anchor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current && ModalRoute.isCurrentOf(context) == true) {
        Scrollable.ensureVisible(context, alignment: 0.03);
      }
    });
  }

  Future<void> _load({
    OwnerRuleGreetingSettings? expected,
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
    });
    final result = await widget.api.readSettings(widget.profileId);
    if (!_current) return;
    setState(() {
      _busy = false;
      if (!_canRequest || result is! GreetingSettingsLoaded) {
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
          _writeProblem = GreetingProblem.conflict;
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
    OwnerRuleGreetingSettings expected, {
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
    });
    final result = await widget.api.writeSettings(
      widget.profileId,
      current: expected,
      enabled: enabled,
      localMinute: schedule.local,
      offsetMinutes: schedule.offset,
      quietStartMinute: schedule.start,
      quietEndMinute: schedule.end,
    );
    if (!_current) return;
    setState(() {
      _busy = false;
      if (result is GreetingSettingsWritten) {
        _remember(result.state);
        _notice = enabled ? '授权已保存；不保证发送。' : '已关闭此 AI 的授权；原时间设置已保留。';
      } else {
        _writeProblem = result is GreetingUnavailable
            ? result.problem
            : GreetingProblem.unknown;
      }
    });
    _anchor();
  }

  String? _gate(OwnerRuleGreetingSettings state) {
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
  }) => TextField(
    key: Key('owner-rule-greeting-$key'),
    controller: controller,
    enabled: editable,
    keyboardType: TextInputType.text,
    autocorrect: false,
    enableSuggestions: false,
    inputFormatters: [LengthLimitingTextInputFormatter(offset ? 6 : 5)],
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
      textKey: Key('owner-rule-greeting-$key'),
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
        key: const Key('owner-rule-greeting-card'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('本人规则问候', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('默认关闭，仅允许该 AI 在本人私聊中使用固定问候。不使用模型或聊天历史，不保证发送。'),
              if (_busy)
                const LinearProgressIndicator(semanticsLabel: '正在读取或提交规则问候'),
              if (!widget.canContactHost() && !_busy)
                _note('连接宿主后才能读取或修改。', 'offline'),
              if (_notice case final note?) _note(note, 'saved'),
              if (_writeProblem case final problem?)
                switch (problem) {
                  GreetingProblem.unknown => _note(
                    '提交结果未知，可能已生效。请重新读取；不会自动重试。',
                    'unknown',
                    error: true,
                  ),
                  GreetingProblem.conflict => _note(
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
              if (approval == null)
                TextButton.icon(
                  key: const Key('owner-rule-greeting-read'),
                  onPressed: canRequest ? _load : null,
                  icon: const Icon(Icons.refresh),
                  label: Text(state == null ? '读取当前问候设置' : '重新读取'),
                ),
              if (state != null && approval == null) ...[
                _note(state.enabled ? '已授权规则问候' : '未授权规则问候', 'state'),
                if (_gate(state) case final gate?) _note(gate, 'gate'),
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
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      key: const Key('owner-rule-greeting-review'),
                      onPressed:
                          canRequest &&
                              draft != null &&
                              state.prerequisitesReady &&
                              state.budgetReady &&
                              (!state.enabled || draft != _saved(state))
                          ? () => _load(expected: state, schedule: draft)
                          : null,
                      child: Text(state.enabled ? '复核并保存时间' : '复核并授权'),
                    ),
                    if (state.enabled)
                      OutlinedButton(
                        key: const Key('owner-rule-greeting-disable'),
                        onPressed: canRequest ? () => _write(state) : null,
                        child: const Text('关闭授权（保留时间）'),
                      ),
                  ],
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
                  '每日 ${_time(approval.schedule.local)}（UTC${_signed(approval.schedule.offset!)}）\n静默 ${_time(approval.schedule.start)}–${_time(approval.schedule.end)}${approval.schedule.start > approval.schedule.end ? '（跨午夜）' : ''}',
                ),
                const SizedBox(height: 8),
                const Text('静默内到期会延至静默结束再判断。仅保存使用固定问候的许可，不保证发送，错过不补发。'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      key: const Key('owner-rule-greeting-cancel'),
                      onPressed: () {
                        setState(() => _review = null);
                        _anchor();
                      },
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      key: const Key('owner-rule-greeting-confirm'),
                      onPressed: canRequest
                          ? () => _write(approval.state, approval: approval)
                          : null,
                      child: Text(approval.state.enabled ? '确认保存时间' : '确认授权'),
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
