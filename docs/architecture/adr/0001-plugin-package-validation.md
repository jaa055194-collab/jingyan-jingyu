# ADR 0001 · 插件包（zip）安全校验

- 状态：已采纳（本轮首次 OSS 选型试点）
- 日期：2026-11-15
- 范围：`packages/jingyu_client_kit/lib/src/plugin_package.dart`（纯 Dart、无 IO）
- 关联：开源选型调研 P0「`archive` 插件包校验」；插件方案 v3 §7 安全、§8 包校验；`docs/plugins/01-plugin-spec.md` §7；`docs/architecture/01-layering.md` 依赖方向

## 1. 背景 / 问题

当前插件（见 `packages/jingyu_client_kit/lib/src/plugin.dart`）只是**编译期代码契约**：一份 `PluginManifest`（`pluginApiVersion = 1`）加一个 `ClientPlugin` 实现，经 `PluginHost.load` 校验后加载。清单校验在 `PluginManifest.fromJson`（严格、失败抛 `FormatException`）与 `PluginHost.load`（`apiVersion` / 平台 / `hostOnly` / id 重复）里完成。

v3 插件方案把插件改为以 **bundle（zip 包）** 分发与安装：一个 zip 里含 `plugin.json`、`lib/`、`assets/` 等。安装前必须先对这个压缩包本身做**安全与完整性校验**，否则会面对：

- **Zip Slip**：条目路径含 `..`、绝对路径、盘符，解压时写到目标目录之外。
- **Zip Bomb / 解压炸弹**：声明尺寸与实际不符、极小压缩比极高，解压耗尽内存。
- **条目异常**：条目数、单条体积、总体积、压缩比超限；重复条目（大小写不敏感）互相覆盖；符号链接条目把写入引到别处。
- **清单异常**：缺少根 `plugin.json`、清单过大、JSON 嵌套过深、非法 JSON、字段非法。
- **完整性**：包内容被篡改时无感知。

约束：**不能破坏既有接口**。现有 `PluginManifest`、`pluginApiVersion = 1`、`PluginHost.load` 的语义保持不变；本校验是安装前的**新增前置步骤**，不与清单加载耦合。

## 2. 决策

采纳两个纯 Dart 的 OSS 包，新增一个纯函数入口 `validatePluginPackage`：

- 用 **`archive`**（MIT，<https://github.com/brendan-duncan/archive>）做 zip 解码与条目读取；
- 用 **`crypto`**（BSD-3-Clause，<https://github.com/dart-lang/crypto>）对整包字节算 sha256，供完整性比对。

`validatePluginPackage` 的契约（与 `docs/plugins/01-plugin-spec.md` §7 一致）：

- 输入 `Uint8List bytes`，可选 `PluginPackageLimits limits`（默认值见下表）与 `String? expectedSha256Hex`。

| `PluginPackageLimits` 字段 | 默认值 |
|---|---|
| `maxEntries` | 512 |
| `maxTotalUncompressedBytes` | 64 MiB |
| `maxEntryUncompressedBytes` | 16 MiB |
| `maxCompressionRatio` | 100 |
| `maxManifestBytes` | 256 KiB |
| `maxJsonDepth` | 32 |

- **纯函数**：不读文件系统、不做网络、不抛给调用方以外的副作用；只对内存字节做校验。
- 返回 `PluginPackageValidation { ok, manifest?, sha256Hex, issues }`；`issues` 逐条给出 `PluginPackageIssue { code, message, path? }`。
- 非法/可疑情况只记 `PluginPackageIssue`（`ok = false`），不抛出未受控异常；清单解析失败也转为 `manifestInvalid` 类问题。
- **不**在此处判定 `apiVersion` 兼容性 / 平台适用性 / `hostOnly`：这些是加载期语义，仍留给 `PluginHost.load`（关注点分离）。清单字段的「结构」仍由 `PluginManifest.fromJson` 严格保证（`apiVersion` 必为整数、`platforms` ⊆ {android,windows}、能力合法等）。

这样：安装路径拿到 `ok == true` 且 `manifest` 后，再交给既有 `PluginHost.load` 完成加载期校验，既有接口零改动。

## 3. 备选方案与取舍

| 方案 | 取舍 |
|---|---|
| **A. 手写 DEFLATE 解析** | 不引依赖、完全可控，但要自己实现 inflate、CRC、zip 目录解析与边界，代码量与出错面远大于收益；维护成本高、易埋内存/越界漏洞。放弃。 |
| **B. 换其它 zip 库** | 生态里能同时满足「纯 Dart、无 `dart:io`、可在单测中跑」的候选很少；`archive` 是当前最主流、活跃维护的纯 Dart 实现，接口能覆盖只读条目与解压流控制。选它。 |
| **C. 服务端校验 vs 客户端纯 Dart 校验** | 服务端校验依赖联网与后端，客户端在离线/首次安装时也得能判；且本校验要在 `jingyu_client_kit`（可脱离 Flutter/IO 做单测）内完成。选**客户端纯 Dart**；服务端未来可另做二次校验，二者不冲突。 |
| **D. 强制签名 vs 仅 sha256 完整性** | v3 已将签名定为**可选**，首版只做「sha256 完整性」：能发现内容与预期哈希不一致，但**不等于**来源可信（无签名就无法证明发布者身份）。签名验证留待后续，不在本轮引入。 |

补充：`archive` 只用于解码与条目枚举；本函数把「解压多少」牢牢卡在限额内，避免把整包无界展开。

## 4. 许可证

| 包 | 版本 | 许可证 | 上游 |
|---|---|---|---|
| `archive` | 3.6.1 | MIT | <https://github.com/brendan-duncan/archive> |
| `crypto` | 3.0.x | BSD-3-Clause | <https://github.com/dart-lang/crypto> |

两者均在项目 OSS 白名单内（MIT / BSD-3-Clause 均为宽松许可、允许商用与再分发，需保留版权与许可声明）。登记见仓库根 `THIRD_PARTY_NOTICES.md`。本 ADR 只做选型结论，许可证全文以上游仓库与 pub 缓存为准。

## 5. 降级 / 可关闭

校验是**纯函数**，与聊天主链路无耦合：

- 若 `archive` / `crypto` 在目标环境不可用，或校验逻辑本身出问题，可在**发布前**关闭「包安装」路径，回退到 **「仅内网可信来源 + 人工确认」** 的安装方式，而**不阻断聊天主链路**。
- 关闭安装路径不影响已加载插件的运行；`validatePluginPackage` 不被调用即等同关闭。
- 该降级只降低「自动安装」的便利与安全门槛，不改变聊天、消息等主功能可用性。

## 6. 影响面 / 依赖方向

- 只落在 `jingyu_client_kit`：依赖 `jingyu_core` + `jingyu_protocol`，**不引入 Flutter、不 import `dart:io`**，保持可在纯单元测试中调用（符合 `docs/architecture/01-layering.md` §2 依赖方向）。
- 新增 `archive`、`crypto` 两个纯 Dart 包依赖；二者不拉入原生/IO 能力。
- 不改动 `plugin.dart` 的 `PluginManifest` / `pluginApiVersion`，不改动 `plugin_host.dart` 的 `PluginHost.load`；只是在其之前增加一个可选的前置校验步骤。
- 尚未接入 M11 安装 UI；本轮只交付契约与校验能力。
- 说明：`plugin_package.dart` 的实现、其测试以及 `pubspec.yaml` 中 `archive` / `crypto` 的依赖声明由本轮代码变更（Lead 负责）落地；本 ADR 只记录选型决策与契约依据，不重复代码内容。撰写本 ADR 时如上述代码/依赖尚未合入，属正常的分工进行态。

## 7. 残余风险

- **声明与实际不符的恶意包**：即便按声明尺寸限制，`archive` 解压出的实际数据若与控制字段不符，仍可能分配较多内存；限额（见下）能压低但不能完全消除，需在调用方再配合内存/超时兜底。
- **沙箱 / WebView 0day**：插件素材可能经 WebView 承载（如房间页），WebView 自身 0day 不在本校验防护范围。
- **完整性 ≠ 可信**：仅 sha256 只能发现内容与预期哈希不一致，无法证明发布者身份（未做签名）。
- 以上均**写入安全策略**，作为已知边界，不宣称本校验能覆盖全部供应链攻击。

## 8. 验收

契约测试覆盖以下场景（每类都要有正/反例）：

- **zip-slip**：绝对路径、盘符、含 `..` 的条目路径被拒（`unsafeEntryPath`）。
- **zip-bomb**：条目数超 `maxEntries`、单条超 `maxEntryUncompressedBytes`、总量超 `maxTotalUncompressedBytes`、压缩比超 `maxCompressionRatio` 分别报 `tooManyEntries` / `entryTooLarge` / `totalTooLarge` / `compressionRatioTooHigh`。
- **entry**：空包（`empty`）、非 zip（`notZip`）。
- **duplicate**：大小写不敏感的重复条目（`duplicateEntry`）。
- **symlink**：符号链接条目被拒（`symbolicLink`）。
- **manifest**：缺根 `plugin.json`（`missingManifest`）、清单超 `maxManifestBytes`（`manifestTooLarge`）、JSON 嵌套超 `maxJsonDepth`（`manifestTooDeep`）、非法 JSON（`manifestInvalidJson`）、字段非法（`manifestInvalid`）。
- **sha256**：给定 `expectedSha256Hex` 不符时 `integrityMismatch`；一致时通过。
- **non-zip**：随机字节被识别为非 zip（`notZip`）。

全部通过后，本 ADR 视为达成；实现与测试代码由 Lead 在同一分支负责，本文件只记录契约与依据。
