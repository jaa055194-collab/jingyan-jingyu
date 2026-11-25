# 本人 AI 私聊 · 显式记忆便签（宿主切片）

这是一张独立、默认关闭的本人私聊记忆授权：主人手动保存少量非敏感便签，并可单独开启“允许这个 AI 在**本人私聊**的 B2 回复中参考这些便签”。它不是 `ownerTextOnly`、回复偏好授权或规则问候，也不会自动从聊天采集、读取历史/群聊/第三人内容、主动发送或调用模型预算以外的能力。绑定或撤销现有私聊仍按原协议工作；本功能只增加自己的表、路由和一条有界 user-role 数据。

## HTTP 契约

- `GET/POST /api/v1/ai-profiles/{aiId}/owner-memory-notes`，`PATCH/DELETE /api/v1/ai-profiles/{aiId}/owner-memory-notes/{noteId}`，`DELETE` 集合路由清空全部便签；`PUT /api/v1/ai-profiles/{aiId}/owner-memory-notes/settings`。`aiId` 是 canonical profile ID。所有读取和写入都以认证账号/设备及当前 owner/AI 身份在同一 SQLite 事务复核；非 owner、非当前有效 AI 统一 404，不提供 admin 代操作。
- GET 和每个成功写入返回同一形状：`{"revision":int,"enabled":bool,"maxNotes":20,"maxNoteBytes":512,"notes":[{"id":string,"text":string,"createdAt":string,"updatedAt":string}],"target":{"providerId":string,"model":string,"origin":string,"token":string}|null}`。未配置读取不建行，返回 `revision:0, enabled:false, notes:[], target`: 依据当前私聊和启用的 `chat` 绑定可显示目标；显示目标不代表模型/预算已可用。
- POST `{"text":string,"expectedRevision":int}`；PATCH `{"text":string,"expectedRevision":int}`；DELETE 单条/集合 `{"expectedRevision":int}`；settings `{"expectedRevision":int,"enabled":bool,"expectedTargetToken":string|null}`。每次接受的操作 revision 恰好 +1。开启需要当前 `target` 且 `expectedTargetToken` 精确匹配；关闭时 token 必须为 null 并可保留便签。过期 409，字段/范围/条数/大小 400，未认证 401，找不到 404。
- 便签 trim 后非空、UTF-8 最多 512 bytes、单行（拒绝所有 C0/C1 控制字符及 bidi/invisible），每个 owner/AI 最多 20 条。正文用 AES-GCM 加密并绑定用途、owner、profile、note id；审计只记动作、note id、revision 和启用状态，不含正文。删除/清空立即影响之后新接受的来源，不承诺从历史备份或已传输 prompt 中消失。

## 注入与失效

[迁移 606](../../apps/host/lib/src/ai/memory/owner_memory_notes_migration.dart) 仅新增便签、本功能设置、目标代和 accepted-source 标记表，不回填任何授权。目标 token 由独立的随机代与 canonical 配对/基础授权 revision 组成；Provider/绑定/凭据变化或本功能私聊授权变化会使设置失效，不复活旧目标。每个 `owner_ai_direct_sources` 接受事务只在当时已开启且有目标时写入 settings revision+token；旧消息、重放、确认前以及之后编辑/删除/清空便签或关闭授权都不会获得新便签。

[观察者](../../apps/host/lib/src/brain/owner_ai_direct_reply_observer.dart) 在准备、模型交递前和发布事务中复核 accepted-source 标记、canonical 配对、当前目标及授权；失效时本次回复丢弃/失败，不会悄悄换成无授权的便签。实际 B2 请求最多带 5 条、合计最多 1024 bytes 的 `untrusted_owner_memory_notes` user-role 数据，当前单条主人文本仍独立且最后；系统提示、人格卡和旧的 `ownerTextOnly` 两段普通路径不变。仅使用现有 B2 runtime、预算、URL guard、用量结算与错误语义；便签本身不产生 token 或模型调用。

## 验证边界

宿主目录 `dart pub get --offline`、`dart analyze --fatal-infos`、`dart test --reporter expanded test/owner_memory_notes_host_test.dart`，并使用合成 worker 的默认宿主装配测试。覆盖默认无行/鉴权、严格限制与密文无正文审计、CAS/目标失效/重启、旧来源不回填、编辑后旧来源不使用、超过 5 条的新到旧有界截断，以及 B2 请求的 user-role 段。未使用真实用户数据、外部模型、客户端或原生设备；不能替代 FR-49/50 的完整记忆管理器/跨用户检索，也不包含主动模型生成消息。
