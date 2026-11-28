import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../net/owner_rule_greeting_api.dart';
import '../../ui/ui.dart';

/// The account-wide control is available without resolving or selecting an AI.
class OwnerRuleGreetingSettingsPanel extends StatelessWidget {
  const OwnerRuleGreetingSettingsPanel({super.key, required this.onOpen});

  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) => ListTile(
    key: const Key('open-owner-rule-greeting-global'),
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.do_not_disturb_on_outlined),
    title: const Text('本人规则问候 · 账户级停止'),
    subtitle: const Text('停止所有本人规则问候。单个 AI 的授权在 AI 运行配置中管理。'),
    trailing: const Icon(Icons.chevron_right),
    onTap: onOpen,
  );
}

class OwnerRuleGreetingStopScreen extends StatefulWidget {
  const OwnerRuleGreetingStopScreen({
    super.key,
    required this.api,
    required this.session,
    required this.isCurrent,
  });

  final OwnerRuleGreetingApi api;
  final ShellViewModel session;
  final bool Function() isCurrent;

  @override
  State<OwnerRuleGreetingStopScreen> createState() =>
      _OwnerRuleGreetingStopScreenState();
}

class _OwnerRuleGreetingStopScreenState
    extends State<OwnerRuleGreetingStopScreen> {
  GlobalGreetingStop? _state;
  GlobalGreetingStop? _review;
  bool _busy = false;
  bool _retired = false;
  bool _readFailed = false;
  GreetingProblem? _writeProblem;

  bool get _current => mounted && !_retired && widget.isCurrent();
  bool get _canRequest =>
      _current &&
      widget.session.online &&
      ModalRoute.isCurrentOf(context) == true;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_sessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _read();
    });
  }

  @override
  void dispose() {
    widget.session.removeListener(_sessionChanged);
    super.dispose();
  }

  void _sessionChanged() {
    if (!_current && !_retired) {
      setState(() {
        _retired = true;
        _state = null;
        _review = null;
      });
    } else if (!_retired) {
      setState(() {
        if (!widget.session.online) _review = null;
      });
    }
  }

  Future<void> _read() async {
    if (!_canRequest || _busy || _review != null) return;
    setState(() {
      _busy = true;
      _state = null;
      _readFailed = false;
    });
    final result = await widget.api.readGlobalStop();
    if (!_current) return;
    setState(() {
      _busy = false;
      if (!_canRequest || result is! GlobalGreetingStopLoaded) {
        _readFailed = true;
      } else {
        _state = result.state;
        _writeProblem = null;
      }
    });
  }

  Future<void> _save(GlobalGreetingStop expected) async {
    if (!_canRequest ||
        _busy ||
        !identical(_state, expected) ||
        !identical(_review, expected)) {
      return;
    }
    setState(() {
      _busy = true;
      _state = null;
      _review = null;
    });
    final result = await widget.api.writeGlobalStop(
      current: expected,
      blocked: !expected.blocked,
    );
    if (!_current) return;
    setState(() {
      _busy = false;
      if (result is GlobalGreetingStopWritten) {
        _state = result.state;
        _writeProblem = null;
      } else {
        _writeProblem = result is GreetingUnavailable
            ? result.problem
            : GreetingProblem.unknown;
      }
    });
  }

  Widget _note(String text, String key) => Padding(
    padding: const EdgeInsets.symmetric(vertical: JySpace.xs),
    child: JyBanner(
      key: Key('owner-rule-greeting-global-$key'),
      kind: JyBannerKind.error,
      message: text,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final review = _review;
    final canRequest = _canRequest && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('账户级停止')),
      body: !_current
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Text('账户或锁定状态已变化。请返回设置后重新打开。'),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('本人规则问候', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text(
                  '此设置适用于整个账户，不需要先选择或创建 AI。停止会关闭当前所有规则问候授权；解除停止不会恢复任何授权。',
                ),
                const SizedBox(height: 8),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: JySpace.sm),
                    child: JyBusyIndicator(label: '正在读取或提交账户级停止', linear: true),
                  ),
                if (!widget.session.online && !_busy)
                  const Text('请连接宿主后读取或修改。'),
                if (_writeProblem case final problem?)
                  switch (problem) {
                    GreetingProblem.unknown => _note(
                      '提交结果未知，可能已生效。请重新读取；不会自动重试。',
                      'unknown',
                    ),
                    GreetingProblem.conflict => _note(
                      '宿主状态已变化。请重新读取后再确认。',
                      'conflict',
                    ),
                    _ => _note('宿主拒绝更改。请检查权限并重新读取。', 'refused'),
                  },
                if (_readFailed)
                  _note('无法验证账户级停止状态。宿主可能不支持此设置，或当前无法访问。', 'unavailable'),
                if (state != null && review == null)
                  SwitchListTile(
                    key: const Key('owner-rule-greeting-global-stop'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('停止全部本人规则问候'),
                    subtitle: Text(
                      state.blocked
                          ? '已停止；解除后仍须逐个授权。'
                          : '未全局停止；不代表任何 AI 已获得授权。',
                    ),
                    value: state.blocked,
                    onChanged: canRequest
                        ? (_) {
                            if (_canRequest &&
                                !_busy &&
                                _review == null &&
                                identical(_state, state)) {
                              setState(() => _review = state);
                            }
                          }
                        : null,
                  ),
                if (review == null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('owner-rule-greeting-global-read'),
                      onPressed: canRequest ? _read : null,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重新读取状态'),
                    ),
                  ),
                if (review != null) ...[
                  const Divider(),
                  Text(
                    review.blocked ? '解除账户级停止？' : '停止全部本人规则问候？',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    review.blocked
                        ? '只解除账户级阻断，不会开启任何 AI 的问候。'
                        : '撤回所有 AI 当前的规则问候授权，保留时间设置。再次开启须逐个确认。',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TextButton(
                        key: const Key('owner-rule-greeting-global-cancel'),
                        onPressed: () => setState(() => _review = null),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        key: const Key('owner-rule-greeting-global-confirm'),
                        onPressed: canRequest ? () => _save(review) : null,
                        child: Text(review.blocked ? '确认解除' : '确认停止'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}
