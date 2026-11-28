import 'package:material_ui/material_ui.dart';

import '../../net/host_connection.dart' show HostReadCancellation;
import '../../net/owner_reply_preferences_api.dart';
import '../../ui/ui.dart';
import 'ai_config_problem_line.dart';

/// Inline review intentionally stays within the selected profile's widget:
/// changing account/profile or locking the editor discards the whole review.
class OwnerReplyPreferencesSection extends StatefulWidget {
  const OwnerReplyPreferencesSection({
    super.key,
    required this.api,
    required this.profile,
    required this.isCurrent,
    required this.canContactHost,
  });

  final OwnerReplyPreferencesApi api;
  final String profile;
  final bool Function() isCurrent;
  final bool Function() canContactHost;

  @override
  State<OwnerReplyPreferencesSection> createState() =>
      _OwnerReplyPreferencesSectionState();
}

enum _Action { enable, saveOff, disable, clear }

final class _Review {
  const _Review(this.state, this.length, this.format);

  final OwnerReplyPreferences state;
  final OwnerReplyLength? length;
  final OwnerReplyFormat? format;
}

class _OwnerReplyPreferencesSectionState
    extends State<OwnerReplyPreferencesSection>
    with AutomaticKeepAliveClientMixin<OwnerReplyPreferencesSection> {
  @override
  bool get wantKeepAlive => true;
  OwnerReplyPreferences? _state;
  OwnerReplyLength? _length;
  OwnerReplyFormat? _format;
  _Review? _review;
  bool _clearPending = false;
  bool _saving = false;
  bool _saved = false;
  bool _targetMissing = false;
  OwnerReplyPreferenceProblem? _readProblem;
  OwnerReplyPreferenceProblem? _writeProblem;
  HostReadCancellation? _read;

  bool get _current => mounted && widget.isCurrent();
  bool get _canRequest =>
      _current &&
      widget.canContactHost() &&
      ModalRoute.isCurrentOf(context) == true;
  bool get _busy => _read != null || _saving;
  bool get _dirty => _length != _state?.length || _format != _state?.format;
  bool get _draftEmpty => _length == null && _format == null;

  @override
  void dispose() {
    _read?.cancel();
    super.dispose();
  }

  // Collapsing a form after a click changes the sliver height. Anchor the
  // result/review so the current state does not scroll away from that click.
  void _showSection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current && ModalRoute.isCurrentOf(context) == true) {
        Scrollable.ensureVisible(context, alignment: 0.04);
      }
    });
  }

  void _remember(OwnerReplyPreferences state) {
    _state = state;
    _length = state.length;
    _format = state.format;
    _readProblem = null;
    _writeProblem = null;
  }

  Future<void> _load({bool review = false}) async {
    if (!_canRequest || _busy) return;
    final original = _state;
    if (review &&
        (original == null || _draftEmpty || original.target == null)) {
      return;
    }
    final length = _length;
    final format = _format;
    final cancellation = HostReadCancellation();
    setState(() {
      _read = cancellation;
      _readProblem = null;
      _saved = false;
      _targetMissing = false;
      _review = null;
      _clearPending = false;
      _state = null; // Do not present stale authorization while re-reading.
    });
    _showSection();
    final result = await widget.api.read(
      widget.profile,
      cancellation: cancellation,
    );
    if (!_current || !identical(_read, cancellation)) return;
    setState(() {
      _read = null;
      if (!_canRequest || result.state == null) {
        _readProblem =
            result.problem ?? OwnerReplyPreferenceProblem.unavailable;
        return;
      }
      final fresh = result.state!;
      if (review &&
          (fresh.revision != original!.revision ||
              fresh.enabled != original.enabled ||
              fresh.length != original.length ||
              fresh.format != original.format)) {
        _writeProblem = OwnerReplyPreferenceProblem.conflict;
        return;
      }
      _remember(fresh);
      if (review) {
        _length = length;
        _format = format;
        if (fresh.target != null) {
          _review = _Review(fresh, length, format);
        } else {
          _targetMissing = true;
        }
      }
    });
    _showSection();
  }

  Future<void> _submit(
    _Action action,
    OwnerReplyPreferences expected, {
    _Review? offer,
  }) async {
    // Old callbacks may still exist between frames. Neither a retired editor
    // nor an earlier read of the same profile is an approval for this write.
    if (!_canRequest || _busy || !identical(expected, _state)) return;
    final OwnerReplyLength? length;
    final OwnerReplyFormat? format;
    switch (action) {
      case _Action.enable:
        if (offer == null ||
            !identical(offer, _review) ||
            !identical(offer.state, expected) ||
            expected.target == null) {
          return;
        }
        length = offer.length;
        format = offer.format;
      case _Action.saveOff:
        if (expected.enabled ||
            !_dirty ||
            _draftEmpty ||
            _review != null ||
            _clearPending) {
          return;
        }
        length = _length;
        format = _format;
      case _Action.disable:
        if (!expected.enabled || _review != null || _clearPending) return;
        length = expected.length;
        format = expected.format;
      case _Action.clear:
        if (expected.enabled || !_clearPending || _review != null) return;
        length = null;
        format = null;
    }
    setState(() {
      _saving = true;
      _saved = false;
      _review = null;
      _clearPending = false;
      _readProblem = null;
      _writeProblem = null;
      _targetMissing = false;
      _state = null;
    });
    _showSection();
    final result = await widget.api.save(
      widget.profile,
      current: expected,
      enabled: action == _Action.enable,
      length: length,
      format: format,
    );
    if (!_current) return;
    setState(() {
      _saving = false;
      if (result.state case final confirmed?) {
        _remember(confirmed);
        _saved = true;
      } else {
        _writeProblem = result.problem ?? OwnerReplyPreferenceProblem.unknown;
      }
    });
    _showSection();
  }

  void _change(VoidCallback apply) {
    if (!_current ||
        _busy ||
        _state == null ||
        _review != null ||
        _clearPending) {
      return;
    }
    setState(() {
      apply();
      _saved = false;
    });
  }

  Widget _note(String text, String key, {bool error = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: JySpace.xs),
    child: AiConfigNoticeLine(text, textKey: Key(key), problem: error),
  );

  static String _lengthLabel(OwnerReplyLength? value) => switch (value) {
    null => '不指定',
    OwnerReplyLength.brief => '简短',
    OwnerReplyLength.detailed => '详细',
  };

  static String _formatLabel(OwnerReplyFormat? value) => switch (value) {
    null => '不指定',
    OwnerReplyFormat.paragraphs => '分段',
    OwnerReplyFormat.bullets => '要点',
  };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Do not let a first-frame lock expose an already held receipt.
    if (!_current) return const SizedBox.shrink();
    final canRequest = _canRequest;
    final state = _state;
    final review = _review;
    final target = review?.state.target ?? state?.target;
    final editing = state != null && !_busy && review == null && !_clearPending;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: JySlab(
        padding: EdgeInsets.zero,
        key: const Key('owner-reply-preferences-section'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('私聊回复偏好', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('独立授权，默认关闭。仅保存回复长短和排版；不读取历史、不保存任意文字，不用于群聊或主动联系。'),
              const SizedBox(height: 8),
              if (_busy)
                JyBusyIndicator(
                  label: _saving ? '正在提交回复偏好' : '正在读取回复偏好',
                  linear: true,
                ),
              if (!canRequest && !_busy)
                _note('连接宿主后才能读取或更改授权。', 'owner-reply-preferences-offline'),
              if (state != null)
                _note(
                  state.enabled ? '已授权自动使用' : '未授权自动使用',
                  'owner-reply-preferences-state',
                ),
              if (state == null &&
                  !_busy &&
                  _readProblem == null &&
                  _writeProblem == null)
                const Text('尚未读取宿主状态。'),
              if (_writeProblem case final problem?)
                switch (problem) {
                  OwnerReplyPreferenceProblem.conflict => _note(
                    '版本或接收方已变化。请重新读取；再次授权需重新确认。',
                    'owner-reply-preferences-conflict',
                    error: true,
                  ),
                  OwnerReplyPreferenceProblem.unknown => _note(
                    '提交结果未知；可能已生效。请重新读取当前状态，不会自动重试。',
                    'owner-reply-preferences-unknown',
                    error: true,
                  ),
                  _ => _note(
                    '宿主拒绝更改。请检查账号或权限后重新读取。',
                    'owner-reply-preferences-refused',
                    error: true,
                  ),
                },
              if (_readProblem case final problem?)
                _note(
                  problem == OwnerReplyPreferenceProblem.refused
                      ? '宿主未提供此档案的回复偏好或未授权访问。'
                      : '无法读取并验证宿主状态。',
                  'owner-reply-preferences-unavailable',
                  error: true,
                ),
              if (_saved) _note('宿主已确认保存。', 'owner-reply-preferences-saved'),
              if (state == null || (review == null && !_clearPending))
                OutlinedButton.icon(
                  key: const Key('owner-reply-preferences-read'),
                  onPressed: canRequest && !_busy ? () => _load() : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('读取当前状态'),
                ),
              if (state != null && target == null)
                _note(
                  _targetMissing
                      ? '接收方已不可用，本次未授权。'
                      : '暂无可授权的接收方。需要本人 AI 私聊许可与有效的聊天模型绑定。',
                  'owner-reply-preferences-no-target',
                ),
              if (state != null && review == null && !_clearPending) ...[
                if (state.enabled && target != null) _TargetDetails(target),
                const SizedBox(height: 8),
                const Text('回复长短'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final option in <OwnerReplyLength?>[
                      null,
                      ...OwnerReplyLength.values,
                    ])
                      ChoiceChip(
                        key: Key(
                          'owner-reply-length-${option?.name ?? 'none'}',
                        ),
                        label: Text(_lengthLabel(option)),
                        selected: _length == option,
                        onSelected: editing
                            ? (_) => _change(() => _length = option)
                            : null,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('排版'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final option in <OwnerReplyFormat?>[
                      null,
                      ...OwnerReplyFormat.values,
                    ])
                      ChoiceChip(
                        key: Key(
                          'owner-reply-format-${option?.name ?? 'none'}',
                        ),
                        label: Text(_formatLabel(option)),
                        selected: _format == option,
                        onSelected: editing
                            ? (_) => _change(() => _format = option)
                            : null,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_dirty) ...[
                  Text(
                    '已保存：${_lengthLabel(state.length)} · ${_formatLabel(state.format)}',
                  ),
                  const Text('当前选择尚未保存。'),
                ],
                if (_dirty && _draftEmpty)
                  const Text('如需清除两项，请先关闭授权，再点「清除已保存偏好」。'),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilledButton(
                      key: const Key('owner-reply-preferences-review'),
                      onPressed:
                          canRequest &&
                              editing &&
                              !_draftEmpty &&
                              target != null &&
                              (!state.enabled || _dirty)
                          ? () => _load(review: true)
                          : null,
                      child: Text(state.enabled ? '确认并更新偏好' : '查看接收方并授权'),
                    ),
                    if (state.enabled)
                      OutlinedButton(
                        key: const Key('owner-reply-preferences-disable'),
                        onPressed: canRequest && editing
                            ? () => _submit(_Action.disable, state)
                            : null,
                        child: const Text('关闭自动使用'),
                      )
                    else ...[
                      OutlinedButton(
                        key: const Key('owner-reply-preferences-save'),
                        onPressed:
                            canRequest && editing && _dirty && !_draftEmpty
                            ? () => _submit(_Action.saveOff, state)
                            : null,
                        child: const Text('只保存，不授权'),
                      ),
                      TextButton(
                        key: const Key('owner-reply-preferences-clear'),
                        onPressed:
                            canRequest &&
                                editing &&
                                (state.length != null || state.format != null)
                            ? () {
                                if (_canRequest &&
                                    identical(state, _state) &&
                                    !_busy &&
                                    _review == null) {
                                  setState(() => _clearPending = true);
                                  _showSection();
                                }
                              }
                            : null,
                        child: const Text('清除已保存偏好'),
                      ),
                    ],
                  ],
                ),
              ],
              if (review != null && target != null) ...[
                const Divider(),
                Text(
                  '确认持续自动使用',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Text(
                  '授权后，宿主会在你与此 AI 后续符合条件的本人私聊模型回复中，把下列固定偏好交给这个接收方。可随时关闭；不会开启私聊或放宽原有许可。',
                ),
                const SizedBox(height: 8),
                _TargetDetails(target),
                Text(
                  '长短：${_lengthLabel(review.length)} · 排版：${_formatLabel(review.format)}',
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      key: const Key('owner-reply-preferences-cancel'),
                      onPressed: () => setState(() => _review = null),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      key: const Key('owner-reply-preferences-confirm'),
                      onPressed: canRequest
                          ? () => _submit(
                              _Action.enable,
                              review.state,
                              offer: review,
                            )
                          : null,
                      child: const Text('确认授权'),
                    ),
                  ],
                ),
              ],
              if (_clearPending && state != null) ...[
                const Text('清除已保存的两项偏好？自动使用仍关闭。'),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      key: const Key('owner-reply-preferences-cancel'),
                      onPressed: () => setState(() => _clearPending = false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      key: const Key('owner-reply-preferences-clear-confirm'),
                      onPressed: canRequest
                          ? () => _submit(_Action.clear, state)
                          : null,
                      child: const Text('确认清除'),
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

class _TargetDetails extends StatelessWidget {
  const _TargetDetails(this.target);
  final OwnerReplyTarget target;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('服务提供方：${target.providerId}'),
      Text('接收地址：${target.origin}'),
      Text('模型：${target.model}'),
    ],
  );
}
