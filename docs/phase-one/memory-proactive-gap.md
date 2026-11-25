# 第一期基线复核：记忆与主动消息

**历史基线结论：基础私聊授权不能跨轮记住主人信息，也不能主动发给主人。** 已有的是收到主人消息后的被动回复；在模型运行时、绑定、人格和预算就绪时，模型可使用保存的人格回复当前单条消息。后续新增的[独立回复偏好授权](owner-reply-preferences.md)只覆盖显式保存的回复长短、排版，默认关闭，旧私聊授权不自动升级。它不召回聊天历史，也不主动联系。下文保留基线证据。

复核基线：本地 `38cd86c8f3a5c5e8b29a6d997bd02a2790400e96`，由 `git rev-parse HEAD 'HEAD^{tree}'` 确认为 tree `3478ae317ae296f252ac44e7aade2aa0ca96fc93`；该 tree 与发布计划记录的远端 `d9dc55d5cad6042bc6f3b3fe7da9b38cf15606c3` 一致。仅使用本地对象离线检查，未访问远端或用户数据。

## 基线证据

| 能力 | 现有行为和边界 | 对应检查 |
|---|---|---|
| 主人私聊与人格 | 默认宿主装配了 [主人回复观察者](../../apps/host/lib/jingyu_host.dart#L326-L351)。规则 S1 是被动回复；S2 的 [无状态聊天入口](../../apps/host/lib/src/models/stateless_owner_chat.dart#L151-L191) 只发受限的当前文本及保存的人格，不取历史、摘要或记忆。[客户端授权文案](../../apps/client_flutter/lib/features/settings/settings_screen.dart#L964-L968) 明示此边界，授权本身不发消息。 | [无状态聊天测试](../../apps/host/test/stateless_owner_chat_test.dart) 断言输出给模型的是系统、当前人格、单条输入及 B2 pinning；[原主人模型链测试](../../apps/host/test/owner_ai_direct_model_flow_test.dart) 包含历史不会入出站请求及撤权丢弃在途回存。 |
| 记忆仓储 | [Migration 600](../../apps/host/lib/src/ai/memory/memory_migrations.dart) 是可选的；[默认迁移](../../apps/host/lib/jingyu_host.dart#L132-L161) 未注册它。[MemoryStore](../../apps/host/lib/src/ai/memory/memory_store.dart) 有加密与 owner/AI/scope/id 绑定、同事务来源授权接口、状态与审计；默认空分类为待确认，召回查询排除非 active 与 T2，模型不能自确认。没有生产授权实现、管理路由或客户端记忆入口；[路由常量](../../packages/jingyu_protocol/lib/src/routes.dart#L186-L187) 本身不是可用接口。 | [仓储测试](../../apps/host/test/memory_store_test.dart) 检查 opt-out、T1/T2、夹具授权、密文和重启，只能证明内部仓储。 |
| 上下文装箱 | [ContextAssembler](../../apps/host/lib/src/ai/context/context_assembler.dart#L95-L127) 接收调用方已经授权的同 scope 召回，在指定 token 窗口内作为带来源的 `untrusted_memory` 用户角色数据，不提升为 system。[ContextualChat](../../apps/host/lib/src/ai/context/contextual_chat.dart#L52-L59) 是内部能力，不是默认主人回复链，也不负责实际召回授权。 | [上下文测试](../../apps/host/test/context_assembler_test.dart) 检查范围、角色、授权和容量；不证明真实来源有权被注入。 |
| 活动心跳与社交等级 | [Migration 602](../../apps/host/lib/src/ai/life/life_migrations.dart) 未默认装配；[LifeEngine](../../apps/host/lib/src/ai/life/life_engine.dart#L57-L87) 是显式调用的规则心跳和离线 gap 记录，不调模型、不开 timer、不发消息。默认 [社交等级 HTTP](../../apps/host/lib/src/ai/social_level/social_level_module.dart) 保存 L0–L4；未配置保持未配置；等级不等于收件人授权，也没有可停掉的主人主动调度器。 | [心跳测试](../../apps/host/test/life_engine_test.dart) 检查 FakeClock、SQLite、重启不补造活动；[社交等级路由测试](../../apps/host/test/social_level_routes_test.dart) 检查实际配置与权限。 |
| 主动发送与预算 | 已有 [B3 预算枚举](../../packages/jingyu_core/lib/src/budget.dart#L8-L22)，但 [ModelGateway](../../apps/host/lib/src/models/model_gateway.dart#L107-L112) 只支持 B1/B2。生产没有本功能的 opt-in、静默窗、AI 发送与客户端入口。[定时消息 timer](../../apps/host/lib/src/messages/messages_module.dart#L108-L136) 投递的是用户事先提交的 [定时消息](../../apps/host/lib/src/messages/scheduled.dart#L42-L79)，不可当作 AI 主动联系。 | 无主动发送或端到端验收证据；不能用 S1 被动回复、用户定时消息或心跳代替。 |

## 为什么不接入现有私聊授权

[主人私聊授权规范：边界及 HTTP 合约](../owner-ai-direct-consent.md#L5-L34) 明确规定 `ownerTextOnly` 仅允许响应该私聊内新接受的主人单条文本，排除历史、记忆、第三方来源和附件；客户端也向已授权用户作出相同承诺。即使内容由主人手填并在宿主加密，发送给模型依然改变了授权的数据范围，不能沿原授权扩展。将便签标为不可信 user-role 数据只处理提示角色，不能替代授权；[撤权规范](../owner-ai-direct-consent.md#L65-L75) 的最终复核也不能撤回已传输的提示。因此基础许可本身始终不包含记忆或主动联系；已经单独支持的固定回复偏好以专门的范围和验收记录为准。

## 后续工单需要明确

- **超出固定偏好的通用记忆（[FR-49/50](../../鲸言鲸语-需求规格-v4.2.md#L403-L420)）**：仍需区分主人手填便签、从聊天建议的候选和第三方内容；分别定义来源授权、敏感/T2、关闭/删除/角色转移、备份和供应商留存语义。不能沿现有 `ownerTextOnly` 或固定格式偏好许可扩大范围。真实验收需覆盖来源撤权、跨账号/实体/会话隔离及写入故障。
- **主动消息（[FR-42–44](../../鲸言鲸语-需求规格-v4.2.md#L321-L344)、[FR-48](../../鲸言鲸语-需求规格-v4.2.md#L381-L396)）**：批准独立默认关闭的主人接收许可，明确 L3/L4 与 L0 停发、静默窗的时区、间隔/每日上限、首次发送时机和撤销语义。决定 B3 模型调用的能力绑定、缺失/未知/耗尽预算时何时必须静默、非预算性模型故障是否允许无 token 规则问候，不得把规则问候冒充模型输出。生产架构需维护可撤销授权、持久化间隔/幂等键、重启不补发、发前复核、审计与客户端真实状态；用 FakeClock+SQLite 验证边界，再做隔离宿主的可观察发送与停发验收。

## 复核命令与结果

从 `38cd86c` 用 `git archive` 解出隔离的宿主与依赖，在快照的宿主目录运行：

```powershell
dart pub get --offline
dart test --reporter expanded test/memory_store_test.dart test/context_assembler_test.dart test/life_engine_test.dart test/social_level_routes_test.dart test/stateless_owner_chat_test.dart
```

Windows 上 **59 项通过，退出码 0**；不含真实用户数据、外部模型、生产记忆/主动发送、客户端、截图或设备验收。上表列出但未在本轮复跑的模型链测试只作源码指引。基线已有记录与本结论一致：[实现状态](../implementation-status.md#L68-L74)、[只读验收记录 AC-04/05](../acceptance.md#L120-L121)。本次不更改原验收状态。
