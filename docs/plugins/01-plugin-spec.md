# 插件规范 v1

> 代码：`packages/jingyu_client_kit/lib/src/plugin.dart`、`plugin_host.dart`；测试：`test/client_kit_test.dart`。
> 宿主侧扩展不走插件，走 `HostModule`（见 `docs/architecture/01-layering.md` §5）。

## 1. 插件由什么组成

```text
plugins/<plugin-id>/
  plugin.json        清单（必需）
  lib/plugin.dart    导出一个 ClientPlugin 实现
  assets/            随插件分发的素材（可选，需署名，见 02-assets.md）
  test/              插件自测（必需）
  README.md          做什么、需要什么能力、怎么验收
```

## 2. plugin.json

```json
{
  "id": "jingyu.room.generator",
  "name": "房间生成",
  "version": "0.1.0",
  "apiVersion": 1,
  "capabilities": ["roomScene", "modelInvoke"],
  "platforms": ["android", "windows"],
  "hostOnly": false,
  "license": "MIT",
  "assetCredits": []
}
```

| 字段 | 规则 |
|---|---|
| `id` | 小写反向域名，至少两段，例如 `jingyu.slash.draw`。全局唯一。 |
| `version` | 语义化版本 `x.y.z`。 |
| `apiVersion` | 必须等于宿主 `pluginApiVersion`（当前 1），否则拒绝加载。 |
| `capabilities` | 只能从下表选。**没声明的能力运行时一律拿不到**。 |
| `platforms` | 只允许 `android`、`windows`。 |
| `hostOnly` | `true` 表示只在宿主机客户端加载。Live2D 模型导入不得以此限制：用户只操作自己的设备，模型文件必须留在本机。 |
| `assetCredits` | 每条第三方素材一行署名，CC 素材必填。 |

解析失败直接拒绝，不做宽松兜底。

## 3. 能力与扩展点

| 能力 | 解锁的登记方法 / 上下文方法 | 说明 |
|---|---|---|
| `slashCommands` | `addSlashCommand` | FR-60。`requiresAiCapability` 未绑定时自动隐藏。 |
| `messageRenderer` | `addMessageCard(cardType, renderer)` | 按消息 body 的 `cardType` 渲染。 |
| `settingsPage` | `addSettingsSection(title, builder)` | 设置页分区。 |
| `roomScene` | `addRoomGenerator` | 3D 房间生成与家具（FR-35，需求方第 13 条）。 |
| `sendMessage` | `context.sendText` | 以当前用户身份发送，仍走发件箱与幂等。 |
| `readConversation` | （M11 接入） | 只读，受服务端可见性约束。 |
| `modelInvoke` | （M05/M11 接入） | 调宿主模型能力，计入该 AI 预算（FR-48/58）。 |
| `localStorage` | `context.storage` | 按插件 id 隔离的键值存储。 |

## 4. 生命周期与隔离

1. 宿主读 `plugin.json` → 校验 API 版本、平台、`hostOnly`、id 是否重复。
2. 调 `activate(registrar)`。插件在这里登记贡献，不得做阻塞 IO。
3. 登记未声明的能力 → 抛错 → **本次已登记的贡献全部回滚**，插件不加载，错误进 `PluginHost.errors`。
4. 斜杠指令或消息卡片与已有的冲突 → 后加载者失败。
5. 一个插件失败不影响其他插件。
6. 退出时逆序 `deactivate()`，需幂等。

## 5. 插件不能做的事

- 不能直接访问网络。要出站，走宿主接口（宿主会过 `UrlGuard`，NFR-05）。
- 不能拿到 token、API key、其他插件的存储。
- 不能在闪照、私密动态、群消息上调用外部模型（需求方续表第 2 条）。
- 不能下载或执行代码。房间生成器只产出布局数据（`RoomLayout`）。

## 6. 写一个插件的最小例子

```dart
class DrawPlugin extends ClientPlugin {
  @override
  final manifest = const PluginManifest(
    id: 'jingyu.slash.draw',
    name: '画图指令',
    version: '0.1.0',
    apiVersion: pluginApiVersion,
    capabilities: {PluginCapability.slashCommands, PluginCapability.sendMessage},
  );

  @override
  Future<void> activate(PluginRegistrar r) async {
    r.addSlashCommand(SlashCommand(
      name: '画图',
      description: '让她画一张图',
      requiresAiCapability: 'image_gen',
      run: (args, ctx) async {
        await ctx.sendText('<当前会话>', '/画图 $args');
        return null;
      },
    ));
  }
}
```

验收：插件目录下 `dart test` 通过；在 `PluginHost` 上加载成功；去掉清单里任一能力后加载失败。

## 7. 插件包安全校验

> 代码：`packages/jingyu_client_kit/lib/src/plugin_package.dart`（纯 Dart、无 IO）。依据见 `docs/architecture/adr/0001-plugin-package-validation.md`。

v3 插件以 bundle（zip 包）分发。安装前先调用 `validatePluginPackage` 对**包字节**做安全与完整性校验；通过后再把 `manifest` 交给既有 `PluginHost.load`。本步骤不改变 `PluginManifest` / `pluginApiVersion = 1` / `PluginHost.load` 的既有语义。

### 7.1 限额 `PluginPackageLimits`

| 字段 | 默认值 | 含义 |
|---|---|---|
| `maxEntries` | 512 | 条目数上限 |
| `maxTotalUncompressedBytes` | 64 MiB | 全部条目解压后总字节上限 |
| `maxEntryUncompressedBytes` | 16 MiB | 单条目解压后字节上限 |
| `maxCompressionRatio` | 100 | 整包压缩比上限（全部解压后总量 / 包字节） |
| `maxManifestBytes` | 256 KiB | 根 `plugin.json` 字节上限 |
| `maxJsonDepth` | 32 | 清单 JSON 嵌套深度上限 |

### 7.2 问题码 `PluginPackageIssueCode`

`empty`、`notZip`、`tooManyEntries`、`entryTooLarge`、`totalTooLarge`、`compressionRatioTooHigh`、`unsafeEntryPath`、`duplicateEntry`、`symbolicLink`、`missingManifest`、`manifestTooLarge`、`manifestTooDeep`、`manifestInvalidJson`、`manifestInvalid`、`integrityMismatch`。

### 7.3 数据结构

```dart
class PluginPackageIssue {
  final PluginPackageIssueCode code;
  final String message;
  final String? path; // 相关条目路径，能定位时给出
}

class PluginPackageValidation {
  final bool ok;                       // 所有校验通过才为 true
  final PluginManifest? manifest;      // ok 时有值；解析失败为 null
  final String sha256Hex;              // 对包字节计算的 sha256（小写十六进制）
  final List<PluginPackageIssue> issues;
}
```

### 7.4 入口

```dart
PluginPackageValidation validatePluginPackage(
  Uint8List bytes, {
  PluginPackageLimits limits,
  String? expectedSha256Hex,
})
```

- **纯函数**：不读文件系统、不做网络与其它 IO；只校验传入的内存字节。
- 要求包内有**根目录的** `plugin.json` 清单。
- 计算整包字节的 sha256；若给了 `expectedSha256Hex` 则比对。
- 用 `PluginManifest.fromJson` 解析清单：**严格**，字段非法时抛 `FormatException`，本函数捕获并转为 `manifestInvalid`（不向外抛出）。
- 可疑/非法情况一律记 `issues` 并置 `ok=false`，不抛未受控异常。
- 清单字段的「结构」仍由 `PluginManifest.fromJson` 严格保证（如 `apiVersion` 必为整数、`platforms` 只允许 android/windows、能力必须合法）；此处**不**判定 `apiVersion` 兼容性 / 平台适用性 / `hostOnly` 等运行期语义，这些仍由 `PluginHost.load` 决定（关注点分离）。

### 7.5 每一项校验与规则

| 检查 | 规则 | 触发码 |
|---|---|---|
| 非空 | 包字节不能为空 | `empty` |
| zip 格式 | 必须能识别为 zip 结构 | `notZip` |
| 条目数 | 条目数 ≤ `maxEntries` | `tooManyEntries` |
| 单条体积 | 每条解压后 ≤ `maxEntryUncompressedBytes` | `entryTooLarge` |
| 总体积 | 全部解压后合计 ≤ `maxTotalUncompressedBytes` | `totalTooLarge` |
| 压缩比 | 整包（全部解压后总量 / 包字节）≤ `maxCompressionRatio`，超过视为疑似 zip 炸弹 | `compressionRatioTooHigh` |
| 路径安全（Zip Slip） | 拒绝绝对路径、盘符、含 `..` 的条目路径 | `unsafeEntryPath` |
| 重复条目 | 拒绝大小写不敏感的重名条目 | `duplicateEntry` |
| 符号链接 | 拒绝符号链接条目 | `symbolicLink` |
| 清单存在 | 必须有根 `plugin.json` | `missingManifest` |
| 清单体积 | `plugin.json` ≤ `maxManifestBytes` | `manifestTooLarge` |
| 清单深度 | JSON 嵌套 ≤ `maxJsonDepth` | `manifestTooDeep` |
| 清单 JSON | 必须是合法 JSON | `manifestInvalidJson` |
| 清单字段 | `PluginManifest.fromJson` 严格解析通过 | `manifestInvalid` |
| 完整性 | 计算 sha256 与 `expectedSha256Hex` 一致（给了才校验） | `integrityMismatch` |

## 8. 插件运行时内核（加载 / 管理器 / 沙箱）

bundle 的安全解包、运行期加载、安装管理与 WebView/JS 沙箱策略已由纯 Dart 包 `jingyu_plugin_runtime` 承接，API、安全边界、残余风险与验证方式见 [03-plugin-runtime.md](03-plugin-runtime.md)。

本节的 `PluginManifest` / `pluginApiVersion = 1` / `PluginHost.load` 语义不变；bundle 的 `permissions` 是分发层字符串 scope，不并入旧 `PluginCapability` 枚举。安装 UI、WebView 平台适配器、私有市场、HMR、动态生成与真实签名仍不在本仓库实现范围。

