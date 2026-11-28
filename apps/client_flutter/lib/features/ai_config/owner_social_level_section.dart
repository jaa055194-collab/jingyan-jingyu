import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';

import '../../net/owner_social_level_api.dart';
import '../../ui/ui.dart';
import 'ai_config_problem_line.dart';

/// Owner-only Android controls for the pinned AI. No request runs on build.
class OwnerSocialLevelSection extends StatefulWidget {
  const OwnerSocialLevelSection({
    super.key,
    required this.api,
    required this.profileId,
    required this.isCurrent,
    required this.canContactHost,
    required this.onSaved,
  });

  final OwnerSocialLevelApi api;
  final String profileId;
  final bool Function() isCurrent;
  final bool Function() canContactHost;

  /// Invalidate dependent settings after a confirmed or possibly committed PUT.
  final VoidCallback onSaved;

  @override
  State<OwnerSocialLevelSection> createState() =>
      _OwnerSocialLevelSectionState();
}

class _OwnerSocialLevelSectionState extends State<OwnerSocialLevelSection> {
  OwnerSocialLevelSnapshot? _snapshot;
  OwnerSocialLevel? _selected;
  OwnerSocialLevelProblem? _problem;
  int _generation = 0;
  bool _pending = false;
  bool _saving = false;
  bool _saved = false;

  bool get _current =>
      mounted &&
      defaultTargetPlatform == TargetPlatform.android &&
      widget.isCurrent();

  bool get _canContact =>
      _current &&
      ModalRoute.isCurrentOf(context) != false &&
      widget.canContactHost();

  @override
  void didUpdateWidget(covariant OwnerSocialLevelSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.api, widget.api) ||
        oldWidget.profileId != widget.profileId ||
        !_current) {
      _generation++;
      _pending = false;
      _saving = false;
      _saved = false;
      _snapshot = null;
      _selected = null;
      _problem = null;
    }
  }

  Future<void> _submit(
    int generation, {
    OwnerSocialLevelSnapshot? before,
    OwnerSocialLevel? level,
  }) async {
    if (generation != _generation || _pending || !_canContact) return;
    final writing = level != null;
    if (writing &&
        (before == null ||
            !identical(before, _snapshot) ||
            _selected != level ||
            before.level == level)) {
      return;
    }
    final api = widget.api;
    final profileId = widget.profileId;
    // Consume the rendered actions synchronously; a new read may return the
    // very same snapshot (notably the canonical unconfigured value).
    final requestGeneration = ++_generation;
    setState(() {
      _pending = true;
      _saving = writing;
      _saved = false;
      _snapshot = null;
      _selected = null;
      _problem = null;
    });
    final result = level == null
        ? await api.read(profileId)
        : await api.write(profileId, level);
    if (!mounted || requestGeneration != _generation) return;
    final current = _current;
    final accept = writing ? current : _canContact;
    setState(() {
      _pending = false;
      _saving = false;
      if (!accept) {
        _problem = OwnerSocialLevelProblem.unavailable;
      } else if (result case OwnerSocialLevelSnapshot()) {
        _snapshot = result;
        _selected = result.level;
        _saved = writing;
      } else if (result case OwnerSocialLevelFailure(:final problem)) {
        _problem = problem;
      }
    });
    // A lost receipt isn't proof that the old authorization is still valid.
    // Going offline does not make the current owner's cached controls safe.
    if (writing &&
        current &&
        (result is OwnerSocialLevelSnapshot ||
            _problem == OwnerSocialLevelProblem.unknown)) {
      widget.onSaved();
    }
  }

  void _select(
    int generation,
    OwnerSocialLevelSnapshot before,
    OwnerSocialLevel level,
  ) {
    if (generation != _generation ||
        _pending ||
        !_canContact ||
        !identical(before, _snapshot) ||
        _selected == level) {
      return;
    }
    setState(() {
      _selected = level;
      _saved = false;
    });
  }

  static String _label(OwnerSocialLevel level) => switch (level) {
    OwnerSocialLevel.l0 => 'L0 静默',
    OwnerSocialLevel.l1 => 'L1 礼貌',
    OwnerSocialLevel.l2 => 'L2 友好',
    OwnerSocialLevel.l3 => 'L3 主动',
    OwnerSocialLevel.l4 => 'L4 开放',
  };

  static String _problemText(OwnerSocialLevelProblem problem) =>
      switch (problem) {
        OwnerSocialLevelProblem.authenticationRequired =>
          '登录状态已失效。请重新连接宿主，再读取社交等级。',
        OwnerSocialLevelProblem.refused => '宿主不支持此设置，或当前账号无法访问。请检查后重新读取。',
        OwnerSocialLevelProblem.unavailable => '无法确认宿主的社交等级。请手动重新读取。',
        OwnerSocialLevelProblem.unknown => '保存结果未知，可能已保存。请重新读取，不会自动重试。',
      };

  @override
  Widget build(BuildContext context) {
    if (!_current) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final canContact = _canContact;
    final enabled = canContact && !_pending;
    final generation = _generation;
    final snapshot = _snapshot;
    final savedLevel = snapshot?.level;
    final selection = _selected;
    final problem = _problem;
    final status = switch ((savedLevel, snapshot, problem)) {
      (_, _, final OwnerSocialLevelProblem issue) => _problemText(issue),
      (final OwnerSocialLevel level, _, _) =>
        '${_saved ? '已保存' : '宿主已保存'}：${_label(level)}',
      (null, OwnerSocialLevelSnapshot(), _) => '尚未配置社交等级，请选择后保存。',
      _ => '尚未读取社交等级。',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: JySpace.lg),
      child: JySlab(
        key: const Key('owner-social-level'),
        padding: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('AI 社交等级', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('这里只保存等级。L0 为静默，不允许主动联系；此操作不保证取消其他排队任务。'),
              const SizedBox(height: 8),
              const Text(
                '保存低于 L3 的等级会撤销规则问候和模型主动联系授权。L3 或 L4 不会授予或恢复授权，也不会开启 L4 多轮私信。',
              ),
              const SizedBox(height: 8),
              if (_pending)
                JyBusyIndicator(
                  label: _saving ? '正在保存社交等级' : '正在读取社交等级',
                  linear: true,
                )
              else
                AiConfigNoticeLine(
                  status,
                  textKey: const Key('owner-social-level-status'),
                  problem: problem != null,
                ),
              if (!canContact && !_pending) const Text('连接宿主后才能读取或保存。'),
              if (snapshot != null) ...[
                const SizedBox(height: 8),
                Text('选择等级', style: theme.textTheme.labelLarge),
                Wrap(
                  key: const Key('owner-social-level-select'),
                  spacing: 8,
                  children: [
                    for (final level in OwnerSocialLevel.values)
                      ChoiceChip(
                        key: Key('owner-social-level-${level.wire}'),
                        label: Text(_label(level)),
                        selected: selection == level,
                        onSelected: enabled && selection != level
                            ? (_) => _select(generation, snapshot, level)
                            : null,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('owner-social-level-read'),
                    onPressed: enabled ? () => _submit(generation) : null,
                    child: Text(snapshot == null ? '读取社交等级' : '重新读取'),
                  ),
                  if (snapshot != null || _saving)
                    FilledButton(
                      key: const Key('owner-social-level-save'),
                      onPressed:
                          enabled &&
                              selection != null &&
                              selection != savedLevel
                          ? () => _submit(
                              generation,
                              before: snapshot,
                              level: selection,
                            )
                          : null,
                      child: Text(_saving ? '正在保存…' : '保存等级'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
