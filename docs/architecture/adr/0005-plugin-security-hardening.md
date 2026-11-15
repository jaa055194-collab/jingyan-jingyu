# ADR 0005 · 插件包/插件 bundle 安全加固（复审修复）

- 状态：已采纳（安全复审修复）
- 日期：2026-11-15
- 范围：`packages/jingyu_client_kit/lib/src/{plugin_package.dart,plugin_bundle.dart,plugin.dart}`（纯 Dart、无 IO）
- 关联：ADR-0001（包校验）、ADR-0002（bundle 模型）；修复对象为已合并的 #34/#36 代码

## 1. 背景 / 问题（复审发现）

对已合并的插件校验/bundle 代码做安全复审，发现：

1. **【关键】符号链接在解码阶段即被解压**：`archive` 的 `ZipDecoder` 解码时会立即 `utf8.decode(file.content)` 读取符号链接目标，**早于任何限额检查**；恶意小包可用符号链接条目触发大体量解压打爆内存。
2. **【重要】体积限额依赖可伪造的头字段**：中央目录声明的未压缩尺寸可被伪造；仅靠声明值做限额不足，且清单解压后未强制真实字节复核（本轮统一在解码前预扫 + 解码后复核）。
3. **【重要】非字符串 `license` 抛 `TypeError`**：`PluginManifest.fromJson` 中 `json['license'] as String?` 遇到非字符串会抛 `TypeError`，未被校验器捕获，向外泄漏未受控异常。
4. **bundle 清单路径未校验**：`PluginBundle` 的 `icon` / `locales` 值 / `plugins[].entry` / `configSchema` 接受 `..`、绝对路径、盘符（首个消费方落地前必须复用路径校验）。
5. Windows 尾点/尾空格与保留设备名（CON/PRN/AUX/NUL/COM1-9/LPT1-9）在条目路径/清单路径中未被拒绝；bundle 内插件 id 去重区分大小写。

## 2. 决策 / 修复

- **解码前中央目录预扫** `_preScanCentralDirectory`：只读解析 EOCD + 中央目录（不解压），在任何解码前：
  - 拒绝符号链接条目（`versionMadeBy>>8==3` 且 `externalAttrs>>16 & 0xF000 == 0xA000`）——从根本上避免解码期符号链接解压；
  - 用声明尺寸先做条目数 / 单条 / 总量限额，超限直接拒绝，不进入解码；
  - **严格镜像 `archive` 的 `ZipDirectory.read`**：按中央目录**尺寸窗口**（`cdOffset .. cdOffset+cdSize`）逐条解析，**不信任** EOCD 的 16-bit 条目计数（该字段可被伪造以让预扫只读良性前缀）；结构异常、走到条目数与 EOCD 不符、或未恰好走完窗口时一律 fail-closed；
  - zip64 触发字段与解码器完全一致：任一盘号/条目计数为 `0xFFFF` 或 CD 大小/偏移为 `0xFFFFFFFF` 都拒绝（fail-closed，防止被引导到攻击者控制的 zip64 CD）。
- **清单真实字节复核**：`plugin.json` 解压后再按真实长度复核 `maxManifestBytes`（保留既有纵深防御），并把清单解析的 `on FormatException` 扩展为 `on Object`，任何非受控异常（如 `TypeError`）都转成 `manifestInvalid`。
- **`license` 类型校验**：`PluginManifest.fromJson` 校验 `license` 必须为字符串或 null，否则抛 `FormatException`。
- **bundle 路径校验**：`icon` / `locales` 值 / `plugins[].entry` / `configSchema` 一律经 `sanitizePackageEntryPath` 校验（拒绝绝对/盘符/`..`/Windows 尾点与保留名）；插件 id 去重改为不区分大小写。
- **路径函数加固**：`sanitizePackageEntryPath` 增加 Windows 尾点/尾空格 + 保留设备名拒绝。

## 3. 兼容性与影响面

- 均为**校验/解析层的收紧**（fail-closed），不改变合法输入的结果；不改公开类型签名（仅 `PluginManifest.fromJson`/`PluginBundle.fromJson` 对非法输入更严格）。
- 纯 Dart、无新增依赖；仍不引 Flutter/dart:io。

## 4. 残余风险（如实记录）

- **非清单条目不做实际解压**（仅清单解压），故其“真实解压体积”仍只在安装/解包消费方按声明值受限；声明可伪造时，消费方仍需以流式/配额兜底（本层不承担解包）。
- **清单解压仍可能先分配再复核**：`plugin.json` 的真实长度复核发生在 `content` 完全 inflate 之后；声明可伪造时，单个大清单在复核前仍会解压（受 `maxManifestBytes` 声明值约束但不构成硬上限）。真正上限需流式 inflate + 输出封顶（archive 当前接口不支持），列为残余风险。
- **zip64 暂不支持**（直接拒绝）；如需支持需扩展预扫。
- **压缩比**仍以声明总量 / 包字节估计；声明可伪造时仅作启发式。

## 5. 验收

新增/覆盖测试：符号链接在解码前预扫拒绝；非字符串 `license` 返回 `manifestInvalid` 而非抛异常；Windows 尾点/保留设备名路径被拒；bundle 的 `icon`/`locales`/`entry`/`configSchema` 不安全路径被拒；bundle 插件 id 大小写不敏感去重。原有 zip-slip/zip-bomb/重复/体积/清单/sha256 测试全部继续通过。
