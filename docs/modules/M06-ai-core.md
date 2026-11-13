# M06 · ai_core：人格、记忆、档案、日记、约定、生活引擎、社交等级

> 依据：v4.2 FR-41～45、FR-49～56、AC-04～09/28；口径 A-1、A-6、A-7、A-10、B-2、B-3、B-4、C-3。依赖：messages、social、models。
> 本模块较大，可拆成多个 PR，每个 PR 一个子目录。

## 子目录

```text
apps/host/lib/src/ai/
  persona/    人格卡、三层自迭代、锁定、变更历史与撤回
  memory/     采集闸门、分类、状态机、检索、跨用户来源
  profile/    关于我档案、重要日子
  diary/      日记生成
  commitments/ 约定与日程候选
  life/       60s 心跳、活动库、gap 记录
  social_level/ L0–L4
  inbox/      AI 提议收件箱
```

## 关键接口

```dart
abstract class PersonaService {
  Future<Result<PersonaCard>> current(AiId ai);
  /// 自迭代：锁定时直接拒绝（口径 A-1）。
  Future<Result<PersonaChange>> selfIterate(AiId ai, PersonaDiff diff, {required String reason, required List<String> evidenceIds});
  Future<Result<void>> lock(AccountId operator, AiId ai, {required bool locked});
  Future<List<PersonaChange>> history(AiId ai);
  Future<Result<void>> revert(AccountId operator, String changeId);
  Future<Result<PersonaChange>> edit(AccountId operator, String changeId, PersonaDiff replacement);
}

abstract class MemoryService {
  /// 先 MemoryPolicy.collectionDecision；deny 时返回 Ok(null)，什么都不写。
  Future<Result<MemoryItem?>> capture(MemoryCandidate candidate);
  Future<Result<void>> transition(String memoryId, MemoryStatus to, {required AccountId actor});
  /// 检索：只返回 MemoryPolicy.mayInject 为 true 的条目。
  Future<List<MemoryItem>> retrieve(AiId ai, {required AccountId talkingWith, required String query, int topK = 8});
}
```

## 规则

1. 人格（口径 A-1）：P2 完全自主；P0/P1 可自迭代，operator 可锁定。每次变更写 `persona_history`：diff、原因、证据 id、时间。人格页可看每次改了什么，可撤回、可修改。
2. 记忆采集：先跑 `MemoryPolicy.collectionDecision`，"别记/别外传"命中则不落库（口径 A-7）。再 `resolveTier`、`initialStatus`。已实现于 `jingyu_core/memory.dart`，**直接调用，不要重写**。
3. 跨用户（口径 A-6、B-2）：`retrieve` 时，除当前用户的私聊与群 scope，还检索其他人私聊中 `about_account_id == talkingWith` 的 active 条目，注入时加前缀"某某跟我说过"。T2 永不跨用户，T1 确认前不跨用户。
4. 日记（口径 C-3）："仅自己可见"指 AI 自己；主人查看要 AI 同意（走收件箱）；其他用户不得申请。跨用户内容生成的日记、档案摘要、`query_about_me` 只对 AI 和主人可见；敏感内容不送模型，脱敏后可送。
5. 生活引擎：60s 规则心跳，不调 LLM；LLM 只在 v4.2 FR-42 列出的节点调用，且记入 B0 层。每条活动写 `activity_log`，**M07 的 S1 要靠它判断能不能说"刚浇完花"**（B-1 第 5 条）。
6. 离线：宿主恢复后只写一条 gap 记录（FR-45），错过的定时项按 B-4。
7. 目标验收（口径 A-10）：每周向主人推送一次"她最近能接住话题吗/有没有变笨"，结果存 `quality_feedback`。
8. 社交等级：改 L0 时取消该 AI 所有排队中的主动任务，1 分钟内生效（口径 C-5）。

## 验收

- [ ] A-1 锁定后 `selfIterate` 返回 forbidden；解锁后可迭代；撤回恢复上一版。
- [ ] AC-05 "别记"的内容在库里、检索日志里、导出里都找不到。
- [ ] AC-05 拿不准的进 T1 pending；pending 不出现在 `retrieve` 结果里。
- [ ] AC-05 T2 不出现在别人的上下文、导出、朋友圈。
- [ ] B-2 A 对 B 的 AI 说的关于 B 的事，B 与该 AI 对话时可被检索到，且带来源前缀。
- [ ] AC-04 改 L0 后 1 分钟内不再有任何主动行为。
- [ ] AC-07 无素材当天跳过日记并记 `skipped_reason`。
- [ ] AC-09 心跳运转；额度用尽退回规则模式；离线恢复只记 gap。
- [ ] AC-28 提议收件箱汇总全部待决事项；未批准不生效；过期失效留审计。
