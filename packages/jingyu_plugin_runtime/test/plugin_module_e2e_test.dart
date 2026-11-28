/// 插件模块端到端契约测试：加载 → 管理器安装/启停 → 沙箱能力桥。
///
/// 使用真实 `buildPluginPackage` 构造 zip 字节，不 mock 加载器/管理器；
/// 沙箱用假通道/假网关验证协议输出，避免依赖 Flutter/WebView。
library;

import 'dart:convert';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_plugin_runtime/jingyu_plugin_runtime.dart';
import 'package:test/test.dart';

Map<String, Object?> _bundleManifest({
  String version = '1.0.0',
  String entryId = 'com.example.hello.card',
  List<String> permissions = const <String>['chat.send', 'storage', 'ui.slot'],
}) {
  return <String, Object?>{
    'id': 'com.example.hello',
    'name': 'Hello 插件',
    'version': version,
    'apiVersion': pluginApiVersion,
    'type': 'bundle',
    'plugins': <Object?>[
      <String, Object?>{
        'runtime': 'webview',
        'id': entryId,
        'entry': 'web/index.html',
        'slots': <String>['conversation.message.card.hello'],
        'permissions': permissions,
      },
      <String, Object?>{
        'runtime': 'declarative',
        'id': 'com.example.hello.data',
        'slots': <String>['room.furniture'],
      },
    ],
    'platforms': <String>['android', 'windows'],
  };
}

BuiltPluginPackage _buildPackage({
  String version = '1.0.0',
  String entryId = 'com.example.hello.card',
  List<String> permissions = const <String>['chat.send', 'storage', 'ui.slot'],
}) {
  return buildPluginPackage(
    manifest: _bundleManifest(
      version: version,
      entryId: entryId,
      permissions: permissions,
    ),
    files: <String, List<int>>{
      'web/index.html': utf8.encode('<html><body>hello</body></html>'),
      'config.schema.json': utf8.encode('{"type":"object"}'),
    },
  );
}

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

class _FakeGateway implements PluginSandboxGateway {
  final List<PluginGatewayRequest> requests = <PluginGatewayRequest>[];

  @override
  Future<Object?> invoke(PluginGatewayRequest request) async {
    requests.add(request);
    return <String, Object?>{'ok': true, 'method': request.method};
  }
}

void main() {
  test('加载 → 安装 → 沙箱调用 → 持久化恢复，全链路可用', () async {
    final built = _buildPackage();

    // 1. 加载：真实 zip 字节 → 运行期描述。
    final loaded = loadPluginBundle(
      built.bytes,
      platform: 'windows',
      expectedSha256Hex: built.sha256Hex,
    );
    expect(loaded.ok, isTrue, reason: loaded.issues.join('; '));
    expect(loaded.bundle!.entries, hasLength(2));
    expect(loaded.bundle!.entries[0].runtime, PluginRuntime.webview);
    expect(loaded.bundle!.entries[0].permissions, contains('chat.send'));
    expect(loaded.bundle!.files['web/index.html'], isNotEmpty);

    // 2. 管理器：安装（审批硬要求）并持久化。
    final store = InMemoryPluginManagerStore();
    final manager = PluginManager(store: store, platform: 'windows');
    await manager.restore();
    final notApproved = await manager.install(
      built.bytes,
      source: PluginInstallSource.imported,
    );
    expect(notApproved.ok, isFalse);
    expect(notApproved.issue!.code, PluginManagerIssueCode.approvalRequired);

    final installed = await manager.install(
      built.bytes,
      source: PluginInstallSource.imported,
      grantedPermissions: const <String>{'chat.send', 'storage', 'ui.slot'},
      userApproved: true,
      expectedSha256Hex: built.sha256Hex,
    );
    expect(installed.ok, isTrue, reason: installed.issue?.message);
    expect(manager.enabledBundleIds, contains('com.example.hello'));

    // 3. 沙箱：独立 origin / CSP / scope 白名单 + JSON-RPC 能力桥。
    final record = manager.installed.single;
    final policy = PluginSandboxPolicy.forEntry(
      bundleId: record.bundleId,
      entry: record.entries.first,
    );
    expect(policy.origin, startsWith('jingyu-plugin://'));
    expect(policy.csp, contains("connect-src 'none'"));
    expect(policy.allowedMethods, contains('chat.sendText'));
    expect(policy.allowedMethods, isNot(contains('model.invoke')));

    final channel = _FakeChannel();
    final gateway = _FakeGateway();
    final sandbox = PluginSandbox();
    final session = await sandbox.open(
      policy: policy,
      channel: channel,
      gateway: gateway,
    );
    expect(session.state, PluginSandboxState.running);
    // start() 发出了 host.ready。
    expect(channel.sent, hasLength(1));

    await session.handleRaw(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'chat.sendText',
        'params': <String, Object?>{'conversationId': 'c1', 'text': 'hi'},
      }),
    );
    expect(gateway.requests, hasLength(1));
    final response = jsonDecode(channel.sent.last) as Map<String, Object?>;
    expect(response['jsonrpc'], '2.0');
    expect(response['id'], 1);
    expect((response['result'] as Map<String, Object?>)['ok'], isTrue);

    // 未授权 scope：拒绝且不进入网关。
    await session.handleRaw(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'model.invoke',
        'params': <String, Object?>{},
      }),
    );
    expect(gateway.requests, hasLength(1));
    final denied = jsonDecode(channel.sent.last) as Map<String, Object?>;
    expect((denied['error'] as Map<String, Object?>)['code'], -32001);
    // 审计只记方法名与结果，不记录 params 正文。
    expect(session.auditLog, isNotEmpty);
    expect(session.auditLog.last.method, 'model.invoke');
    expect(session.auditLog.last.allowed, isFalse);

    // 4. 持久化恢复：新管理器从同一 store 读回安装记录。
    final restored = PluginManager(store: store, platform: 'windows');
    await restored.restore();
    expect(restored.installed, hasLength(1));
    expect(restored.installed.single.bundleId, 'com.example.hello');
    expect(restored.installed.single.version, '1.0.0');

    // 5. 启停与卸载的依赖/状态边界。
    final disabled = await manager.setEnabled('com.example.hello', false);
    expect(disabled.ok, isTrue);
    expect(manager.isPluginEnabled('com.example.hello.card'), isFalse);
    final uninstalled = await manager.uninstall('com.example.hello');
    expect(uninstalled.ok, isTrue);
    expect(manager.installed, isEmpty);

    await sandbox.closeAll();
    expect(channel.closed, isTrue);
  });

  test('更新只接受更高版本，并保留配置', () async {
    final v1 = _buildPackage();
    final v2 = _buildPackage(version: '1.0.1');

    final store = InMemoryPluginManagerStore();
    final manager = PluginManager(store: store, platform: 'android');
    await manager.restore();
    final installed = await manager.install(
      v1.bytes,
      source: PluginInstallSource.market,
      grantedPermissions: const <String>{'chat.send', 'storage', 'ui.slot'},
      userApproved: true,
    );
    expect(installed.ok, isTrue);

    final config = <String, Object?>{'greeting': '你好'};
    expect((await manager.setConfig('com.example.hello', config)).ok, isTrue);

    final downgraded = await manager.update(
      v1.bytes,
      grantedPermissions: const <String>{'chat.send', 'storage', 'ui.slot'},
      userApproved: true,
    );
    expect(downgraded.ok, isFalse);
    expect(downgraded.issue!.code, PluginManagerIssueCode.versionNotNewer);

    final updated = await manager.update(
      v2.bytes,
      grantedPermissions: const <String>{'chat.send', 'storage', 'ui.slot'},
      userApproved: true,
    );
    expect(updated.ok, isTrue, reason: updated.issue?.message);
    expect(manager.installed.single.version, '1.0.1');
    expect(manager.snapshot.config['com.example.hello'], config);
  });

  test('加载失败不会进入管理器状态', () async {
    final built = _buildPackage(permissions: const <String>['model.invoke']);
    final store = InMemoryPluginManagerStore();
    final manager = PluginManager(store: store, platform: 'windows');
    await manager.restore();

    final outcome = await manager.install(
      built.bytes,
      source: PluginInstallSource.imported,
      grantedPermissions: const <String>{'chat.send'},
      userApproved: true,
    );
    expect(outcome.ok, isFalse);
    expect(outcome.issue!.code, PluginManagerIssueCode.permissionNotGranted);
    expect(manager.installed, isEmpty);
  });
}
