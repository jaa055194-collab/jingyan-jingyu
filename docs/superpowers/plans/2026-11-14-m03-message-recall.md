# M03 消息撤回（24h、留审计、无正文）实现计划

**Goal:** 为已有持久消息内核增加"撤回自己的消息（24 小时内）"能力：正文清除为撤回占位、审计留痕且不含正文，并通过认证 HTTP 暴露。

**Architecture:** 在 `MessageStore` 契约中增加 `recall`，由内存与 SQLite 两个实现分别通过同一契约测试；SQLite 用新迁移 205 增加 `recalled_at` 列，在同一事务内校验会话/发送者/24h/未撤回后，把正文重加密为 `{"recalled": true}` 并写入 `recalled_at`。`MessagesModule` 增加认证路由，成员策略与既有发送一致，成功后写 `AuditLog`（仅消息 id 与 conversationId，不含正文）。

**Spec:** `docs/modules/M03-messages.md` 规则 2 与 AC-19（撤回超过 24h 失败；撤回留审计且审计里无正文）；v4.2 FR-15、NFR-07。C-5 在途撤权一分钟仍适用。

## Global Constraints

- 只能撤回自己发送的消息；他人消息、非成员、未知消息一律失败且不改变存储。
- 24 小时窗口使用注入 `Clock`，不使用 `DateTime.now()`。
- 撤回后差集同步只返回 `{"recalled": true}` 占位，原正文不再可读；再次撤回失败。
- 审计不得包含正文/音频/密钥字段，只允许标量元数据。
- 不改变既有 append/since/ack 行为与路由。

## Review Focus

- 非发送者撤回（含群主/管理员）必须失败且正文不变；这是权限判定，不涉及"看"的 404 规则，动作拒绝用 403。
- 24h 边界：恰好 24h 允许、超过 1 秒拒绝；跨时长不因复用时区/UTC 误差漂移。
- 撤回后 `since` 分页、seq、幂等键不受影响；同一 clientMsgId 重放返回撤回占位而不是旧正文。
- 审计条目只有 targetId/conversationId 等标量，`AuditEntry` 对正文键抛错。
- 内存与 SQLite 行为一致（同一契约测试），SQLite 事务失败不得半写。

## Tasks

1. **契约 RED**：在 `message_store_contract.dart` 增加撤回契约用例（成功占位、非发送者失败、未知消息失败、重复撤回失败），先运行确认两实现 RED。
2. **实现存储**：迁移 205 + 两实现 `recall`，运行契约测试 GREEN。
3. **HTTP RED**：新增 `message_recall_test.dart`（真实 SQLite/AccountsDomain/FakeClock）：本人 24h 内 200 且同步占位+审计无正文+DB 密文非原正文；他人 403 且不变；非成员 404；匿名 401；未知消息 404；超过 24h（刷新 token 后）403 且不变。
4. **路由与审计**：`Routes.messageRecall`、`MessagesModule._recall`、可选注入 `Clock` 与现有 `AuditLog`；默认宿主装配传入 clock。
5. **验证与文档**：聚焦测试、`dart analyze --fatal-infos`、完整 `tool/check.ps1`；更新 `implementation-status.md`、`requirements-traceability.md`（AC-19 撤回子项，明确编辑/定时/闪照/搜索/附件仍未完成）。

## Self-Review

- 本切片只覆盖 AC-19 的"撤回 24h 失败 + 审计无正文"，不含编辑留痕、定时消息、闪照、搜索、附件，也不含客户端 UI 或批量撤回。
- 撤回不物理删除消息行，以保留 seq 单调与分页稳定；这符合"留审计"和 seq 语义，但与"删除"不同，需在文档写明。
- 已知限制：撤回写入与审计写入是两次数据库写入；审计插入失败时撤回已生效，接口不返回 500、也不回滚。独立 review 确认内存实现的"已撤回"判定必须按 messageId 记录（不能按正文内容判定），已修复并补一致性回归。
