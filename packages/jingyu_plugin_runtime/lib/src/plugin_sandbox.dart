/// WebView / JS 插件沙箱策略层与 JSON-RPC 能力桥。
///
/// 纯 Dart、无 IO：平台适配器（WebView 通道、宿主能力网关）由调用方注入。
/// 完整规则见 `design/plugin-runtime-contract.md` §6（ticket 内部契约）。
///
/// 安全边界：
/// - 每个插件独立 origin（`jingyu-plugin://<bundleId>/<pluginId>`）与固定 CSP；
/// - `connect-src 'none'` 对 `deny` / `host-gateway` 都生效，插件不能直接联网；
/// - 方法白名单 = 已授予 scope 对应的方法，另做 scope 二次校验；
/// - 消息大小 / JSON 深度 / 限流 / 并发 / 超时均由会话统一约束；
/// - 审计只记录 pluginId / method / at / allowed / errorCode，绝不记录 params。
library;

import 'dart:async';
import 'dart:convert';

import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'plugin_loader.dart';

/// 沙箱固定 CSP：默认全禁，仅允许同源脚本 / 样式 / 图片 / 字体 / 媒体。
///
/// `connect-src 'none'` 对 `deny` 与 `host-gateway` 都成立：插件需要出站时
/// 只能经能力桥调用宿主网关，由宿主执行既有 UrlGuard 等约束。
const String pluginSandboxCsp =
    "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data:; font-src 'self'; media-src 'self'; "
    "connect-src 'none'; object-src 'none'; base-uri 'none'; "
    "form-action 'none'; frame-ancestors 'none'";

/// 沙箱会话限制。
class PluginSandboxLimits {
  const PluginSandboxLimits({
    this.maxMessageBytes = 256 * 1024,
    this.maxJsonDepth = 32,
    this.maxCallsPerMinute = 120,
    this.maxInFlight = 8,
    this.callTimeout = const Duration(seconds: 10),
  }) : assert(maxMessageBytes > 0, 'maxMessageBytes 必须为正数'),
       assert(maxJsonDepth > 0, 'maxJsonDepth 必须为正数'),
       assert(maxCallsPerMinute > 0, 'maxCallsPerMinute 必须为正数'),
       assert(maxInFlight > 0, 'maxInFlight 必须为正数');

  /// 单条入站消息 UTF-8 字节上限。
  final int maxMessageBytes;

  /// 消息 JSON 嵌套深度上限。
  final int maxJsonDepth;

  /// 每会话 60 秒滑动窗口内的最大调用数。
  final int maxCallsPerMinute;

  /// 并发中的网关调用上限。
  final int maxInFlight;

  /// 单次网关调用超时。
  final Duration callTimeout;
}

/// 单个插件的沙箱策略（由运行期描述生成，平台适配器据此加固 WebView）。
class PluginSandboxPolicy {
  const PluginSandboxPolicy({
    required this.pluginId,
    required this.bundleId,
    required this.origin,
    required this.csp,
    required this.permissions,
    required this.allowedMethods,
    this.network = 'deny',
    this.allowNavigation = false,
    this.allowNewWindows = false,
    this.allowDownloads = false,
    this.allowDevTools = false,
    this.allowFileAccess = false,
    this.allowGeolocation = false,
  }) : assert(
         network == 'deny' || network == 'host-gateway',
         'network 只允许 deny / host-gateway',
       );

  /// 插件 id（bundle 内唯一）。
  final String pluginId;

  /// 插件所属 bundle id。
  final String bundleId;

  /// 独立 origin：`jingyu-plugin://<encoded bundleId>/<encoded pluginId>`。
  final String origin;

  /// 固定 CSP。
  final String csp;

  /// 已授予的权限 scope 集合。
  final Set<String> permissions;

  /// 允许调用的能力桥方法名集合。
  final Set<String> allowedMethods;

  /// 网络策略：`deny`（默认）或 `host-gateway`；两者都不允许插件直连外网。
  final String network;

  /// 平台适配器必须禁用的 WebView 能力（默认全部关闭）。
  final bool allowNavigation;
  final bool allowNewWindows;
  final bool allowDownloads;
  final bool allowDevTools;
  final bool allowFileAccess;
  final bool allowGeolocation;

  /// 由 bundle 与运行期插件行生成策略。
  ///
  /// `allowedMethods` 只包含 `permissions` 中 scope 对应的方法；
  /// 未知 network 取值按 `deny` fail-closed 处理。
  static PluginSandboxPolicy forEntry({
    required String bundleId,
    required LoadedPluginEntry entry,
  }) {
    final allowed = <String>{};
    for (final method in PluginBridgeApi.methods) {
      if (entry.permissions.contains(method.scope)) {
        allowed.add(method.name);
      }
    }
    return PluginSandboxPolicy(
      pluginId: entry.id,
      bundleId: bundleId,
      origin: _pluginOrigin(bundleId: bundleId, pluginId: entry.id),
      csp: pluginSandboxCsp,
      permissions: Set<String>.unmodifiable(entry.permissions),
      allowedMethods: Set<String>.unmodifiable(allowed),
      network: entry.network == 'host-gateway' ? 'host-gateway' : 'deny',
    );
  }
}

/// 审计证据回调：每次策略判定后调用，禁止在条目中携带 params。
typedef PluginSandboxEvidence = void Function(PluginSandboxAuditEntry entry);

/// 一条沙箱审计记录。
///
/// 只保存判定所需的元数据；**不保存 params**，避免聊天正文、密钥等
/// 敏感内容经审计日志泄漏。
class PluginSandboxAuditEntry {
  const PluginSandboxAuditEntry({
    required this.pluginId,
    required this.method,
    required this.at,
    required this.allowed,
    this.errorCode,
  });

  /// 插件 id。
  final String pluginId;

  /// 方法名；无法解析出方法时为空串。
  final String method;

  /// 审计时间（由注入时钟产生）。
  final DateTime at;

  /// 是否通过策略白名单 / scope 校验并进入网关。
  final bool allowed;

  /// 失败时的桥错误码。
  final PluginBridgeErrorCode? errorCode;

  @override
  String toString() =>
      'PluginSandboxAuditEntry(pluginId: $pluginId, method: $method, '
      'at: ${at.toIso8601String()}, allowed: $allowed, '
      'errorCode: ${errorCode?.name})';
}

/// 发往插件 WebView 的通道。
abstract class PluginSandboxChannel {
  /// 发送一条 JSON 文本到插件 WebView。
  Future<void> send(String message);

  /// 关闭通道。
  Future<void> close();
}

/// 宿主能力网关请求。
class PluginGatewayRequest {
  const PluginGatewayRequest({
    required this.pluginId,
    required this.bundleId,
    required this.method,
    required this.scope,
    required this.params,
  });

  final String pluginId;
  final String bundleId;
  final String method;
  final String scope;
  final Map<String, Object?> params;
}

/// 宿主能力网关：由平台适配器把允许的桥方法落到真实宿主能力上。
abstract class PluginSandboxGateway {
  /// 执行一次能力调用；异常由会话统一转成 internalError。
  Future<Object?> invoke(PluginGatewayRequest request);
}

/// 沙箱会话状态。
enum PluginSandboxState { created, running, stopped }

/// 单个插件的沙箱会话：JSON-RPC 2.0 能力桥 + 策略校验 + 限流 + 审计。
class PluginSandboxSession {
  PluginSandboxSession({
    required this.policy,
    required this.channel,
    required this.gateway,
    this.limits = const PluginSandboxLimits(),
    DateTime Function()? clock,
    PluginSandboxEvidence? onAudit,
  }) : _clock = clock ?? DateTime.now,
       _onAudit = onAudit;

  /// 会话策略。
  final PluginSandboxPolicy policy;

  /// 插件 WebView 通道。
  final PluginSandboxChannel channel;

  /// 宿主能力网关。
  final PluginSandboxGateway gateway;

  /// 会话限制。
  final PluginSandboxLimits limits;

  final DateTime Function() _clock;
  final PluginSandboxEvidence? _onAudit;

  final List<PluginSandboxAuditEntry> _auditLog = <PluginSandboxAuditEntry>[];
  final List<DateTime> _callTimes = <DateTime>[];

  PluginSandboxState _state = PluginSandboxState.created;
  int _inFlight = 0;

  /// 当前状态。
  PluginSandboxState get state => _state;

  /// 审计日志（不可修改快照）。
  List<PluginSandboxAuditEntry> get auditLog =>
      List<PluginSandboxAuditEntry>.unmodifiable(_auditLog);

  /// created -> running，并向插件发送 `host.ready` 通知。
  Future<void> start() async {
    if (_state == PluginSandboxState.running) {
      throw StateError('沙箱会话已启动');
    }
    if (_state == PluginSandboxState.stopped) {
      throw StateError('沙箱会话已停止');
    }
    _state = PluginSandboxState.running;
    try {
      await channel.send(
        encodePluginBridgeMessage(
          PluginBridgeNotification(
            method: 'host.ready',
            params: <String, Object?>{
              'pluginId': policy.pluginId,
              'bundleId': policy.bundleId,
              'apiVersion': pluginBridgeProtocolVersion,
            },
          ),
        ),
      );
    } on Object {
      // 通道不可用时 fail-closed：会话不再接受消息。
      _state = PluginSandboxState.stopped;
      rethrow;
    }
  }

  /// 处理一条来自插件的原始 JSON 文本。
  Future<void> handleRaw(String raw) async {
    _ensureRunning();

    final int byteLength;
    try {
      byteLength = utf8.encode(raw).length;
    } on Object {
      // 含未配对代理项等无法编码为 UTF-8 的字符串按 parse error 处理。
      _audit('', allowed: false, errorCode: PluginBridgeErrorCode.parseError);
      await _sendFailure(null, PluginBridgeErrorCode.parseError, 'JSON 解析失败');
      return;
    }
    if (byteLength > limits.maxMessageBytes) {
      _audit(
        '',
        allowed: false,
        errorCode: PluginBridgeErrorCode.messageTooLarge,
      );
      await _sendFailure(
        null,
        PluginBridgeErrorCode.messageTooLarge,
        '插件桥消息超过大小上限：$byteLength > ${limits.maxMessageBytes}',
      );
      return;
    }

    final bridgeLimits = PluginBridgeLimits(
      maxBytes: limits.maxMessageBytes,
      maxDepth: limits.maxJsonDepth,
    );
    final decoded = decodePluginBridgeJson(raw, limits: bridgeLimits);
    final message = decoded.valueOrNull;
    if (message == null) {
      // 区分 JSON-RPC 的 parse error（文本不是合法 JSON）与
      // invalid request（JSON 合法但消息结构不合法）。
      final validJson = _isValidJson(raw);
      final code = validJson
          ? PluginBridgeErrorCode.invalidRequest
          : PluginBridgeErrorCode.parseError;
      _audit('', allowed: false, errorCode: code);
      await _sendFailure(
        validJson ? _extractId(raw) : null,
        code,
        validJson ? '请求不是合法的 JSON-RPC 2.0 消息' : 'JSON 解析失败',
      );
      return;
    }

    switch (message) {
      case PluginBridgeRequest():
        await _handleRequest(message);
      case PluginBridgeNotification():
        await _handleNotification(message);
      case PluginBridgeSuccess():
      case PluginBridgeFailure():
        // 宿主当前只向插件发通知、不发请求，插件不应主动回传响应。
        _audit(
          '',
          allowed: false,
          errorCode: PluginBridgeErrorCode.invalidRequest,
        );
    }
  }

  /// 宿主向插件推送一条通知（如 `message.onMessage`）。
  Future<void> sendEvent(String method, Map<String, Object?> params) async {
    _ensureRunning();
    await channel.send(
      encodePluginBridgeMessage(
        PluginBridgeNotification(method: method, params: params),
      ),
    );
  }

  /// 使会话失效并关闭通道；重复调用幂等。
  Future<void> stop() async {
    if (_state == PluginSandboxState.stopped) return;
    _state = PluginSandboxState.stopped;
    _callTimes.clear();
    await channel.close();
  }

  Future<void> _handleRequest(PluginBridgeRequest request) async {
    final methodInfo = PluginBridgeApi.method(request.method);
    if (methodInfo == null) {
      _audit(
        request.method,
        allowed: false,
        errorCode: PluginBridgeErrorCode.methodNotFound,
      );
      await _sendFailure(
        request.id,
        PluginBridgeErrorCode.methodNotFound,
        '未知方法：${request.method}',
      );
      return;
    }

    if (!policy.allowedMethods.contains(request.method) ||
        !policy.permissions.contains(methodInfo.scope)) {
      _audit(
        request.method,
        allowed: false,
        errorCode: PluginBridgeErrorCode.permissionDenied,
      );
      await _sendFailure(
        request.id,
        PluginBridgeErrorCode.permissionDenied,
        '权限不足：${request.method}',
      );
      return;
    }

    if (request.method == 'ui.registerSlot') {
      final slot = request.params['slot'];
      if (slot is! String || !PluginBridgeApi.isKnownSlot(slot)) {
        _audit(
          request.method,
          allowed: false,
          errorCode: PluginBridgeErrorCode.invalidParams,
        );
        await _sendFailure(
          request.id,
          PluginBridgeErrorCode.invalidParams,
          '参数不合法：slot 未知',
        );
        return;
      }
    }

    if (!_consumeRateLimit()) {
      _audit(
        request.method,
        allowed: false,
        errorCode: PluginBridgeErrorCode.rateLimited,
      );
      await _sendFailure(
        request.id,
        PluginBridgeErrorCode.rateLimited,
        '调用过于频繁',
      );
      return;
    }
    if (_inFlight >= limits.maxInFlight) {
      _audit(
        request.method,
        allowed: false,
        errorCode: PluginBridgeErrorCode.rateLimited,
      );
      await _sendFailure(
        request.id,
        PluginBridgeErrorCode.rateLimited,
        '并发调用超限',
      );
      return;
    }

    _inFlight++;
    try {
      final result = await gateway
          .invoke(
            PluginGatewayRequest(
              pluginId: policy.pluginId,
              bundleId: policy.bundleId,
              method: request.method,
              scope: methodInfo.scope,
              params: request.params,
            ),
          )
          .timeout(limits.callTimeout);
      if (_state != PluginSandboxState.running) return;
      _audit(request.method, allowed: true);
      await _send(PluginBridgeSuccess(id: request.id, result: result));
    } on TimeoutException {
      if (_state != PluginSandboxState.running) return;
      _audit(
        request.method,
        allowed: true,
        errorCode: PluginBridgeErrorCode.timeout,
      );
      await _sendFailure(request.id, PluginBridgeErrorCode.timeout, '宿主能力调用超时');
    } on Object {
      if (_state != PluginSandboxState.running) return;
      _audit(
        request.method,
        allowed: true,
        errorCode: PluginBridgeErrorCode.internalError,
      );
      await _sendFailure(
        request.id,
        PluginBridgeErrorCode.internalError,
        '宿主能力调用失败',
      );
    } finally {
      _inFlight--;
    }
  }

  Future<void> _handleNotification(
    PluginBridgeNotification notification,
  ) async {
    final methodInfo = PluginBridgeApi.method(notification.method);
    if (methodInfo == null) {
      _audit(
        notification.method,
        allowed: false,
        errorCode: PluginBridgeErrorCode.methodNotFound,
      );
      return;
    }
    if (!policy.allowedMethods.contains(notification.method) ||
        !policy.permissions.contains(methodInfo.scope)) {
      _audit(
        notification.method,
        allowed: false,
        errorCode: PluginBridgeErrorCode.permissionDenied,
      );
      return;
    }
    // 插件 -> 宿主方向当前只接受 host.log 这类无响应通知。
    if (notification.method != 'host.log') {
      _audit(
        notification.method,
        allowed: false,
        errorCode: PluginBridgeErrorCode.methodNotFound,
      );
      return;
    }

    if (!_consumeRateLimit()) {
      _audit(
        notification.method,
        allowed: false,
        errorCode: PluginBridgeErrorCode.rateLimited,
      );
      return;
    }
    if (_inFlight >= limits.maxInFlight) {
      _audit(
        notification.method,
        allowed: false,
        errorCode: PluginBridgeErrorCode.rateLimited,
      );
      return;
    }

    _inFlight++;
    try {
      await gateway
          .invoke(
            PluginGatewayRequest(
              pluginId: policy.pluginId,
              bundleId: policy.bundleId,
              method: notification.method,
              scope: methodInfo.scope,
              params: notification.params,
            ),
          )
          .timeout(limits.callTimeout);
      if (_state != PluginSandboxState.running) return;
      _audit(notification.method, allowed: true);
    } on TimeoutException {
      if (_state != PluginSandboxState.running) return;
      _audit(
        notification.method,
        allowed: true,
        errorCode: PluginBridgeErrorCode.timeout,
      );
    } on Object {
      if (_state != PluginSandboxState.running) return;
      _audit(
        notification.method,
        allowed: true,
        errorCode: PluginBridgeErrorCode.internalError,
      );
    } finally {
      _inFlight--;
    }
  }

  /// 60 秒滑动窗口限流；通过时登记本次调用。
  bool _consumeRateLimit() {
    final now = _clock();
    const window = Duration(minutes: 1);
    _callTimes.removeWhere((at) => now.difference(at) >= window);
    if (_callTimes.length >= limits.maxCallsPerMinute) return false;
    _callTimes.add(now);
    return true;
  }

  Future<void> _sendFailure(
    Object? id,
    PluginBridgeErrorCode code,
    String message,
  ) => _send(PluginBridgeFailure(id: id, code: code, message: message));

  Future<void> _send(PluginBridgeMessage message) async {
    if (_state != PluginSandboxState.running) return;
    try {
      await channel.send(encodePluginBridgeMessage(message));
    } on Object {
      // 通道已不可用：fail-closed，后续消息一律拒绝。
      _state = PluginSandboxState.stopped;
    }
  }

  void _audit(
    String method, {
    required bool allowed,
    PluginBridgeErrorCode? errorCode,
  }) {
    final entry = PluginSandboxAuditEntry(
      pluginId: policy.pluginId,
      method: method,
      at: _clock(),
      allowed: allowed,
      errorCode: errorCode,
    );
    _auditLog.add(entry);
    final callback = _onAudit;
    if (callback == null) return;
    try {
      callback(entry);
    } on Object {
      // 证据上报失败不得影响沙箱主流程。
    }
  }

  void _ensureRunning() {
    if (_state == PluginSandboxState.stopped) {
      throw StateError('沙箱会话已停止');
    }
    if (_state == PluginSandboxState.created) {
      throw StateError('沙箱会话尚未启动');
    }
  }
}

/// 插件沙箱管理器：按 pluginId 维护活动会话。
class PluginSandbox {
  PluginSandbox({
    PluginSandboxLimits limits = const PluginSandboxLimits(),
    DateTime Function()? clock,
  }) : _limits = limits,
       _clock = clock ?? DateTime.now;

  final PluginSandboxLimits _limits;
  final DateTime Function() _clock;
  final Map<String, PluginSandboxSession> _sessions =
      <String, PluginSandboxSession>{};

  /// 当前活动会话（已停止的不包含）。
  List<PluginSandboxSession> get sessions =>
      List<PluginSandboxSession>.unmodifiable(
        _sessions.values.where(
          (session) => session.state != PluginSandboxState.stopped,
        ),
      );

  /// 创建并启动一个会话。
  Future<PluginSandboxSession> open({
    required PluginSandboxPolicy policy,
    required PluginSandboxChannel channel,
    required PluginSandboxGateway gateway,
    PluginSandboxEvidence? onAudit,
  }) async {
    final existing = _sessions[policy.pluginId];
    if (existing != null && existing.state != PluginSandboxState.stopped) {
      throw StateError('插件 ${policy.pluginId} 已有活动沙箱会话');
    }
    _sessions.remove(policy.pluginId);
    final session = PluginSandboxSession(
      policy: policy,
      channel: channel,
      gateway: gateway,
      limits: _limits,
      clock: _clock,
      onAudit: onAudit,
    );
    await session.start();
    _sessions[policy.pluginId] = session;
    return session;
  }

  /// 关闭指定插件的会话；不存在时为空操作。
  Future<void> close(String pluginId) async {
    final session = _sessions.remove(pluginId);
    if (session != null) {
      await session.stop();
    }
  }

  /// 关闭全部会话。
  Future<void> closeAll() async {
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    for (final session in sessions) {
      await session.stop();
    }
  }
}

/// 生成插件独立 origin：host（bundleId）小写，两段均做组件编码。
String _pluginOrigin({required String bundleId, required String pluginId}) {
  final encodedBundle = _encodeOriginPart(bundleId.toLowerCase(), 'bundleId');
  final encodedPlugin = _encodeOriginPart(pluginId, 'pluginId');
  return 'jingyu-plugin://$encodedBundle/$encodedPlugin';
}

String _encodeOriginPart(String value, String label) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, label, '不能为空');
  }
  if (value.contains('..')) {
    throw ArgumentError.value(value, label, '不能包含 ".."');
  }
  return Uri.encodeComponent(value);
}

/// 文本是否为合法 JSON（用于区分 parse error 与 invalid request）。
bool _isValidJson(String raw) {
  try {
    jsonDecode(raw);
    return true;
  } on Object {
    return false;
  }
}

/// 从合法 JSON 中尽力提取请求 id；仅用于 invalid request 的错误响应。
Object? _extractId(String raw) {
  try {
    final value = jsonDecode(raw);
    if (value is! Map<String, Object?>) return null;
    final id = value['id'];
    if (id is int) return id;
    if (id is String && id.isNotEmpty && id.length <= 128) return id;
    return null;
  } on Object {
    return null;
  }
}
