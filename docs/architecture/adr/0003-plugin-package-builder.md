# ADR 0003 · 插件包（bundle zip）构建

- 状态：已采纳（插件工具链第三批）
- 日期：2026-11-15
- 范围：`packages/jingyu_client_kit/lib/src/plugin_package_builder.dart`（纯 Dart、无 IO）
- 关联：插件方案 v3 §4（bundle 打包）、§8（`tool/pack-plugin` = bundle 打包 + sha256）；ADR-0001（包校验）

## 1. 背景 / 问题

ADR-0001 已提供安装前的**校验** `validatePluginPackage`，但缺少**构建**侧：把一份清单与静态资源组装成可分发、可通过校验、且带整包 sha256 的 zip。没有构建侧，“校验”无法闭环，也无法在 CI/工具里自动产出可安装包并展示完整性摘要。

## 2. 决策

在 `jingyu_client_kit` 新增纯函数 `buildPluginPackage`，作为 `validatePluginPackage` 的逆操作：

- 输入：`manifest`（任意 JSON 可序列化对象）、`files`（相对路径 -> 字节）、可选 `modifiedSecondsSinceEpoch`。
- 行为：
  1. `jsonEncode(manifest)` 写入根 `plugin.json`；不可序列化则抛 `PluginPackageBuildException`。
  2. 每个附加条目路径经 `sanitizePackageEntryPath` 规范化并校验；不安全（绝对/盘符/`..`）、重复（大小写不敏感）、或显式提供 `plugin.json` 一律拒绝。
  3. 条目按规范化路径**排序**，并以**固定 UTC 修改时间**（默认 1980-01-01T00:00:00Z）传入 `ZipEncoder` 的 `modified`（`isUtc: true`），保证**同输入产出相同字节**（跨机器/时区可复现）。
  4. `ZipEncoder` 编码后，用 `crypto` 计算整包 sha256。
- 返回 `BuiltPluginPackage { bytes, sha256Hex }`。

复用既有依赖 `archive`（MIT）+ `crypto`（BSD-3-Clause），**不新增依赖**。

## 3. 备选方案与取舍

| 方案 | 取舍 |
|---|---|
| **A. 只做 CLI，不做纯库** | CLI 需读写文件系统、难以在纯单测中覆盖；先在纯库实现，CLI 可后续薄封装。 |
| **B. 不固定时间戳（复现性弱）** | zip 头含条目时间，不固定会导致同输入每次字节不同、sha256 变化，破坏“可复现构建/比对”。因此固定时间戳。 |
| **C. 允许业务传入 `plugin.json`** | 会与“由 manifest 生成”冲突并可能造成清单与内容不一致；显式拒绝，强制单一来源。 |

## 4. 许可证

沿用 `archive`（MIT）与 `crypto`（BSD-3-Clause），已登记于仓库根 `THIRD_PARTY_NOTICES.md`。本批**不新增**第三方依赖。

## 5. 影响面 / 依赖方向

- 只落在 `jingyu_client_kit`：依赖 `jingyu_core` + `jingyu_protocol` + `archive` + `crypto`；**不引入 Flutter、不 import `dart:io`**（纯函数，不读写文件）。
- 不改动 `PluginManifest` / `pluginApiVersion` / `PluginHost.load` / `validatePluginPackage`；仅新增文件与导出。
- 尚未接入 `tool/pack-plugin` CLI 与安装 UI；本轮交付可复现的构建纯库。

## 6. 残余风险

- **确定性依赖 `archive` 的编码行为**：固定 UTC 时间戳 + 排序下稳定（已通过 `modified: … isUtc: true` 避免本地时区影响，跨时区可复现）；若未来升级 `archive` 改变编码细节，需重跑确定性测试。
- **构建不做安全性背书**：构建只保证结构与路径安全、可经校验；清单/资源是否可信仍由发布方与审批负责（见 ADR-0001 / v3 §7）。
- **大小/条目限制在构建侧不强制**：构建产物若超出安装校验限额，会在 `validatePluginPackage` 处被拒；构建侧不重复该策略（关注点分离）。

## 7. 验收

契约测试覆盖：构建结果经 `validatePluginPackage` 判定 `ok`（打包↔校验往返、manifest 解析一致、sha256 一致）；同输入字节与 sha256 稳定（可复现）；sha256 与独立 `crypto` 计算一致；不安全路径（`../`、绝对、盘符）被拒；重复条目（大小写不敏感）被拒；显式 `plugin.json` 被拒；清单不可序列化被拒。全部通过后本 ADR 达成。
