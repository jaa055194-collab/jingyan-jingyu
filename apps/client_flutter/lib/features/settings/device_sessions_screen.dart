import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../net/device_sessions_api.dart';

typedef DeviceSessionLister = Future<DeviceSessionsRead> Function();
typedef DeviceRevoker =
    Future<DeviceRevokeOutcome> Function(String deviceId);

/// Remote device-session list with an explicit, confirmed remote sign-off.
///
/// Read states are honest and mutually exclusive: unbound (no host connection
/// injected), loading, denied, unavailable, malformed, empty or a loaded list.
/// A revoke is only shown as done when the host confirms it; a failure is a
/// per-device honest state with no automatic retry. The device the host reports
/// as current — or every device when the host reports none — requires a
/// distinctly stronger confirmation, and nothing is ever revoked silently.
class DeviceSessionsScreen extends StatefulWidget {
  const DeviceSessionsScreen({
    super.key,
    this.listDevices,
    this.revokeDevice,
    this.session,
    this.title = '设备会话',
  });

  /// Host-backed lister ([DeviceSessionsApi.listDevices] in production).
  final DeviceSessionLister? listDevices;

  /// Host-backed revoke ([DeviceSessionsApi.revokeDevice] in production).
  final DeviceRevoker? revokeDevice;

  /// Session used to discard a result when the account, lock or auth changes.
  final ShellViewModel? session;

  final String title;

  @override
  State<DeviceSessionsScreen> createState() => _DeviceSessionsScreenState();
}

enum _Phase { unbound, loading, denied, unavailable, malformed, empty, ready }

/// One in-flight or completed explicit confirmation for one device id.
class _Confirmation {
  _Confirmation(this.device, {required this.strong});
  final DeviceSummary device;

  /// The stronger gate: requires typing the device name to confirm.
  final bool strong;
  String typed = '';
  bool submitting = false;
  DeviceRevokeOutcome? failure;
}

class _DeviceSessionsScreenState extends State<DeviceSessionsScreen> {
  _Phase _phase = _Phase.loading;
  List<DeviceSummary> _devices = const [];
  String? _notice;
  bool _discarded = false;
  bool _loading = false;
  _Confirmation? _confirmation;

  /// Identity captured when the read/revoke started. A mismatch afterwards
  /// means the result belongs to a session that no longer exists.
  String? _account;

  @override
  void initState() {
    super.initState();
    _capture();
    widget.session?.addListener(_onSessionChanged);
    if (widget.listDevices == null) {
      _phase = _Phase.unbound;
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(DeviceSessionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session?.removeListener(_onSessionChanged);
      widget.session?.addListener(_onSessionChanged);
      _capture();
    }
  }

  @override
  void dispose() {
    widget.session?.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _capture() => _account = widget.session?.connectedAccountId;

  /// True while the captured identity still matches the live session.
  bool _identityValid() {
    final session = widget.session;
    if (session == null) return true;
    if (_account == null) return false;
    return session.authenticated &&
        !session.locked &&
        session.connectedAccountId == _account;
  }

  void _onSessionChanged() {
    if (!mounted) return;
    if (_identityValid()) {
      setState(() {});
      return;
    }
    // Lock, logout or an authenticated-account change: drop the pending
    // confirmation and any in-flight result instead of applying it.
    final hadWork = _confirmation != null || _loading;
    setState(() {
      _confirmation = null;
      _loading = false;
      _devices = const [];
      _phase = _Phase.unavailable;
      if (hadWork) _discarded = true;
    });
    _capture();
  }

  Future<void> _load() async {
    final lister = widget.listDevices;
    if (lister == null || _loading) return;
    final account = _account;
    final session = widget.session;
    if (session != null && !_identityValid()) {
      setState(() {
        _phase = _Phase.denied;
        _notice = '登录状态已变化，请重新打开设备会话；不会自动重试。';
      });
      return;
    }
    setState(() {
      _loading = true;
      _discarded = false;
      _notice = null;
      _confirmation = null;
      _phase = _Phase.loading;
      _devices = const [];
    });
    DeviceSessionsRead read;
    try {
      read = await lister();
    } catch (_) {
      // Never surface raw transport text; unknown is not success.
      read = const DeviceSessionsRead(DeviceSessionsStatus.unavailable);
    }
    if (!mounted) return;
    if (session != null &&
        (!_identityValid() || session.connectedAccountId != account)) {
      setState(() {
        _loading = false;
        _devices = const [];
        _phase = _Phase.unavailable;
        _discarded = true;
      });
      _capture();
      return;
    }
    setState(() {
      _loading = false;
      _discarded = false;
      _devices = read.status == DeviceSessionsStatus.loaded
          ? read.devices
          : const [];
      _phase = switch (read.status) {
        DeviceSessionsStatus.loaded => _devices.isEmpty
            ? _Phase.empty
            : _Phase.ready,
        DeviceSessionsStatus.unauthenticated => _Phase.denied,
        DeviceSessionsStatus.unavailable => _Phase.unavailable,
        DeviceSessionsStatus.malformed => _Phase.malformed,
      };
      _notice = null;
    });
  }

  /// The current device must not be silently revocable. When the host does not
  /// report one, we cannot tell which row it is, so every row takes the
  /// stronger gate rather than assuming.
  bool _requiresStrong(DeviceSummary device) =>
      device.current || !_devices.any((row) => row.current);

  void _askRevoke(DeviceSummary device) {
    if (_loading) return;
    setState(() {
      _discarded = false;
      _notice = null;
      _confirmation = _Confirmation(device, strong: _requiresStrong(device));
    });
  }

  Future<void> _submit() async {
    final confirmation = _confirmation;
    final revoke = widget.revokeDevice;
    if (confirmation == null ||
        revoke == null ||
        confirmation.submitting ||
        (confirmation.strong && confirmation.typed.trim() != confirmation.device.deviceName)) {
      return;
    }
    final session = widget.session;
    if (session != null && !_identityValid()) {
      setState(() {
        _confirmation = null;
        _discarded = true;
      });
      return;
    }
    final device = confirmation.device;
    final account = _account;
    setState(() {
      confirmation.submitting = true;
      confirmation.failure = null;
    });
    DeviceRevokeOutcome outcome;
    try {
      outcome = await revoke(device.id);
    } catch (_) {
      outcome = DeviceRevokeOutcome.unavailable(device.id);
    }
    if (!mounted) return;
    // A lock, logout or account change while the request was in flight means
    // the answer cannot be attributed to the current session: discard it and
    // clear any pending confirmation without claiming a revoke.
    if (session != null &&
        (!_identityValid() || session.connectedAccountId != account)) {
      setState(() {
        _confirmation = null;
        _discarded = true;
        _devices = const [];
        _phase = _Phase.unavailable;
      });
      _capture();
      return;
    }
    if (!identical(_confirmation, confirmation) || outcome.deviceId != device.id) {
      return;
    }
    setState(() {
      confirmation.submitting = false;
      if (outcome.confirmed) {
        _devices = List<DeviceSummary>.unmodifiable(
          _devices.where((row) => row.id != device.id),
        );
        _phase = _devices.isEmpty ? _Phase.empty : _Phase.ready;
        _confirmation = null;
        _notice = '已远程下线：${device.deviceName}（宿主已确认）';
      } else {
        confirmation.failure = outcome;
      }
    });
  }

  static String _statusLabel(DeviceRevokeStatus status) => switch (status) {
    DeviceRevokeStatus.revoked => '宿主已确认下线',
    DeviceRevokeStatus.unauthenticated => '未确认下线：登录状态已失效，请重新打开本页。',
    DeviceRevokeStatus.notFound => '未确认下线：宿主未找到该设备（可能已被移除）。',
    DeviceRevokeStatus.unavailable => '未确认下线：宿主暂不可用或结果未知。',
    DeviceRevokeStatus.malformed => '未确认下线：宿主响应无效。',
  };

  Widget _deviceCard(DeviceSummary device, TextStyle? title) {
    final failure = _confirmation?.device.id == device.id
        ? _confirmation?.failure
        : null;
    return Card(
      key: Key('device-row-${device.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(device.deviceName, style: title)),
                if (device.current)
                  Padding(
                    key: Key('device-current-${device.id}'),
                    padding: const EdgeInsets.only(left: 8),
                    child: const Text('本机'),
                  ),
              ],
            ),
            Text('设备标识：${device.id}'),
            Text('最近使用：${device.lastUsedAt.toIso8601String()}'),
            if (device.current)
              const Text('这是宿主标记的当前设备：下线后本机需要重新登录。'),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: Key('device-revoke-${device.id}'),
                onPressed: _loading || widget.revokeDevice == null
                    ? null
                    : () => _askRevoke(device),
                child: const Text('远程下线'),
              ),
            ),
            if (failure != null)
              Padding(
                key: Key('device-failure-${device.id}'),
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${_statusLabel(failure.status)} 不会自动重试；如需再次尝试，请重新确认。',
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _confirmationPanel() {
    final confirmation = _confirmation;
    if (confirmation == null) return const SizedBox.shrink();
    final device = confirmation.device;
    final canSubmit =
        !confirmation.submitting &&
        widget.revokeDevice != null &&
        (!confirmation.strong ||
            confirmation.typed.trim() == device.deviceName);
    return Card(
      key: const Key('device-confirm-panel'),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              confirmation.strong ? '确认下线当前设备？' : '确认远程下线？',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text('设备：${device.deviceName}（${device.id}）'),
            const SizedBox(height: 4),
            Text(
              confirmation.strong
                  ? '宿主未明确标记本机，或这台就是本机。下线后该设备会立即失去登录，'
                        '需要重新登录；为免误操作，请输入设备名以确认。'
                  : '该设备会立即失去登录，需要重新登录。此操作不可撤销。',
            ),
            if (confirmation.strong)
              TextField(
                key: const Key('device-confirm-name'),
                enabled: !confirmation.submitting,
                decoration: const InputDecoration(
                  labelText: '输入设备名以确认',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) =>
                    setState(() => confirmation.typed = value),
                onSubmitted: (_) => _submit(),
              ),
            if (confirmation.submitting)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
            Row(
              children: [
                TextButton(
                  key: const Key('device-confirm-cancel'),
                  onPressed: confirmation.submitting
                      ? null
                      : () => setState(() => _confirmation = null),
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const Key('device-confirm-submit'),
                  onPressed: canSubmit ? _submit : null,
                  child: Text(confirmation.submitting ? '正在下线…' : '确认下线'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final bound = widget.listDevices != null;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '列出当前账号已登录的设备（名称与最近使用时间，均为宿主返回的元数据）。'
            '远程下线会立即使该设备失去登录，需要在该设备重新登录；'
            '本机或无法确定本机时需输入设备名确认。不显示、不保存任何令牌。',
            key: Key('device-sessions-help'),
          ),
          const SizedBox(height: 8),
          if (!bound)
            const Text(
              '当前入口未接线宿主连接：设备会话不可用（需装配 DeviceSessionsApi）。',
              key: Key('device-sessions-unbound'),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('device-sessions-refresh'),
              onPressed: bound && !_loading ? _load : null,
              child: Text(_loading ? '加载中…' : '刷新'),
            ),
          ),
          if (bound) ...[
            if (_discarded)
              Padding(
                key: const Key('device-sessions-discarded'),
                padding: const EdgeInsets.only(top: 4),
                child: const Text(
                  '登录、锁定或账号已变化：已丢弃进行中的结果并清除待确认操作；不会自动重试。',
                ),
              ),
            if (_notice != null)
              Padding(
                key: const Key('device-sessions-notice'),
                padding: const EdgeInsets.only(top: 4),
                child: Text(_notice!),
              ),
            if (_phase == _Phase.loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_phase == _Phase.denied)
              const Text(
                '无权限读取设备会话（未认证或已失效）；不会自动重试。',
                key: Key('device-sessions-denied'),
              )
            else if (_phase == _Phase.unavailable)
              const Text(
                '读取失败或结果未确认；不会自动重试。',
                key: Key('device-sessions-unavailable'),
              )
            else if (_phase == _Phase.malformed)
              const Text(
                '宿主响应无效（字段、标识或时间戳不合规）；不展示部分结果，不会自动重试。',
                key: Key('device-sessions-malformed'),
              )
            else if (_phase == _Phase.empty)
              const Text(
                '当前账号没有可显示的设备会话。',
                key: Key('device-sessions-empty'),
              )
            else ...[
              if (!_devices.any((row) => row.current))
                const Padding(
                  key: Key('device-current-unknown'),
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    '宿主未标记本机：无法确定哪台是当前设备，因此每台都需输入设备名确认，'
                    '不会默认任何一台可安全下线。',
                  ),
                ),
              for (final device in _devices) _deviceCard(device, text.titleMedium),
            ],
            _confirmationPanel(),
          ],
        ],
      ),
    );
  }
}
