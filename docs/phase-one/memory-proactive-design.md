# 一期 · 主动联系与聊天历史自动记忆 · 实现设计

本文件是本期两项硬门槛功能的实现契约。两条功能都沿用既有 B 授权模型：**默认关闭、按 AI 单独开启、可随时撤回**；主动联系仅限本人 AI 私聊并含静默窗。两项完成后需实测验证再打包，未完成项不得称完整版。

## 硬门槛

1. 聊天历史自动记忆：仅采集已授权私聊、默认关闭、单独开启、可查看/撤回/清空，不采集群聊与他人内容。
2. 模型主动联系：仅本人 AI 私聊、默认关闭、静默窗与频率上限、不重复发送。

## 复用的既有契约

- `OwnerAiDirectConsent` / `owner_ai_direct_sources`：已授权本人私聊的接受标记与 grant revision。
- `owner_ai_direct_grants` 的 revision/identity 变化通过触发器使各功能的目标 token 失效（参照 `owner_rule_greeting_migration.dart`、`owner_memory_notes_migration.dart`）。
- 预算：模型主动走 B3（`BudgetLayer.b3Proactive` + `ProviderCapability.chat`）；只读 B3 闸门复用 `UsageMeter.ruleGreetingDayInTx`。
- 静默窗与本地日：`SilentWindow`、`UserTimeZone`、`dayKey`（`jingyu_core`）。
- 无正文审计：`audit_log`，只记动作/ID/revision/时间。

---

## 功能 A · 聊天历史自动记忆

迁移号：**607**（复用已存在的 `memoryMigrations` 600 的 `encrypted_memory` / `memory_source_messages`，本次把 600 也注册进默认宿主）。

新文件（由 A 负责）：

- `apps/host/lib/src/ai/memory/owner_auto_memory_migration.dart`
- `apps/host/lib/src/ai/memory/owner_memory_authorization.dart`（生产版 `MemoryAuthorization`）
- `apps/host/lib/src/ai/memory/owner_auto_memory.dart`（服务）
- `apps/host/lib/src/ai/memory/owner_auto_memory_module.dart`（HTTP 模块）
- 测试 `apps/host/test/owner_auto_memory_test.dart`
- 客户端 `apps/client_flutter/lib/net/owner_auto_memory_api.dart`
- 客户端 `apps/client_flutter/lib/features/ai_config/owner_auto_memory_section.dart`
- 文档 `docs/phase-one/owner-auto-memory.md` 与 `docs/phase-one/owner-auto-memory-ui.md`

### 数据模型（迁移 607）

```sql
-- 每 owner/AI 一项，默认关闭
CREATE TABLE owner_auto_memory_settings (
  owner_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  ai_profile_id TEXT NOT NULL REFERENCES ai_profile(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>=0),
  enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
  target_token TEXT,
  PRIMARY KEY(owner_id,ai_profile_id)
);
-- 目标 token 的随机纪元 + 触发器，完全照搬 owner_memory_notes 的
-- owner_memory_target_epochs 与 binding/provider/direct_grants 触发器模式
-- （把表名/字段名替换成 auto memory 版本）。
CREATE TABLE owner_auto_memory_target_epochs (...);
-- accepted-at 来源戳：只回填“接受时已开启”的来源
CREATE TABLE owner_auto_memory_sources (
  source_message_id TEXT PRIMARY KEY NOT NULL REFERENCES owner_ai_direct_sources(source_message_id) ON DELETE CASCADE,
  settings_revision INTEGER NOT NULL,
  target_token TEXT NOT NULL
);
```

### 采集规则（规则优先，拿不准 → T1）

在 `OwnerAiDirectIncoming` 已提交 owner 文本后（或新增一个轻量 `AcceptedMessageObserver`，仅当开启时）采集：

- 只处理 `owner_ai_direct_sources` 中的 owner 文本消息（不含编辑、未撤回、私聊）。
- 显式记忆指令（“记住”“记下”“别忘了”“以后”“别忘”）且长度有界 → `tier=t0`、`evidence=userStated`、`status=active`。
- 其余 owner 文本 → `tier=t1`、`evidence=userStated`、`status=pending`（需主人在管理器中确认后才注入）。
- 上限：每 AI 最多 50 条 active/pending；超限不写（或只保留最新）。单条正文 ≤ 512 UTF-8 字节，超长截断拒绝该候选。
- 绝不采集群聊或第三人内容（scope 只用 `private:<aiProfileId>:<ownerAccountId>`）。

`MemoryCandidate` 来源：`owningOperatorId=ownerAccountId`、`aiProfileId`、`sourceAccountId=ownerAccountId`、`aboutAccountId=ownerAccountId`、`scopeKey='private:<aiProfileId>:<ownerAccountId>'`、`sourceMessageIds=[消息 id]`。

### 生产 `MemoryAuthorization`（owner-private）

`OwnerPrivateMemoryAuthorization`：

- `authorizeCapture`：candidate.owningOperatorId == ai 的 operator、scope 是 `private:` 且 `parts[2] == ownerAccountId`、source 消息在当前有效 grant 内、settings.enabled=1 且 target_token 匹配、来源账号是 owner 本人。
- `authorizeRead` / `authorizeTransition`：context.talkingWith == owningOperatorId（仅本人在本人私聊可见），其余拒绝。

### HTTP 契约

`GET/PUT /api/v1/ai-profiles/{aiId}/owner-auto-memory/settings`：

- 响应 `{revision:int, enabled:bool, target:{providerId,model,origin,token}|null}`，未配置返回 `revision:0,enabled:false,target:null`。
- PUT `{expectedRevision:int, enabled:bool, expectedTargetToken:string|null}`，开启需 target 且 token 精确匹配，关闭 token 必须 null。过期 409、字段错 400、非 owner/无效 AI 404、未认证 401。

`GET /api/v1/ai-profiles/{aiId}/owner-auto-memory`：`{revision, maxEntries:50, entries:[{id,text,tier,status,createdAt}]}`（只解密本人私有 scope，T2 排除，正文解密后原样返回）。

`DELETE /api/v1/ai-profiles/{aiId}/owner-auto-memory/{memoryId}`：`{expectedRevision}` → `transition` 到 `deleted`（留审计），成功 revision+1 并返回当前列表。

`DELETE /api/v1/ai-profiles/{aiId}/owner-auto-memory`：`{expectedRevision}` → 清空（全部 transition 到 deleted）。

### 注入

active 的 `t0`/`t1` 记忆按 `MemoryStore.retrieve` 注入本人私聊 B2 回复（最多 5 条、合计 ≤1024 字节），作为 `untrusted_owner_memory` user-role 段（参照 memory notes 的注入方式，但用独立 kind 名 `untrusted_owner_memory`）。pending 不注入；模型不能自确认（`MemoryStore.transition` 已禁止）。

### 客户端

`OwnerAutoMemorySection`：读取当前设置 → 开关（开启需 target + 二次确认）、列出 entries、删除单条、清空全部；默认关闭文案与 memory notes 一致。`OwnerAutoMemoryApi` 校验响应与 CAS。

---

## 功能 B · 模型主动联系

迁移号：**608**。

新文件（由 B 负责）：

- `apps/host/lib/src/ai/life/owner_model_proactive_migration.dart`
- `apps/host/lib/src/ai/life/owner_model_proactive.dart`（服务 + 调度）
- `apps/host/lib/src/ai/life/owner_model_proactive_module.dart`（HTTP 模块）
- `apps/host/lib/src/models/model_gateway.dart`：把 `chat` 的 layer 校验扩为允许 `b3Proactive`（capability=`chat`，`allowDegradedLayer` 对 B3 恒 false，degrade→静默）。
- 测试 `apps/host/test/owner_model_proactive_test.dart`
- 客户端 `apps/client_flutter/lib/net/owner_model_proactive_api.dart`
- 客户端 `apps/client_flutter/lib/features/ai_config/owner_model_proactive_card.dart`
- 文档 `docs/phase-one/owner-model-proactive.md` 与 `docs/phase-one/owner-model-proactive-ui.md`

### 数据模型（迁移 608，照搬 owner_rule_greeting 结构 + 追加）

```sql
CREATE TABLE owner_model_proactive_stops (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL CHECK(revision>0),
  blocked INTEGER NOT NULL CHECK(blocked IN (0,1))
);
CREATE TABLE owner_model_proactive (
  owner_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  ai_profile_id TEXT NOT NULL REFERENCES ai_profile(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL CHECK(revision>0),
  local_minute INTEGER NOT NULL CHECK(local_minute BETWEEN 0 AND 1439),
  offset_minutes INTEGER CHECK(offset_minutes BETWEEN -840 AND 840),
  quiet_start INTEGER NOT NULL CHECK(quiet_start BETWEEN 0 AND 1439),
  quiet_end INTEGER NOT NULL CHECK(quiet_end BETWEEN 0 AND 1439 AND quiet_end<>quiet_start),
  interval_minutes INTEGER NOT NULL CHECK(interval_minutes BETWEEN 60 AND 10080),
  conversation_id TEXT, chat_revision INTEGER,
  nominal_at INTEGER, due_at INTEGER, observed_through INTEGER NOT NULL,
  PRIMARY KEY(owner_id,ai_profile_id),
  CHECK(...同 rule greeting 的空/非空一致性，多一个 interval_minutes)
);
CREATE TABLE owner_model_proactive_delivery (
  owner_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  ai_account_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  last_at INTEGER NOT NULL,
  PRIMARY KEY(owner_id,ai_account_id)
);
```

触发器完全照搬 rule greeting（direct_grants 的 update/delete/insert、direct_conversations 的 pair 变化、social_level 的 L0/L3/L4 变化），把表名替换为 `owner_model_proactive`。provider/binding 变化同样使许可失效。

### 设置与门槛

- `GET/PUT /api/v1/ai-profiles/{aiId}/owner-model-proactive`：响应含 `revision,enabled,localMinute,offsetMinutes,quietStartMinute,quietEndMinute,intervalMinutes,globalBlocked,globalRevision,socialLevel,chatRevision,budgetReady,lastSentAt`。开启需固定偏移、L3/L4、有效本人私聊、未全局关闭、B3 预算就绪、两项 reviewed revision 匹配。
- `GET/PUT /api/v1/accounts/me/owner-model-proactive`：`{revision,blocked}` 全局停止，开启撤销全部许可，解除停止不复活。

### 调度与模型调用

- 复用 rule greeting 的 cursor/连续观察/静默窗顺延/持久化幂等闸门（每 10 秒 poll，错过不补发，重启不重放）。
- 频率上限：`interval_minutes`（默认 1440 即一天一次，最小 60 分钟）；`owner_model_proactive_delivery.last_at` 记录上次发送，间隔不足不发送。
- 到点后：先持久推进 cursor，再在短事务复核许可/静默/预算日；然后**调用模型**（B3，capability=chat，短系统提示“给主人发一句简短主动问候，不要编造事实，不要提记忆”），拿到短文本后原子 append + 写 delivery 水位 + 无正文审计。
- 预算耗尽/未知用量/模型失败 → 静默，不补发、不冒充规则问候、不写假 token。
- 去重：`clientMsgId = 'mp_<owner>/<ai>/<day>'` 用 append 的 duplicate 判定 + delivery 水位双重去重。

### 客户端

`OwnerModelProactiveCard`：读取设置 → 填写 localMinute/quiet/offset/intervalMinutes → 二次确认开启；关闭保留设置、解除不复活；显示 lastSentAt/预算/L3-L4/静默窗状态。`OwnerModelProactiveApi` 校验响应与 CAS。

---

## 共享接线（由 Lead 负责）

- `packages/jingyu_protocol/lib/src/routes.dart`：已加 5 个路由常量（A: 3，B: 2）。
- `apps/host/lib/jingyu_host.dart`：
  - 迁移列表加 `...memoryMigrations`（600）、`ownerAutoMemoryMigration`（607）、`ownerModelProactiveMigration`（608）。
  - 默认模块加 `OwnerAutoMemoryModule`、`OwnerModelProactiveModule`。
  - 在 `OwnerAiDirectIncoming`/fanout 后挂自动记忆采集 observer；给 `OwnerAiDirectReplyObserver` 注入 auto-memory 检索与模型主动的目标/预算接线。
- `apps/client_flutter/lib/features/ai_config/ai_config_editor.dart` + `settings_screen.dart`：加两个 section/card。

## 验收口径

两条功能都要求：默认关闭无行、非 owner 404、匿名 401、严格字段 400、CAS 409、加密落库（无明文）、无正文审计、来源失效不复活、重启不重放/不补发、模型失败静默、去重。宿主 `tool/check.ps1` 全绿；随后做隔离宿主实测（合成账号、合成 worker），再按 `tool/build_phase_one_package.ps1` 打包 Windows release + Android debug + 干净宿主源码快照。
