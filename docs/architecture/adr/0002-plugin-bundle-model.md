# ADR 0002 · 插件 bundle 描述模型与依赖版本约束

- 状态：已采纳（开源选型第二批试点）
- 日期：2026-11-15
- 范围：`packages/jingyu_client_kit/lib/src/plugin_bundle.dart`（纯 Dart、无 IO）
- 关联：插件方案 v3 §4（bundle / preset / 安装校验）、§8（`client_kit` 契约）；开源选型调研 §3.3（插件：`pub_semver` 语义化版本，A 档直接依赖）；依赖方向见 `docs/architecture/01-layering.md`

## 1. 背景 / 问题

v3 方案把可分发的插件单位定为 **bundle（zip 包）**：一个 `plugin.json` 可描述多行插件（`plugins[]`），每行声明 `runtime`（webview / dart / declarative）、`entry`、`slots`、`permissions`、`configSchema`、`network`，并可声明 `dependencies`、`platforms`、`integrity.sha256`、`locales` 等。当前仓库只有**单插件**清单 `PluginManifest`（`plugin.dart`：`id/name/version/apiVersion/capabilities/platforms/hostOnly/license/assetCredits`），缺少 bundle 形态的类型化模型，也缺少依赖版本约束的判定能力。

若手写版本/版本区间比较，容易在 `^1.2.0`、`>=1.2.0 <2.0.0`、预发布标签等边界上与 pub 语义不一致，进而造成“依赖看似满足、实际不兼容”的误判。

## 2. 决策

新增纯 Dart 的 bundle 模型 `PluginBundle`，并用 OSS **`pub_semver`**（BSD-3-Clause，<https://github.com/dart-lang/tools/tree/main/pkgs/pub_semver>）解析版本与依赖版本区间：

- `PluginBundle.fromJson(Map) -> PluginBundle`：严格解析，失败抛 `FormatException`，不做宽松兜底。
  - 顶层：`id`（反向域名）、`name`、`version`（`pub_semver.Version`）、`apiVersion`（int）、`type`（`bundle`/`plugin`，默认 `bundle`）、`icon`、`locales`、`plugins`（非空）、`dependencies`、`platforms`（⊆ {android,windows}）、`integrity.sha256`（可选，64 位小写十六进制）。
  - `PluginBundleEntry`：`runtime`（三档枚举）、可选 `id`（bundle 内唯一）、`entry`（webview/dart 必填）、`slots`、`permissions`、`configSchema`、`network`（`deny` 默认 / `host-gateway`）。
  - `PluginDependency`：`id` + `pub_semver.VersionConstraint`；支持 `"id@range"` 字符串或 `{id, version|constraint}` 对象。
- `PluginBundle.isApiCompatible(int hostApiVersion)`：与 `PluginHost.load` 一致，判定 `apiVersion` 相等。
- `PluginBundle.unmetDependencies(Map<String,String> installedVersions) -> List<UnmetDependency>`：逐条给出“未安装 / 已安装版本号非法 / 版本不满足区间”。

**不改动** `PluginManifest` / `pluginApiVersion = 1` / `PluginHost.load`；bundle 模型是并存的**分发层**模型，`PluginManifest` 仍是加载期的单插件契约。二者职责分离：bundle 负责“包里有什么、依赖谁、是否 API 兼容”，加载期负责“能否在本机加载”。

## 3. 备选方案与取舍

| 方案 | 取舍 |
|---|---|
| **A. 手写版本/区间比较** | 不引依赖，但需自行实现 `^`/`~`/范围/预发布比较，边界易错，且与 pub 生态语义可能不一致。放弃。 |
| **B. 仅用正则校验版本字符串** | 只能验证格式，无法判断依赖区间是否被满足（如安装的 `1.9.0` 是否满足 `^1.2.0`）。放弃。 |
| **C. 直接用 `pub_semver`（采纳）** | `pub_semver` 就是 pub 自身的版本语义实现，`Version` / `VersionConstraint.parse` / `allows` 覆盖全部边界；纯 Dart、无 IO，可直接在 `client_kit` 单测中运行。 |

## 4. 许可证

| 包 | 版本 | 许可证 | 上游 |
|---|---|---|---|
| `pub_semver` | 2.2.1 | BSD-3-Clause | <https://github.com/dart-lang/tools/tree/main/pkgs/pub_semver> |
| `collection`（`pub_semver` 的传递依赖） | 1.19.x | BSD-3-Clause | <https://github.com/dart-lang/collection> |

均在项目 OSS 白名单内（宽松许可，允许商用与再分发，需保留版权与许可声明）。

> 说明：仓库根 `THIRD_PARTY_NOTICES.md` 由并行 PR #34（首个试点，引入 `archive`/`crypto`）新建。本 PR 为避免与 #34 对同一新文件的 add/add 冲突，不在此分支新建该文件；`pub_semver` 的许可证登记在上述许可证表与本 ADR 中记录，待 #34 合入后将本项补登到统一的 `THIRD_PARTY_NOTICES.md`。

## 5. 影响面 / 依赖方向

- 只落在 `jingyu_client_kit`：依赖 `jingyu_core` + `jingyu_protocol`，**不引入 Flutter、不 import `dart:io`**，可在纯单元测试中调用（符合 `docs/architecture/01-layering.md` §2 依赖方向）。
- 新增 `pub_semver`（纯 Dart）直接依赖；`collection` 为其传递依赖。
- 不改任何既有公开接口；仅新增文件 `plugin_bundle.dart` 与导出。
- 尚未接入客户端安装 UI / bundle 打包工具；本轮只交付类型模型与版本/依赖判定能力。

## 6. 残余风险

- **依赖版本只是客户端的静态判定**：真实可用性还取决于运行时是否安装、权限与平台；本模型只做声明级校验，不代运行期加载。
- **预发布/构建元数据**：`pub_semver` 完整遵循 pub 语义；如后续允许 `-beta` 等预发布依赖，需要产品口径确认。
- **preset（启用组合）尚未建模**：v3 §4 的 preset 组合分发留待后续；本 ADR 只覆盖 bundle 描述与依赖。

## 7. 验收

契约测试覆盖：合法 bundle（多行插件/locales/integrity/依赖）、`type=plugin`、declarative 免 entry、字符串与对象两种依赖写法；拒绝非法 id/版本/apiVersion/type/空 plugins/未知 runtime/webview 缺 entry/重复插件 id/非法 platforms/非法 integrity.sha256/非法依赖区间；依赖满足性（满足、未安装、版本不满足、版本非法的检出）；`isApiCompatible` 判定。全部通过后本 ADR 达成。
