import 'dart:async';
import 'dart:convert';

import 'package:jingyu_client_kit/jingyu_client_kit.dart' show PluginRuntime;
import 'package:jingyu_plugin_runtime/jingyu_plugin_runtime.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// 测试替身
// ---------------------------------------------------------------------------

/// 记录发往插件 WebView 的原始 JSON 文本。
class _FakeChannel implements PluginSandboxChannel {
  final List<String> sent = <String>[];
  bool closed = false;

  @override
  Future<void> send(String message) async {
    sent.add(message);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// 记录网关请求并允许注入返回值 / 异常 / 未完成 Future。
class _FakeGateway implements PluginSandboxGateway {
  final List<PluginGatewayRequest> requests = <PluginGatewayRequest>[];
  Future<Object?> Function(PluginGatewayRequest request)? onInvoke;

  @override
  Future<Object?> invoke(PluginGatewayRequest request) {
    requests.add(request);
    final handler = onInvoke;
    if (handler == null) {
      return Future<Object?>.value(const <String, Object?>{'ok': true});
    }
    return handler(request);
  }
}

/// 可手动推进的时钟，用于限流窗口测试。
class _FakeClock {
  _FakeClock() : now = DateTime.utc(2026, 1, 1, 12);

  DateTime now;

  DateTime call() => now;

  void advance(Duration duration) {
    now = now.add(duration);
  }
}

/// 一个已组装好的会话测试环境。
class _Harness {
  _Harness._(this.channel, this.gateway, this.session);

  factory _Harness({
    PluginSandboxPolicy? policy,
    PluginSandboxLimits limits = const PluginSandboxLimits(),
    DateTime Function()? clock,
    PluginSandboxEvidence? onAudit,
  }) {
    final channel = _FakeChannel();
    final gateway = _FakeGateway();
    final session = PluginSandboxSession(
      policy: policy ?? _policyFor(const <String>{'host'}),
      channel: channel,
      gateway: gateway,
      limits: limits,
      clock: clock,
      onAudit: onAudit,
    );
    return _Harness._(channel, gateway, session);
  }

  final _FakeChannel channel;
  final _FakeGateway gateway;
  final PluginSandboxSession session;
}

Future<_Harness> _startHarness({
  PluginSandboxPolicy? policy,
  PluginSandboxLimits limits = const PluginSandboxLimits(),
  DateTime Function()? clock,
  PluginSandboxEvidence? onAudit,
}) async {
  final harness = _Harness(
    policy: policy,
    limits: limits,
    clock: clock,
    onAudit: onAudit,
  );
  await harness.session.start();
  return harness;
}

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

PluginSandboxPolicy _policyFor(
  Set<String> permissions, {
  String bundleId = 'bundle.one',
  String pluginId = 'plugin.one',
  String network = 'deny',
}) {
  return PluginSandboxPolicy.forEntry(
    bundleId: bundleId,
    entry: LoadedPluginEntry(
      id: pluginId,
      runtime: PluginRuntime.webview,
      entry: 'index.html',
      permissions: permissions,
      network: network,
    ),
  );
}

String _requestJson({
  Object id = 1,
  required String method,
  Map<String, Object?> params = const <String, Object?>{},
}) => encodePluginBridgeMessage(
  PluginBridgeRequest(id: id, method: method, params: params),
);

String _notificationJson(
  String method, [
  Map<String, Object?> params = const {},
]) => encodePluginBridgeMessage(
  PluginBridgeNotification(method: method, params: params),
);

Map<String, Object?> _jsonOf(String raw) =>
    jsonDecode(raw) as Map<String, Object?>;

PluginBridgeMessage _decode(String raw) {
  final result = decodePluginBridgeJson(raw);
  expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
  return result.value;
}

int _errorCodeOf(String raw) {
  final error = _jsonOf(raw)['error'] as Map<String, Object?>;
  return error['code'] as int;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

void main() {
  group('PluginSandboxLimits', () {
    test('默认值与契约一致', () {
      const limits = PluginSandboxLimits();
      expect(limits.maxMessageBytes, 256 * 1024);
      expect(limits.maxJsonDepth, 32);
      expect(limits.maxCallsPerMinute, 120);
      expect(limits.maxInFlight, 8);
      expect(limits.callTimeout, const Duration(seconds: 10));
    });
  });

  group('PluginSandboxPolicy.forEntry', () {
    test('生成独立 origin：host 小写、两段均做组件编码', () {
      final policy = PluginSandboxPolicy.forEntry(
        bundleId: 'My/Bundle',
        entry: LoadedPluginEntry(
          id: '插件一',
          runtime: PluginRuntime.webview,
          entry: 'index.html',
          permissions: const <String>{'host'},
        ),
      );
      expect(
        policy.origin,
        'jingyu-plugin://${Uri.encodeComponent('my/bundle')}/${Uri.encodeComponent('插件一')}',
      );
      expect(policy.origin, startsWith('jingyu-plugin://'));
      expect(policy.pluginId, '插件一');
      expect(policy.bundleId, 'My/Bundle');
    });

    test('拒绝空 id 与包含 .. 的 id', () {
      LoadedPluginEntry entry(String id) => LoadedPluginEntry(
        id: id,
        runtime: PluginRuntime.webview,
        entry: 'index.html',
      );
      expect(
        () => PluginSandboxPolicy.forEntry(
          bundleId: '',
          entry: entry('plugin.one'),
        ),
        throwsArgumentError,
      );
      expect(
        () => PluginSandboxPolicy.forEntry(
          bundleId: '..',
          entry: entry('plugin.one'),
        ),
        throwsArgumentError,
      );
      expect(
        () => PluginSandboxPolicy.forEntry(
          bundleId: 'bundle.one',
          entry: entry('..'),
        ),
        throwsArgumentError,
      );
      expect(
        () => PluginSandboxPolicy.forEntry(
          bundleId: 'bundle.one',
          entry: entry('   '),
        ),
        throwsArgumentError,
      );
    });

    test('CSP 为固定值且 connect-src 永远 none', () {
      final policy = _policyFor(const <String>{'host'});
      expect(policy.csp, pluginSandboxCsp);
      expect(
        policy.csp,
        "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
        "img-src 'self' data:; font-src 'self'; media-src 'self'; "
        "connect-src 'none'; object-src 'none'; base-uri 'none'; "
        "form-action 'none'; frame-ancestors 'none'",
      );
      expect(policy.csp, contains("connect-src 'none'"));
    });

    test('allowedMethods 只包含已授予 scope 对应的方法', () {
      final policy = _policyFor(const <String>{'host', 'chat.send', 'storage'});
      expect(policy.allowedMethods, const <String>{
        'host.getInfo',
        'host.log',
        'host.openExternal',
        'chat.sendText',
        'chat.sendCard',
        'storage.get',
        'storage.set',
        'storage.remove',
        'storage.keys',
      });
      expect(policy.allowedMethods.contains('chat.listConversations'), isFalse);
      expect(policy.allowedMethods.contains('model.invoke'), isFalse);
      expect(policy.allowedMethods.contains('ui.registerSlot'), isFalse);
    });

    test('network 保留 host-gateway，平台约束默认全部关闭', () {
      final policy = _policyFor(const <String>{
        'host',
      }, network: 'host-gateway');
      expect(policy.network, 'host-gateway');
      expect(policy.allowNavigation, isFalse);
      expect(policy.allowNewWindows, isFalse);
      expect(policy.allowDownloads, isFalse);
      expect(policy.allowDevTools, isFalse);
      expect(policy.allowFileAccess, isFalse);
      expect(policy.allowGeolocation, isFalse);
      expect(policy.csp, contains("connect-src 'none'"));
    });

    test('未知 network 按 deny fail-closed', () {
      final policy = _policyFor(const <String>{'host'}, network: 'anything');
      expect(policy.network, 'deny');
    });

    test('permissions / allowedMethods 为不可修改集合', () {
      final policy = _policyFor(const <String>{'host'});
      expect(() => policy.permissions.add('storage'), throwsUnsupportedError);
      expect(
        () => policy.allowedMethods.add('storage.get'),
        throwsUnsupportedError,
      );
    });
  });

  group('会话生命周期', () {
    test('start 从 created 进入 running 并发送 host.ready 通知', () async {
      final harness = _Harness();
      expect(harness.session.state, PluginSandboxState.created);

      await harness.session.start();

      expect(harness.session.state, PluginSandboxState.running);
      expect(harness.channel.sent, hasLength(1));
      final message = _decode(harness.channel.sent.single);
      expect(message, isA<PluginBridgeNotification>());
      final notification = message as PluginBridgeNotification;
      expect(notification.method, 'host.ready');
      expect(notification.params['pluginId'], 'plugin.one');
      expect(notification.params['bundleId'], 'bundle.one');
      expect(notification.params['apiVersion'], pluginBridgeProtocolVersion);
    });

    test('重复 start 抛 StateError', () async {
      final harness = await _startHarness();
      await expectLater(harness.session.start(), throwsStateError);
    });

    test('start 之前 handleRaw 抛 StateError', () async {
      final harness = _Harness();
      await expectLater(
        harness.session.handleRaw(_requestJson(method: 'host.getInfo')),
        throwsStateError,
      );
    });

    test('stop 关闭通道，之后 handleRaw 抛 StateError', () async {
      final harness = await _startHarness();
      await harness.session.stop();

      expect(harness.session.state, PluginSandboxState.stopped);
      expect(harness.channel.closed, isTrue);
      await expectLater(
        harness.session.handleRaw(_requestJson(method: 'host.getInfo')),
        throwsStateError,
      );
    });

    test('stop 幂等', () async {
      final harness = await _startHarness();
      await harness.session.stop();
      await harness.session.stop();
      expect(harness.session.state, PluginSandboxState.stopped);
      expect(harness.channel.closed, isTrue);
    });

    test('sendEvent 发送合法 JSON-RPC 通知', () async {
      final harness = await _startHarness();
      await harness.session.sendEvent(
        'message.onMessage',
        const <String, Object?>{'conversationId': 'c1', 'text': '你好'},
      );

      final message = _decode(harness.channel.sent.last);
      expect(message, isA<PluginBridgeNotification>());
      final notification = message as PluginBridgeNotification;
      expect(notification.method, 'message.onMessage');
      expect(notification.params['conversationId'], 'c1');
      expect(notification.params['text'], '你好');
      final raw = _jsonOf(harness.channel.sent.last);
      expect(raw['jsonrpc'], '2.0');
      expect(raw.containsKey('id'), isFalse);
    });

    test('sendEvent 在非 running 状态抛 StateError', () async {
      final harness = _Harness();
      await expectLater(
        harness.session.sendEvent('message.onMessage', const {}),
        throwsStateError,
      );
      await harness.session.start();
      await harness.session.stop();
      await expectLater(
        harness.session.sendEvent('message.onMessage', const {}),
        throwsStateError,
      );
    });
  });

  group('请求分发：允许与拒绝', () {
    test('允许的请求经网关成功返回，并携带 plugin/bundle/method/scope/params', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
      );
      harness.gateway.onInvoke = (request) async => <String, Object?>{
        'version': '1.0.0',
      };

      await harness.session.handleRaw(
        _requestJson(id: 7, method: 'host.getInfo'),
      );

      expect(harness.gateway.requests, hasLength(1));
      final gatewayRequest = harness.gateway.requests.single;
      expect(gatewayRequest.pluginId, 'plugin.one');
      expect(gatewayRequest.bundleId, 'bundle.one');
      expect(gatewayRequest.method, 'host.getInfo');
      expect(gatewayRequest.scope, 'host');
      expect(gatewayRequest.params, isEmpty);

      final message = _decode(harness.channel.sent.last);
      expect(message, isA<PluginBridgeSuccess>());
      final success = message as PluginBridgeSuccess;
      expect(success.id, 7);
      expect(success.result, <String, Object?>{'version': '1.0.0'});

      expect(harness.session.auditLog.last.allowed, isTrue);
      expect(harness.session.auditLog.last.errorCode, isNull);
    });

    test('未授予 scope 的方法返回 permissionDenied 且不调用网关', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'storage'}),
      );
      await harness.session.handleRaw(
        _requestJson(id: 3, method: 'host.getInfo'),
      );

      expect(harness.gateway.requests, isEmpty);
      final failure = _decode(harness.channel.sent.last) as PluginBridgeFailure;
      expect(failure.id, 3);
      expect(failure.code, PluginBridgeErrorCode.permissionDenied);
      expect(_errorCodeOf(harness.channel.sent.last), -32001);
      final audit = harness.session.auditLog.last;
      expect(audit.allowed, isFalse);
      expect(audit.errorCode, PluginBridgeErrorCode.permissionDenied);
    });

    test('allowedMethods 与 permissions 不一致时仍拒绝（scope 二次校验）', () async {
      final policy = PluginSandboxPolicy(
        pluginId: 'p1',
        bundleId: 'b1',
        origin: 'jingyu-plugin://b1/p1',
        csp: pluginSandboxCsp,
        permissions: const <String>{'storage'},
        allowedMethods: const <String>{'host.getInfo'},
      );
      final harness = await _startHarness(policy: policy);
      await harness.session.handleRaw(_requestJson(method: 'host.getInfo'));

      expect(harness.gateway.requests, isEmpty);
      expect(
        _errorCodeOf(harness.channel.sent.last),
        PluginBridgeErrorCode.permissionDenied.code,
      );
    });

    test('未知方法返回 methodNotFound', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
      );
      await harness.session.handleRaw(
        _requestJson(id: 11, method: 'host.unknownMethod'),
      );

      expect(harness.gateway.requests, isEmpty);
      final failure = _decode(harness.channel.sent.last) as PluginBridgeFailure;
      expect(failure.id, 11);
      expect(failure.code, PluginBridgeErrorCode.methodNotFound);
      expect(
        harness.session.auditLog.last.errorCode,
        PluginBridgeErrorCode.methodNotFound,
      );
    });

    test('chat.sendText 使用 chat.send scope', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'chat.send'}),
      );
      await harness.session.handleRaw(
        _requestJson(
          method: 'chat.sendText',
          params: const <String, Object?>{'conversationId': 'c1', 'text': 'hi'},
        ),
      );

      expect(harness.gateway.requests.single.scope, 'chat.send');
      expect(harness.gateway.requests.single.params['text'], 'hi');
      expect(_decode(harness.channel.sent.last), isA<PluginBridgeSuccess>());
    });

    test('ui.registerSlot 非法 slot 返回 invalidParams', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'ui.slot'}),
      );

      await harness.session.handleRaw(
        _requestJson(method: 'ui.registerSlot', params: const {}),
      );
      expect(
        _errorCodeOf(harness.channel.sent.last),
        PluginBridgeErrorCode.invalidParams.code,
      );

      await harness.session.handleRaw(
        _requestJson(
          method: 'ui.registerSlot',
          params: const <String, Object?>{'slot': 'shell.notARealSlot'},
        ),
      );
      expect(
        _errorCodeOf(harness.channel.sent.last),
        PluginBridgeErrorCode.invalidParams.code,
      );

      await harness.session.handleRaw(
        _requestJson(
          method: 'ui.registerSlot',
          params: const <String, Object?>{'slot': 42},
        ),
      );
      expect(
        _errorCodeOf(harness.channel.sent.last),
        PluginBridgeErrorCode.invalidParams.code,
      );

      expect(harness.gateway.requests, isEmpty);
      expect(
        harness.session.auditLog.last.errorCode,
        PluginBridgeErrorCode.invalidParams,
      );
    });

    test('ui.registerSlot 接受静态 slot 与动态消息卡片 slot', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'ui.slot'}),
      );

      await harness.session.handleRaw(
        _requestJson(
          method: 'ui.registerSlot',
          params: const <String, Object?>{'slot': 'settings.section'},
        ),
      );
      await harness.session.handleRaw(
        _requestJson(
          method: 'ui.registerSlot',
          params: const <String, Object?>{
            'slot': 'conversation.message.card.vendor.custom',
          },
        ),
      );

      expect(harness.gateway.requests, hasLength(2));
      expect(_decode(harness.channel.sent.last), isA<PluginBridgeSuccess>());
    });

    test('成功响应是合法 JSON-RPC 2.0（仅 jsonrpc/id/result）', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
      );
      harness.gateway.onInvoke = (request) async => 'pong';
      await harness.session.handleRaw(
        _requestJson(id: 'req-1', method: 'host.getInfo'),
      );

      final raw = harness.channel.sent.last;
      final map = _jsonOf(raw);
      expect(map.keys.toSet(), <String>{'jsonrpc', 'id', 'result'});
      expect(map['jsonrpc'], '2.0');
      expect(map['id'], 'req-1');
      expect(map['result'], 'pong');
      final message = _decode(raw);
      expect(message, isA<PluginBridgeSuccess>());
      expect((message as PluginBridgeSuccess).id, 'req-1');
    });

    test('失败响应是合法 JSON-RPC 2.0（仅 jsonrpc/id/error）', () async {
      final harness = await _startHarness(policy: _policyFor(const <String>{}));
      await harness.session.handleRaw(
        _requestJson(id: 'req-2', method: 'host.getInfo'),
      );

      final raw = harness.channel.sent.last;
      final map = _jsonOf(raw);
      expect(map.keys.toSet(), <String>{'jsonrpc', 'id', 'error'});
      expect(map['jsonrpc'], '2.0');
      expect(map['id'], 'req-2');
      final error = map['error'] as Map<String, Object?>;
      expect(error['code'], -32001);
      expect(error['message'], isA<String>());
      final message = _decode(raw) as PluginBridgeFailure;
      expect(message.id, 'req-2');
      expect(message.code, PluginBridgeErrorCode.permissionDenied);
    });

    test('网关抛异常返回 internalError', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
      );
      harness.gateway.onInvoke = (request) async {
        throw StateError('boom');
      };
      await harness.session.handleRaw(_requestJson(id: 5, method: 'host.log'));

      expect(
        _errorCodeOf(harness.channel.sent.last),
        PluginBridgeErrorCode.internalError.code,
      );
      final audit = harness.session.auditLog.last;
      expect(audit.allowed, isTrue);
      expect(audit.errorCode, PluginBridgeErrorCode.internalError);
    });

    test('网关超时返回 timeout', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
        limits: const PluginSandboxLimits(
          callTimeout: Duration(milliseconds: 20),
        ),
      );
      final completer = Completer<Object?>();
      harness.gateway.onInvoke = (request) => completer.future;

      await harness.session.handleRaw(_requestJson(id: 6, method: 'host.log'));

      expect(
        _errorCodeOf(harness.channel.sent.last),
        PluginBridgeErrorCode.timeout.code,
      );
      expect(
        harness.session.auditLog.last.errorCode,
        PluginBridgeErrorCode.timeout,
      );
    });

    test('网关返回 null 时也是成功响应（result 为 null）', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
      );
      harness.gateway.onInvoke = (request) async => null;
      await harness.session.handleRaw(_requestJson(id: 8, method: 'host.log'));

      final map = _jsonOf(harness.channel.sent.last);
      expect(map.containsKey('result'), isTrue);
      expect(map['result'], isNull);
      expect(_decode(harness.channel.sent.last), isA<PluginBridgeSuccess>());
    });
  });

  group('消息大小与 JSON 校验', () {
    test('超过 maxMessageBytes 返回 messageTooLarge 并审计', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
        limits: const PluginSandboxLimits(maxMessageBytes: 64),
      );
      final raw =
          '{"jsonrpc":"2.0","id":1,"method":"host.log","params":{"text":"'
          '${'x' * 200}"}}';
      expect(utf8.encode(raw).length, greaterThan(64));

      await harness.session.handleRaw(raw);

      final map = _jsonOf(harness.channel.sent.last);
      expect(map['jsonrpc'], '2.0');
      expect(map['id'], isNull);
      final error = map['error'] as Map<String, Object?>;
      expect(error['code'], PluginBridgeErrorCode.messageTooLarge.code);
      final audit = harness.session.auditLog.last;
      expect(audit.allowed, isFalse);
      expect(audit.errorCode, PluginBridgeErrorCode.messageTooLarge);
    });

    test('畸形 JSON 返回 parseError', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
      );
      await harness.session.handleRaw('{"jsonrpc": 2.0,');

      final message = _decode(harness.channel.sent.last) as PluginBridgeFailure;
      expect(message.id, isNull);
      expect(message.code, PluginBridgeErrorCode.parseError);
      expect(_errorCodeOf(harness.channel.sent.last), -32700);
      expect(
        harness.session.auditLog.last.errorCode,
        PluginBridgeErrorCode.parseError,
      );
    });

    test('JSON 合法但结构非法返回 invalidRequest', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
      );
      await harness.session.handleRaw(
        '{"jsonrpc":"1.0","id":9,"method":"host.log"}',
      );

      expect(
        _errorCodeOf(harness.channel.sent.last),
        PluginBridgeErrorCode.invalidRequest.code,
      );
      expect(
        harness.session.auditLog.last.errorCode,
        PluginBridgeErrorCode.invalidRequest,
      );
    });

    test('超过 maxJsonDepth 的消息被拒绝', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
        limits: const PluginSandboxLimits(maxJsonDepth: 4),
      );
      await harness.session.handleRaw(
        '{"jsonrpc":"2.0","id":1,"method":"host.log",'
        '"params":{"a":{"b":{"c":{"d":1}}}}}',
      );

      expect(
        _errorCodeOf(harness.channel.sent.last),
        PluginBridgeErrorCode.invalidRequest.code,
      );
      expect(harness.gateway.requests, isEmpty);
    });

    test('上限以内的消息正常通过', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
        limits: const PluginSandboxLimits(maxMessageBytes: 512),
      );
      await harness.session.handleRaw(
        _requestJson(
          method: 'host.log',
          params: const <String, Object?>{'m': 'ok'},
        ),
      );
      expect(_decode(harness.channel.sent.last), isA<PluginBridgeSuccess>());
    });
  });

  group('限流与并发', () {
    test('超过 maxCallsPerMinute 返回 rateLimited', () async {
      final clock = _FakeClock();
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
        limits: const PluginSandboxLimits(maxCallsPerMinute: 2),
        clock: clock.call,
      );

      await harness.session.handleRaw(_requestJson(id: 1, method: 'host.log'));
      await harness.session.handleRaw(_requestJson(id: 2, method: 'host.log'));
      await harness.session.handleRaw(_requestJson(id: 3, method: 'host.log'));

      expect(harness.gateway.requests, hasLength(2));
      expect(
        _errorCodeOf(harness.channel.sent.last),
        PluginBridgeErrorCode.rateLimited.code,
      );
      expect(
        harness.session.auditLog.last.errorCode,
        PluginBridgeErrorCode.rateLimited,
      );
    });

    test('滑动窗口 60 秒后恢复调用', () async {
      final clock = _FakeClock();
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
        limits: const PluginSandboxLimits(maxCallsPerMinute: 1),
        clock: clock.call,
      );

      await harness.session.handleRaw(_requestJson(id: 1, method: 'host.log'));
      await harness.session.handleRaw(_requestJson(id: 2, method: 'host.log'));
      expect(
        _errorCodeOf(harness.channel.sent.last),
        PluginBridgeErrorCode.rateLimited.code,
      );

      clock.advance(const Duration(minutes: 1, seconds: 1));
      await harness.session.handleRaw(_requestJson(id: 3, method: 'host.log'));

      expect(harness.gateway.requests, hasLength(2));
      expect(_decode(harness.channel.sent.last), isA<PluginBridgeSuccess>());
    });

    test('超过 maxInFlight 时拒绝并发调用，完成后可继续', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
        limits: const PluginSandboxLimits(maxInFlight: 1),
      );
      final completer = Completer<Object?>();
      harness.gateway.onInvoke = (request) => completer.future;

      final first = harness.session.handleRaw(
        _requestJson(id: 1, method: 'host.log'),
      );
      await harness.session.handleRaw(_requestJson(id: 2, method: 'host.log'));

      expect(
        _errorCodeOf(harness.channel.sent.last),
        PluginBridgeErrorCode.rateLimited.code,
      );
      expect(harness.gateway.requests, hasLength(1));

      completer.complete(const <String, Object?>{'ok': true});
      await first;
      expect(_decode(harness.channel.sent.last), isA<PluginBridgeSuccess>());
    });
  });

  group('插件通知', () {
    test('host.log 通知调用网关但不返回响应', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'host'}),
      );
      final sentBefore = harness.channel.sent.length;

      await harness.session.handleRaw(
        _notificationJson('host.log', const <String, Object?>{'message': 'hi'}),
      );

      expect(harness.gateway.requests, hasLength(1));
      expect(harness.gateway.requests.single.method, 'host.log');
      expect(harness.channel.sent, hasLength(sentBefore));
      expect(harness.session.auditLog.last.allowed, isTrue);
    });

    test('未知通知不返回响应且记录 methodNotFound', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'events'}),
      );
      final sentBefore = harness.channel.sent.length;

      await harness.session.handleRaw(
        _notificationJson('events.emit', const <String, Object?>{'name': 'x'}),
      );

      expect(harness.gateway.requests, isEmpty);
      expect(harness.channel.sent, hasLength(sentBefore));
      expect(
        harness.session.auditLog.last.errorCode,
        PluginBridgeErrorCode.methodNotFound,
      );
    });

    test('无 host 权限时 host.log 通知被拒绝', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'storage'}),
      );
      await harness.session.handleRaw(
        _notificationJson('host.log', const <String, Object?>{'message': 'hi'}),
      );

      expect(harness.gateway.requests, isEmpty);
      expect(
        harness.session.auditLog.last.errorCode,
        PluginBridgeErrorCode.permissionDenied,
      );
    });
  });

  group('审计', () {
    test('审计不记录 params 内容（正文 / 密钥不泄漏）', () async {
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'chat.send'}),
      );
      harness.gateway.onInvoke = (request) async => const <String, Object?>{
        'ok': true,
      };

      await harness.session.handleRaw(
        _requestJson(
          method: 'chat.sendText',
          params: const <String, Object?>{
            'text': '绝密正文：今晚见',
            'apiKey': 'sk-live-secret',
          },
        ),
      );

      final entry = harness.session.auditLog.last;
      expect(entry.method, 'chat.sendText');
      expect(entry.allowed, isTrue);
      expect(entry.pluginId, 'plugin.one');
      final serialized = entry.toString();
      expect(serialized, isNot(contains('绝密正文')));
      expect(serialized, isNot(contains('sk-live-secret')));
      expect(serialized, isNot(contains('今晚见')));
      expect(serialized, contains('chat.sendText'));
    });

    test('onAudit 证据回调收到完整审计条目', () async {
      final collected = <PluginSandboxAuditEntry>[];
      final harness = await _startHarness(
        policy: _policyFor(const <String>{'storage'}),
        onAudit: collected.add,
      );
      await harness.session.handleRaw(_requestJson(method: 'host.getInfo'));

      expect(collected, hasLength(1));
      expect(
        collected.single.errorCode,
        PluginBridgeErrorCode.permissionDenied,
      );
      expect(
        identical(collected.single, harness.session.auditLog.single),
        isTrue,
      );
    });

    test('auditLog 为不可修改快照', () async {
      final harness = await _startHarness();
      await harness.session.handleRaw(_requestJson(method: 'host.log'));
      final log = harness.session.auditLog;
      expect(() => log.clear(), throwsUnsupportedError);
    });
  });

  group('PluginSandbox 会话管理', () {
    test('open 创建并启动会话，close 关闭指定插件会话', () async {
      final sandbox = PluginSandbox();
      final channel = _FakeChannel();
      final session = await sandbox.open(
        policy: _policyFor(const <String>{'host'}),
        channel: channel,
        gateway: _FakeGateway(),
      );

      expect(session.state, PluginSandboxState.running);
      expect(sandbox.sessions, hasLength(1));
      expect(sandbox.sessions.single.policy.pluginId, 'plugin.one');

      await sandbox.close('plugin.one');
      expect(session.state, PluginSandboxState.stopped);
      expect(channel.closed, isTrue);
      expect(sandbox.sessions, isEmpty);
    });

    test('同一 pluginId 重复 open 抛 StateError', () async {
      final sandbox = PluginSandbox();
      await sandbox.open(
        policy: _policyFor(const <String>{'host'}),
        channel: _FakeChannel(),
        gateway: _FakeGateway(),
      );
      await expectLater(
        sandbox.open(
          policy: _policyFor(const <String>{'host'}),
          channel: _FakeChannel(),
          gateway: _FakeGateway(),
        ),
        throwsStateError,
      );
    });

    test('closeAll 关闭全部会话', () async {
      final sandbox = PluginSandbox();
      final channelA = _FakeChannel();
      final channelB = _FakeChannel();
      await sandbox.open(
        policy: _policyFor(const <String>{'host'}, pluginId: 'plugin.a'),
        channel: channelA,
        gateway: _FakeGateway(),
      );
      await sandbox.open(
        policy: _policyFor(const <String>{'host'}, pluginId: 'plugin.b'),
        channel: channelB,
        gateway: _FakeGateway(),
      );
      expect(sandbox.sessions, hasLength(2));

      await sandbox.closeAll();

      expect(channelA.closed, isTrue);
      expect(channelB.closed, isTrue);
      expect(sandbox.sessions, isEmpty);
    });

    test('close 未知 pluginId 为空操作', () async {
      final sandbox = PluginSandbox();
      await sandbox.close('not.installed');
      expect(sandbox.sessions, isEmpty);
    });
  });
}
