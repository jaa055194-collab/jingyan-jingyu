import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';
import '../../net/device_sessions_api.dart';
import '../../ui/ui.dart';

typedef DeviceSessionLister = Future<DeviceSessionsRead> Function();
typedef DeviceRevoker = Future<DeviceRevokeOutcome> Function(String deviceId);

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

  /// Identity and callbacks are pinned to the session that opened this route.
  /// A replacement connection requires opening a new route.
  late final ShellViewModel? _routeSession;
  late final String? _routeAccount;
  late final Object? _routeSessionContext;
  late final DeviceSessionLister? _routeLister;
  late final DeviceRevoker? _routeRevoker;
  bool _routeInvalid = false;
  bool _revoking = false;

  @override
  void initState() {
    super.initState();
    _routeSession = widget.session;
    _routeAccount = _routeSession?.connectedAccountId;
    _routeSessionContext = _routeSession?.ownAiSessionContext;
    _routeLister = widget.listDevices;
    _routeRevoker = widget.revokeDevice;
    _routeSession?.addListener(_onSessionChanged);
    if (_routeLister == null) {
      _phase = _Phase.unbound;
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(DeviceSessionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _invalidateRoute();
    }
  }

  @override
  void dispose() {
    _routeSession?.removeListener(_onSessionChanged);
    super.dispose();
  }

  bool _routeMatchesSession() {
    if (_routeInvalid) return false;
    final session = _routeSession;
    if (session == null) return true;
    final valid =
        _routeAccount != null &&
        session.authenticated &&
        !session.locked &&
        session.connectedAccountId == _routeAccount &&
        session.ownAiSessionContext == _routeSessionContext;
    if (!valid) _invalidateRoute();
    return valid;
  }

  void _invalidateRoute() {
    if (_routeInvalid) return;
    setState(() {
      _routeInvalid = true;
      _devices = const [];
      _notice = null;
      _confirmation = null;
      _loading = false;
      _revoking = false;
      _phase = _Phase.unavailable;
      _discarded = true;
    });
  }

  void _onSessionChanged() {
    if (!mounted || !_routeMatchesSession()) return;
    setState(() {});
  }

  Future<void> _load() async {
    final lister = _routeLister;
    if (lister == null || _routeInvalid || _loading || _revoking) return;
    if (!_routeMatchesSession()) return;
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
    if (!mounted || !_routeMatchesSession()) return;
    setState(() {
      _loading = false;
      _discarded = false;
      _devices = read.status == DeviceSessionsStatus.loaded
          ? read.devices
          : const [];
      _phase = switch (read.status) {
        DeviceSessionsStatus.loaded =>
          _devices.isEmpty ? _Phase.empty : _Phase.ready,
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
    if (_routeInvalid || _loading || _revoking || !_routeMatchesSession()) {
      return;
    }
    setState(() {
      _discarded = false;
      _notice = null;
      _confirmation = _Confirmation(device, strong: _requiresStrong(device));
    });
  }

  Future<void> _submit() async {
    final confirmation = _confirmation;
    final revoke = _routeRevoker;
    if (confirmation == null ||
        revoke == null ||
        _routeInvalid ||
        _loading ||
        _revoking ||
        confirmation.submitting ||
        (confirmation.strong &&
            confirmation.typed.trim() != confirmation.device.deviceName)) {
      return;
    }
    if (!_routeMatchesSession()) return;
    final device = confirmation.device;
    setState(() {
      _revoking = true;
      confirmation.submitting = true;
      confirmation.failure = null;
    });
    DeviceRevokeOutcome outcome;
    try {
      outcome = await revoke(device.id);
    } catch (_) {
      outcome = DeviceRevokeOutcome.unavailable(device.id);
    }
    if (!mounted || !_routeMatchesSession()) return;
    if (!identical(_confirmation, confirmation)) return;
    if (outcome.deviceId != device.id) {
      outcome = DeviceRevokeOutcome.malformed(device.id);
    }
    setState(() {
      _revoking = false;
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
            if (device.current) const Text('这是宿主标记的当前设备：下线后本机需要重新登录。'),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: Key('device-revoke-${device.id}'),
                onPressed:
                    _routeInvalid ||
                        _loading ||
                        _revoking ||
                        _routeRevoker == null
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
        !_routeInvalid &&
        !_revoking &&
        !confirmation.submitting &&
        _routeRevoker != null &&
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
                child: JyBusyIndicator(label: '正在下线', linear: true),
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
    final bound = _routeLister != null;
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
              onPressed: bound && !_routeInvalid && !_loading && !_revoking
                  ? _load
                  : null,
              child: Text(_loading ? '加载中…' : '刷新'),
            ),
          ),
          if (bound) ...[
            if (_discarded)
              Padding(
                key: const Key('device-sessions-discarded'),
                padding: const EdgeInsets.only(top: 4),
                child: const Text(
                  '登录、锁定或账号已变化：此页面已失效，已清除设备信息及待确认操作；请重新打开设备会话。',
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
                child: Center(child: JyBusyIndicator(label: '正在读取设备会话')),
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
              const Text('当前账号没有可显示的设备会话。', key: Key('device-sessions-empty'))
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
              for (final device in _devices)
                _deviceCard(device, text.titleMedium),
            ],
            _confirmationPanel(),
          ],
        ],
      ),
    );
  }
}
