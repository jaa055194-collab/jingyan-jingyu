# 本人 AI 私聊 · 聊天历史自动记忆（宿主切片）

这是一张独立、默认关闭、按 AI 单独开启的聊天历史自动记忆授权：仅在主人本人 AI 私聊中采集**主人自己的文字消息**，并提供一个有界的查看/删除/清空管理器。它不是 `ownerTextOnly`、手动记忆便签、回复偏好或规则问候；绝不采集群聊或第三人内容，不主动发送或通知。复用既有 `encrypted_memory` / `memory_source_messages`（迁移 600），本功能只新增自己的设置表、目标代、accepted-source 来源戳、三条路由，以及一条有界的 `untrusted_owner_memory` user-role 注入段。

## 数据与采集

- [迁移 607](../../apps/host/lib/src/ai/memory/owner_auto_memory_migration.dart) 新增 `owner_auto_memory_settings`（每 owner/AI 一行、默认无行）、`owner_auto_memory_target_epochs` 与 `owner_auto_memory_sources`。目标代与触发器完全照搬手动便签的失效模式：Provider/绑定/凭据或本功能私聊授权变化都会使设置失效，不复活旧目标。accepted-source 来源戳只回填“接受时已开启”的来源，因此旧消息、重放或之后开启都不会补采。
- 采集规则优先：显式记忆指令（“记住 / 记下 / 别忘了 / 以后 / 别忘”）且长度有界 → `tier=t0`、`evidence=userStated`、`status=active`；其余主人文字 → `tier=t1`、`evidence=userStated`、`status=pending`。绝不 `t2`。每 AI 最多 50 条 active+pending，单条正文 ≤ 512 UTF-8 字节（超长拒绝该候选）。scope 只用 `private:<aiProfileId>:<ownerAccountId>`。
- 采集经由 `MemoryStore.capture` 落库，复用其 cipher/AAD；生产 [授权器](../../apps/host/lib/src/ai/memory/owner_memory_authorization.dart) `OwnerPrivateMemoryAuthorization` 在 capture/read/transition 上按同一事务复核：owner 是该 AI 的 operator、scope 为 `private:` 且第三段是 owner 本人、来源账号是 owner、来源消息在当前有效 grant 内、settings 已开启且 target_token 匹配。模型不能自确认（`MemoryStore.transition` 已禁止）。

## HTTP 契约

- `GET/PUT /api/v1/ai-profiles/{aiId}/owner-auto-memory/settings`：`{"revision":int,"enabled":bool,"target":{"providerId":string,"model":string,"origin":string,"token":string}|null}`；未配置返回 `revision:0,enabled:false,target:null`。开启需 `target` 且 `expectedTargetToken` 精确匹配，关闭 token 必须为 null。过期 409、字段错 400、非 owner/无效 AI 404、未认证 401。
- `GET /api/v1/ai-profiles/{aiId}/owner-auto-memory`：`{"revision":int,"maxEntries":50,"entries":[{"id":string,"text":string,"tier":string,"status":string,"createdAt":string}]}`，只解密本人私有 scope，排除 T2，正文解密后原样返回（active/pending 均可见）。
- `DELETE /api/v1/ai-profiles/{aiId}/owner-auto-memory/{memoryId}` 与 `DELETE .../owner-auto-memory`：`{"expectedRevision":int}`，transition 到 deleted（active）或 rejected（pending，因策略禁止 pending→deleted），成功 revision+1 并返回当前列表。审计只记动作/ID/revision/时间，绝不含正文；来源 ID 不可变。

## 注入与失效

active 的 `t0`/`t1` 记忆经 [服务](../../apps/host/lib/src/ai/memory/owner_auto_memory.dart) 的 `forSourceInTx`/`isFreshInTx` 快照与复核，按最新优先最多 5 条、合计 ≤ 1024 UTF-8 字节注入本人私聊 B2 回复，作为独立 `untrusted_owner_memory` user-role 段（区别于 `untrusted_owner_memory_notes`）。pending 永不注入。每次设置变更、目标变化或 accepted-source 失效都会使旧快照作废。

## 验证边界

宿主目录 `dart analyze --fatal-infos` 与 `dart test test/owner_auto_memory_test.dart`（真实 SQLite + FakeClock）。覆盖默认无行/鉴权、严格字段、CAS 409、密文无正文审计、仅采集授权私聊（拒群聊/第三人）、T1 pending 不注入、T0 active 有界 ≤5/≤1024、50 条上限、旧来源不补采、删除/清空。未使用真实用户数据、外部模型或原生设备；不替代 FR-49/50 的完整记忆管理器，也不包含主动模型生成消息。
