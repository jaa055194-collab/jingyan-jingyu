# ADR 0004 · M11 外壳第一阶段：客户端会话编排（纯 Dart）

- 状态：已采纳（M11 客户端外壳第一阶段）
- 日期：2026-11-15
- 范围：`packages/jingyu_client_kit/lib/src/client_session.dart`（纯 Dart、无 IO）
- 关联：`docs/modules/M11-client-shell.md` 规则 1（业务逻辑放 client_kit）、规则 2（Outbox/SyncCursor）、规则 3（PluginHost 接线）；FR-14/AC-18

## 1. 背景 / 问题

M11 是 Android + Windows 的 Flutter 外壳。按 M11 规则 1，业务逻辑必须放 `jingyu_client_kit`（纯 Dart、可单测），外壳只做 UI 绑定。当前 `client_kit` 已有独立积木：`Outbox`（离线发件箱）、`SyncCursor`（差集游标）、`LocalMessageCache`（本地缓存），但缺少把它们**按账号编排**的统一入口。外壳若各自拼装，容易出现“收消息游标与缓存不同步、发件箱状态散落、重启后重放被当新消息”等一致性缺陷。

## 2. 决策

新增纯 Dart 的 `ClientSession`（每账号一个），作为 M11 会话编排层：

- `ingest(Iterable<CachedMessage>) -> SyncIngestResult`：按会话分组、用 `SyncCursor` 逐条 `accept`；`applied` 写 `LocalMessageCache`；`duplicate` 忽略；`gap` 记录 `SyncGap(conversationId, afterSeq)` 并停止该会话本批后续条目（不写入乱序消息）。不同会话互不影响。
- 游标惰性初始化：首次用到某会话时以 `cache.headSeq` 作 `lastSeq`，重启后重放即判为 `duplicate`，不会重复写入/复活。
- `sendText(conversationId, text) -> clientMsgId`：经 `Outbox.enqueue`（`MessageKind.text`）。
- `flush(Submit, {onDropped}) -> FlushReport`：委托 `Outbox.flush`（瞬时失败保留队首、永久失败丢弃回调）。
- `messages(...)`、`headSeq(...)`：读本地缓存。
- `applyRecall(...)`、`clearAccount()`：撤回占位与账号清理。

外壳（Flutter）持有一个 `ClientSession` 并负责：网络收发（帧用 `jingyu_protocol`）、把收到的授权后数据解成 `CachedMessage` 交给 `ingest`、据 `gaps` 发 `SyncRequestFrame` 拉差集、把 `outbox.items`/`cache` 快照加密落盘（持久化不在本层）。`PluginHost` 仍独立创建，与本编排层平行组合。

## 3. 备选方案与取舍

| 方案 | 取舍 |
|---|---|
| **A. 在外壳里拼装三块积木** | UI 层混业务、难单测、易漂移；违反 M11 规则 1。放弃。 |
| **B. 让 `Outbox`/`Cache` 互相知道彼此** | 制造耦合与循环依赖；不利于各自单测。放弃。 |
| **C. 新增 `ClientSession` 编排层（采纳）** | 依赖单向（Session → 三块），纯 Dart 可测；外壳只绑定。 |

## 4. 影响面 / 依赖方向

- 只落在 `jingyu_client_kit`：依赖 `jingyu_core` + `jingyu_protocol` + 既有 `outbox/sync_cursor/local_message_cache`；**不引入 Flutter、不 import `dart:io`**。
- 不改动既有类与公开接口；仅新增文件与导出。
- 尚未实现 Flutter UI、平台适配器（托盘/AUMID/前台服务/分享）、onboarding 等——见第 6 节。

## 5. 残余风险

- **授权不在本层**：`ingest` 假定传入的是服务端已授权、已按可见性过滤的数据；客户端不做权限判定（与 `LocalMessageCache` 一致）。
- **持久化由外壳负责**：本层仅内存结构；落盘加密、断电一致性由 Flutter 外壳实现（后续阶段）。
- **ingest 缺口策略**：出现缺口即停该会话本批后续条目，需外壳拉差集后重放；若外壳不处理 `gaps`，该会话不会前进（这是有意的 fail-safe，不是静默丢消息）。

## 6. 后续（M11 其余阶段，另行推进）

Flutter 外壳 `apps/client_flutter`（路由/主题/页面）、平台适配器（Windows 托盘/自启/快捷键/AUMID 通知/悬浮宠物；Android 前台服务/分享面板/来电）、onboarding、应用锁等为后续阶段。仓库已有一个未完成的 M11 草稿 PR #8（Flutter 壳 + 原生适配器，基于较早分支），将在 UI 阶段与其对齐/收敛；本 ADR 交付的是其可复用的纯 Dart 编排内核。

## 7. 验收

契约测试覆盖：按序 ingest 写入缓存并前进游标；重复下发忽略；缺口报告 `afterSeq`、不写入乱序、补齐后按序应用；一个会话缺口不影响其它会话；重启（复用缓存）后重放判重复；`sendText` 入队并可 `flush` 提交、瞬时失败保留队首；`applyRecall` 置撤回；`clearAccount` 清空。全部通过后本阶段达成（非完整 M11 验收）。
