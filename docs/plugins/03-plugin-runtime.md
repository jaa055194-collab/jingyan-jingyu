# 03 · 插件运行时内核（加载 / 管理器 / 沙箱）

> 代码：`packages/jingyu_protocol/lib/src/plugin_bridge.dart`、`packages/jingyu_client_kit/lib/src/plugin_package.dart`、`packages/jingyu_plugin_runtime/lib/src/{plugin_loader,plugin_manager,plugin_sandbox}.dart`。
> 测试：上述各包的 `test/`（`plugin_bridge_test.dart`、`plugin_package_extractor_test.dart`、`plugin_loader_test.dart`、`plugin_manager_test.dart`、`plugin_sandbox_test.dart`）。
> 依据：插件方案 v3 §4/§5/§7 与 §9 阶段 1。本文件描述的是**纯 Dart、无 IO、不依赖 Flutter** 的运行时内核，不是完整的插件生态。

## 1. 范围与边界

### 1.1 本切片已实现

- **加载**：插件包字节 → 安全校验 → 有界解包 → `PluginBundle` 强类型解析 → 运行期描述（runtime / entry / slots / permissions / configSchema / network）；校验 API 版本、平台、入口文件、配置 schema 与依赖。
- **管理器**：安装 / 更新 / 启用 / 停用 / 卸载 / 配置；权限审批为硬要求；依赖检查；版本递增检查；状态快照持久化（存储由调用方注入）。
- **沙箱策略与能力桥**：每个插件独立 origin、固定 CSP、默认禁网；JSON-RPC 2.0 编解码、方法白名单 + scope 校验、消息大小/深度限制、限流、并发上限、调用超时与无正文审计。

### 1.2 明确未实现（不得当作完整插件系统或 M11 验收）

- **Flutter WebView 平台适配器与 UI**：Android WebView / Windows WebView2 的窗口宿主、导航/下载/DevTools/文件访问/设备权限的实际拦截、slot 渲染层。
- **安装 UI / 插件管理器 UI / 配置自动表单**。
- **私有插件市场**（本地目录 / 私有 Git / 局域网索引）。
- **HMR 热重载**与**动态生成插件**（生成 → 校验 → 用户确认 → 沙箱加载 → 回滚）。
- **真实签名**：当前只有 sha256 完整性校验，能发现包内容与预期哈希不一致，但不证明发布者身份。
- **preset 组合、JS SDK 包（`@jingyu/plugin-sdk`）**。
- `runtime: dart` 的宿主插件只完成描述、平台与依赖校验；**不提供进程隔离、源码审查或安装执行机制**。

### 1.3 残余风险（如实记录）

- **WebView 引擎 0day**：CSP、origin 隔离、禁网与导航约束只能降低风险，无法防御 WebView 内核漏洞；真实平台适配器上线前，本切片提供的只是策略数据，不是已生效的隔离。
- **宿主 Dart 插件 = 信任其代码**：`runtime: dart` 在宿主进程内运行，拥有全能力；本切片只做声明级校验，不能把“通过加载检查”当作安全背书。
- **策略与执行分离**：导航、下载、DevTools、文件访问、地理位置等开关由平台适配器落实；纯 Dart 层无法证明它们在双端真实生效。
- **`network: host-gateway` 不等于直连**：它表示出站仍须经宿主网关（如 `UrlGuard`），本切片不实现网关，也不扩大任何网络访问范围。
- **持久化由外层负责**：`PluginManagerStore` 只定义接口；落盘加密、备份、损坏恢复与多进程并发由平台外壳实现。
- **包完整性不等于来源可信**：sha256 可被篡改者连同包一起替换；可选签名的验证留待后续。

## 2. 模块结构

| 包 / 文件 | 职责 |
|---|---|
| `jingyu_protocol/lib/src/plugin_bridge.dart` | 桥协议常量、`PluginBridgeLimits`、JSON-RPC 2.0 消息模型与严格编解码、错误码、方法目录 `PluginBridgeApi`（methods / scopes / slotKeys）。 |
| `jingyu_client_kit/lib/src/plugin_package.dart` | 既有 `validatePluginPackage`（纯校验）与新增 `extractPluginPackage`（校验通过后的安全有界解包，纯内存、不含目录条目）。 |
| `jingyu_plugin_runtime/lib/src/plugin_loader.dart` | `loadPluginBundle`：包字节 → `PluginBundle` → `LoadedPluginBundle` / `LoadedPluginEntry` 运行期描述。 |
| `jingyu_plugin_runtime/lib/src/plugin_manager.dart` | `PluginManager`：安装、更新、启停、卸载、配置、权限审批、依赖与持久化快照。 |
| `jingyu_plugin_runtime/lib/src/plugin_sandbox.dart` | `PluginSandboxPolicy` / `PluginSandboxSession` / `PluginSandbox`：策略生成、JSON-RPC 能力桥、限流、超时、审计。 |
| `jingyu_plugin_runtime/lib/jingyu_plugin_runtime.dart` | 统一导出以上三块能力。 |

依赖方向：`jingyu_plugin_runtime` 依赖 `jingyu_core` + `jingyu_protocol` + `jingyu_client_kit`，**不 import Flutter，也不 import `dart:io`**；平台 IO 与 WebView 由调用方注入。

## 3. 加载流程（字节 → 校验 → 解包 → bundle 解析 → 运行期描述）

```text
插件包字节 Uint8List
  │
  ├─ 1. validatePluginPackage（既有）：非空 / zip / 条目数 / 单条体积 / 总量 / 压缩比 /
  │       zip-slip / 重复条目 / 符号链接 / 清单存在与严格解析 / sha256 完整性
  ├─ 2. extractPluginPackage：仅在校验 ok 后 ZipDecoder；逐条 sanitizePackageEntryPath；
  │       跳过目录与符号链接；复用有界流式 inflate，按真实输出字节封顶；
  │       files 只读（含根 plugin.json），任何失败 ok=false 且 files 为空
  ├─ 3. PluginBundle.fromJson：严格解析 bundle（id/name/version/apiVersion/type/plugins/
  │       dependencies/platforms/integrity）；失败 → bundleInvalid
  ├─ 4. 运行期检查：apiVersion / platforms / 入口文件是否存在 / configSchema /
  │       依赖是否由 installedVersions 满足 / bundle 内插件 id 唯一
  └─ 5. LoadedPluginBundle：bundle + files + sha256Hex + List<LoadedPluginEntry>
```

`LoadedPluginEntry` 字段：`id`、`runtime`（`webview` / `dart` / `declarative`）、`entry`、`slots`、`permissions`、`configSchema`、`configSchemaJson`、`network`（默认 `deny`）。

失败码 `PluginLoadIssueCode`：

| 代码 | 含义 |
|---|---|
| `packageInvalid` | 包校验/解包失败（每个 issue 一条 message，保留条目路径）。 |
| `bundleInvalid` | `plugin.json` 不是对象或 `PluginBundle.fromJson` 解析失败。 |
| `apiVersionMismatch` | `bundle.apiVersion != hostApiVersion`。 |
| `platformUnsupported` | 当前平台不在 `bundle.platforms` 内。 |
| `missingEntryFile` | `webview` / `dart` 缺 `entry`，或声明的入口文件不在包内；`declarative` 若声明了 `entry` 也必须存在。 |
| `configInvalid` | `configSchema` 文件不存在、不是合法 JSON 对象，或顶层 `type` 存在但不是字符串。 |
| `dependencyUnmet` | 依赖未安装或版本区间不满足（`unmetDependencies(installedVersions)` 逐条报告）。 |
| `duplicatePluginId` | bundle 内插件 id 重复（大小写不敏感）；多行 bundle 缺 id 且无法用 `bundle.id` 唯一标识。 |

规则：单行插件且该行无 `id` 时使用 `bundle.id`；`webview` / `dart` 必须有 `entry`；任何 issue 都使 `ok=false`，结果不可变。

## 4. 管理器状态机与持久化接口

### 4.1 状态机

```text
                 install（userApproved=true，权限齐全）
   未安装 ─────────────────────────────────────────────▶ 已安装 enabled=true
                                                          │  ▲
                                     setEnabled(false)    │  │ setEnabled(true)
                                                          ▼  │（依赖均启用）
                                                       已安装 enabled=false
   已安装 ── update（版本更新、权限不缩小）──▶ 已安装（保留 enabled 状态与 config）
   已安装 ── uninstall（无启用中的依赖方）──▶ 未安装
```

- 安装成功即 `enabled=true`（`userApproved` 表示用户已确认）；v3 的“安装后确认再启用”落在安装审批这一步。
- 依赖判定用 `installedVersions`（含未启用的 bundle）；启用判定要求依赖都由**已启用**插件满足。
- 停用/卸载前检查：若其他已启用 bundle 依赖本 bundle 的 entry id，返回 `dependentsExist`。

### 4.2 操作与失败码

| 操作 | 关键规则 |
|---|---|
| `install(bytes, source, grantedPermissions, userApproved)` | 任何安装都要求 `userApproved=true`（即使零权限，保守处理）；权限必须全部在 `grantedPermissions` 内；同 bundleId 已存在 → `alreadyInstalled`；加载失败 → `loadFailed`；依赖未满足 → `dependencyUnmet`；成功后追加 bundle 并持久化。 |
| `update(bytes, grantedPermissions, userApproved)` | 新包 bundleId 必须匹配已安装 bundle；`Version.parse(new) > Version.parse(old)`，否则 `versionNotNewer`；新权限 ⊆ 旧权限 ∪ 本次授予；新增权限要求 `userApproved`；保留旧 enabled 状态与 config；原子替换并保存。 |
| `setEnabled(bundleId, enabled)` | 停用检查启用中的依赖方；启用检查自身依赖；bundle 不存在 → `notFound`。 |
| `uninstall(bundleId)` | 有其它 bundle 依赖本 bundle → `dependentsExist`；删除其 config 并保存。 |
| `setConfig(bundleId, config)` | bundle 必须存在；config 必须可 `jsonEncode` 且为键值 map；保存成功后才替换内存快照。 |

失败码 `PluginManagerIssueCode`：`alreadyInstalled`、`notFound`、`versionNotNewer`、`bundleIdChanged`、`dependencyUnmet`、`dependentsExist`、`permissionNotGranted`、`approvalRequired`、`loadFailed`、`storeFailed`、`invalidState`。

### 4.3 持久化接口

```dart
abstract class PluginManagerStore {
  Future<PluginManagerState?> load();
  Future<void> save(PluginManagerState state);
}
```

- `PluginManagerState.schemaVersion` 固定为 `1`；`toJson` / `fromJson` 严格，坏数据抛 `FormatException`。
- `restore()` 只调用一次；快照 schemaVersion 不符或坏数据时保持空状态并记录 `lastLoadError`，不把损坏快照当有效状态。
- 所有变更 copy-on-write：先 `save` 成功，再替换内存快照；`save` 失败返回 `storeFailed` 且内存状态不变。
- `InMemoryPluginManagerStore` 供测试与演示；真实落盘由平台外壳实现。

## 5. 沙箱策略（origin / CSP / 禁网 / 方法 scope / 限流 / 超时 / 审计）

### 5.1 策略生成 `PluginSandboxPolicy.forEntry`

| 字段 | 规则 |
|---|---|
| `origin` | `jingyu-plugin://<encoded bundleId>/<encoded pluginId>`；bundleId 先转小写、两段都做 `Uri.encodeComponent`；拒绝空值与 `..`。 |
| `csp` | 固定为公开常量 `pluginSandboxCsp`，见 §5.2。 |
| `permissions` | 取自 `LoadedPluginEntry.permissions`（bundle 分发层字符串 scope，不并入旧 `PluginCapability` 枚举）。 |
| `allowedMethods` | `PluginBridgeApi.methods` 中 scope 属于 `permissions` 的方法名集合。 |
| `network` | `deny`（默认）或 `host-gateway`；其它值 fail-closed 按 `deny` 处理，两者在沙箱内都不允许直连外网。 |
| 平台开关 | `allowNavigation` / `allowNewWindows` / `allowDownloads` / `allowDevTools` / `allowFileAccess` / `allowGeolocation`，默认全部 `false`。 |

平台开关必须由平台适配器据此加固 WebView（导航 / 新窗口 / 下载 / DevTools / 文件访问 / 地理位置）；纯 Dart 策略层只描述“应当关闭”，不能证明平台侧已生效。

### 5.2 CSP

```text
default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline';
img-src 'self' data:; font-src 'self'; media-src 'self'; connect-src 'none';
object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'
```

`connect-src 'none'` 对 `deny` 与 `host-gateway` 都成立：插件不能直接 `fetch` / `WebSocket`，需要出站时只能经能力桥调用宿主网关，由宿主执行 `UrlGuard` 等既有约束。

### 5.3 能力桥与方法 scope

桥协议为 JSON-RPC 2.0，`pluginBridgeProtocolVersion = 1`。方法目录按命名空间划分：

| 命名空间 | 方法 | scope |
|---|---|---|
| `host` | `getInfo` / `log` / `openExternal` | `host` |
| `chat` | `sendText` / `sendCard` / `listConversations` | `chat.send` / `chat.read` |
| `message` | `recent` / `get` / `onMessage` | `message.read` / `message.events` |
| `model` | `invoke` | `model.invoke` |
| `storage` | `get` / `set` / `remove` / `keys`（插件私有） | `storage` |
| `ui` | `registerSlot` / `setTitle` / `close` / `toast` | `ui.slot` / `ui.chrome` |
| `world` | `getLayout` / `setLayout` / `onPresence` | `world.read` / `world.write` / `world.events` |
| `events` | `on` / `off` | `events` |
| `commands` | `registerSlash` | `commands` |
| `settings` | `read` / `write` | `config` |
| `notify` | `notify` | `notify` |

- 只有方法名在 `allowedMethods` 且 scope 在 `permissions` 内才允许调用，否则 `permissionDenied`。
- `ui.registerSlot` 的 `slot` 必须是 `PluginBridgeApi.slotKeys` 中的 key，或匹配 `conversation.message.card.` 前缀的动态 key；否则 `invalidParams`。
- 消息限制：`maxBytes = 256 KiB`、`maxDepth = 32`、`maxIdLength = 128`、`maxMethodLength = 128`、`maxStringLength = 64 KiB`；顶层必须是对象、`jsonrpc` 必须为 `"2.0"`、未知顶层字段拒绝。

### 5.4 限流、并发与超时

| 限制 | 默认值 | 说明 |
|---|---|---|
| `maxCallsPerMinute` | 120 | 每会话 60 秒滑动窗口；超限 `rateLimited`。 |
| `maxInFlight` | 8 | 并发中的调用数；超限返回 `rateLimited`。 |
| `callTimeout` | 10 秒 | `gateway.invoke` 超时返回 `timeout`。 |
| `maxMessageBytes` | 256 KiB | 超过记审计 `messageTooLarge`，并尝试返回错误响应。 |
| `maxJsonDepth` | 32 | 消息 JSON 嵌套深度上限。 |

错误码：`parseError(-32700)`、`invalidRequest(-32600)`、`methodNotFound(-32601)`、`invalidParams(-32602)`、`internalError(-32603)`、`permissionDenied(-32001)`、`messageTooLarge(-32002)`、`rateLimited(-32003)`、`timeout(-32004)`、`sandboxUnavailable(-32005)`。

### 5.5 会话生命周期与审计

- 状态：`created` → `running` → `stopped`；`PluginSandbox.open` 创建会话并自动 `start()`；`start()` 发送 `host.ready` 通知（含 pluginId / bundleId / apiVersion），通道不可用时 fail-closed。
- `handleRaw(raw)`：未启动 / 已停止会话抛 `StateError`；解析失败返回 `parseError`；合法 JSON 但结构不合法返回 `invalidRequest`；插件→宿主的通知目前只接受 `host.log`，其它通知记审计且不返回响应；请求走白名单 → 限流 → 网关调用 → 成功/失败响应。
- `sendEvent(method, params)`：宿主动推送通知给插件（如 `message.onMessage`）。
- `stop()`：使会话失效、清空限流窗口并关闭通道；重复调用幂等，之后 `handleRaw` 被拒绝。
- 审计 `PluginSandboxAuditEntry` 只记录 `pluginId` / `method` / `at` / `allowed` / `errorCode`，**不记录 params**，避免正文经审计泄漏；证据回调异常不影响主流程。

## 6. 调用示例（纯 Dart 片段）

```dart
import 'dart:typed_data';

import 'package:jingyu_plugin_runtime/jingyu_plugin_runtime.dart';

Future<void> runPlugin(Uint8List packageBytes) async {
  // 1) 加载：字节 → 运行期描述（平台由外壳传入，这里以 windows 为例）。
  final loaded = loadPluginBundle(packageBytes, platform: 'windows');
  if (!loaded.ok) {
    for (final issue in loaded.issues) {
      // ignore: avoid_print
      print('${issue.code.name}: ${issue.message}');
    }
    return;
  }

  // 2) 管理器：安装（权限必须预先由用户确认）。
  final manager = PluginManager(
    store: InMemoryPluginManagerStore(),
    platform: 'windows',
  );
  await manager.restore();
  final installed = await manager.install(
    packageBytes,
    source: PluginInstallSource.imported,
    grantedPermissions: const {'host', 'chat.send', 'storage'},
    userApproved: true,
  );
  if (!installed.ok) {
    // ignore: avoid_print
    print('install failed: ${installed.issue?.code.name}');
    return;
  }

  // 3) 沙箱：策略由运行期描述生成，通道/网关由平台适配器注入。
  final loadedBundle = loaded.bundle!;
  final entry = loadedBundle.entries.first;
  final policy = PluginSandboxPolicy.forEntry(
    bundleId: loadedBundle.bundle.id,
    entry: entry,
  );
  final sandbox = PluginSandbox();
  final session = await sandbox.open(
    policy: policy,
    channel: platformChannel, // 实现 PluginSandboxChannel 的 WebView 通道
    gateway: hostGateway,     // 实现 PluginSandboxGateway 的宿主能力网关
  );

  // 插件侧发来的 JSON-RPC 请求交给会话处理；返回消息由 channel.send 发出。
  await session.handleRaw(
    '{"jsonrpc":"2.0","id":1,"method":"host.getInfo","params":{}}',
  );

  // 宿主向插件推送事件（如新消息）。
  await session.sendEvent('message.onMessage', const {'conversationId': 'c1'});

  await session.stop();
  await sandbox.closeAll();
}
```

`platformChannel` / `hostGateway` 是平台适配器实现（本切片不提供）。测试中用 fake 实现记录 `send` 的 JSON 并返回值。

## 7. 测试覆盖

| 测试文件 | 覆盖重点 |
|---|---|
| `jingyu_protocol/test/plugin_bridge_test.dart` | 严格 JSON-RPC 2.0 编解码与往返；顶层字段/`jsonrpc`/id/method 规则；大小与深度限制；方法目录、scope 与 slotKeys；错误码与 `Result` 失败不抛异常。 |
| `jingyu_client_kit/test/plugin_package_extractor_test.dart` | 合法包条目内容/路径/大小；zip-slip、重复条目、超大条目、伪造头、sha256 不符；空包；根 `plugin.json` 入 `files`；失败时 `files` 为空。 |
| `jingyu_plugin_runtime/test/plugin_loader_test.dart` | 合法多行 bundle（webview + dart + declarative）；全部 `PluginLoadIssueCode`；依赖满足/不满足；configSchema 好/坏；entry 缺失；platform / apiVersion 不匹配；重复 id。 |
| `jingyu_plugin_runtime/test/plugin_manager_test.dart` | 安装成功/重复/未审批/权限不足/依赖；多行 bundle；启停依赖；卸载依赖；更新版本/降级/换 id/新增权限；持久化恢复；store 失败回滚；配置序列化；严格快照解析。 |
| `jingyu_plugin_runtime/test/plugin_sandbox_test.dart` | 允许/拒绝、scope、未知方法、非法 slot、超长消息、畸形 JSON、限流、超时、停止、事件、审计不含参数；origin / CSP / 平台开关默认关闭。 |
| `jingyu_plugin_runtime/test/plugin_module_e2e_test.dart` | 加载 → 安装 → 沙箱调用 → 持久化恢复全链路；更新只接受更高版本并保留配置；安装失败不进入管理器状态。 |

2026-11-28 本工作树实测（Windows）：`jingyu_protocol` 60 项、`jingyu_client_kit` 309 项（含 `plugin_package_extractor_test` 16 项）、`jingyu_plugin_runtime` 127 项（含 `plugin_module_e2e_test` 3 项）测试通过；三包 `dart analyze --fatal-infos` 均无问题。

运行方式（各包目录内）：

```powershell
dart pub get
dart analyze --fatal-infos
dart test
```

本切片的测试是**纯 Dart 单元测试**：使用 fake channel / fake gateway / 内存存储，不证明真实 WebView、真实文件 IO、真实签名或双端平台行为。

## 8. 与 v3 方案阶段 1 的对应关系

| v3 §9 阶段 1 内容 | 本切片状态 |
|---|---|
| bundle / manifest 模型 | 已完成（ADR-0002 的 `PluginBundle` / `PluginBundleEntry` / `PluginDependency`），本切片复用。 |
| 包校验（zip 条目 / 体积 / 压缩比 / 路径 / schema） | 已有 `validatePluginPackage`（ADR-0001 / ADR-0005）；本切片新增 `extractPluginPackage` 安全有界解包。 |
| 桥 v3（事件 / slot 消息）与严格编解码 | 已完成 `plugin_bridge.dart`：JSON-RPC 2.0 消息模型、错误码、方法/scope/slot 目录。 |
| config schema | 加载期只校验 `configSchema` 为合法 JSON 对象且 `type` 为字符串；**不实现**自动表单与配置 UI。 |
| SDK 类型 / `@jingyu/plugin-sdk` | 未实现；当前只有 Dart 侧方法目录常量。 |
| 单测 | 见 §7。 |

阶段 1 之外、但**不依赖 M11 可先做**的纯逻辑，本切片也提前实现了管理器状态机（对应 v3 阶段 4/6 的前置）与沙箱策略/能力桥（对应 v3 阶段 3 的前置）。真实 Slot 渲染框架（阶段 2）、WebView 沙箱宿主（阶段 3）、管理器 UI/HMR（阶段 4）、私有市场（阶段 5）、动态生成（阶段 6）均未开始，必须等 M11 外壳与后续排期；因此本切片不等于完整 M11 验收，也不等于 v3 全部阶段完成。

## 9. 验证口径与残余缺口

- 验证命令：各包 `dart pub get && dart analyze --fatal-infos && dart test`；仓库级检查由 `tool/check.ps1` 统一执行（Lead 集成时复核）。
- 通过单元测试只能证明纯 Dart 逻辑与策略数据正确，不能证明：WebView 隔离在 Android/Windows 真机生效、安装 UI 可用、包来源可信、签名验证完成、插件生态完整。
- 后续接入 WebView 平台适配器时，必须把 §5.1 的平台约束逐项落实并补真机证据；在此之前，任何“插件已安全隔离”的对外表述都不成立。
