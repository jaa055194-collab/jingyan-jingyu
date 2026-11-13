# M07 · brain：S1/S2 路由、梗库、领域卡组、预算

> 依据：v4.2 FR-46/47/48、AC-33/34/35；口径 A-2、A-3、B-1、B-5。依赖：models、ai_core。

## 要写的文件

```text
apps/host/lib/src/brain/
  brain_module.dart     name 'brain'
  classifier.dart       S1 分类器：规则优先 + chat.fast 小模型
  router.dart           BrainRouter：决定 S1 直答 / 衬垫 + S2 / 纯 S2
  s1_responder.dart     接梗、衬垫、轻事务；生活事件只引用 activity_log
  s2_responder.dart     主对话：记忆检索、领域卡组注入、流式输出
  meme_library.dart     三层梗库：通用 / 圈内 / 个人
  domain_packs.dart     领域卡组（≤500 字/领域，用完即弃）
  pacing.dart           拟人延迟 1–4s（可关），使用注入的 Clock
apps/host/test/brain_test.dart
```

## 接口

```dart
enum Complexity { simple, complex, unsure }

class BrainDecision {
  final Complexity complexity;
  final bool sendPadding;      // 是否先发 S1 衬垫
  final List<String> reasons;  // 规则命中原因，写日志
}

abstract class BrainRouter {
  Future<BrainDecision> decide(AiId ai, IncomingMessage message, {required bool inGroup});
  Stream<OutgoingPiece> respond(AiId ai, IncomingMessage message, BrainDecision decision);
}

class OutgoingPiece {
  final String text;
  final String source;               // 's1' 或 's2'
  final List<String> activityRefs;   // S1 引用的 activity_log id，可为空
}
```

## 规则

1. 路由按 `02-decisions.md` B-1：先 S1 分类；`simple` 由 S1 直答；`complex` 先衬垫（可关）再 S2；`unsure` 按 `complex` 处理。
2. S1 只有在 `activity_log` 里有对应记录时才能说"她自己的生活事件"，并把 id 写进 `activityRefs`。没有记录就不说。单测必须覆盖"没有记录时 S1 不提浇花"。
3. S1 不对用户或外部世界做事实断言，不做承诺；输出 `source='s1'`，不进记忆候选，可以进人格复盘、日记、梗库（口径 B-1 第 7 条）。
4. 群聊同样走本路由（口径 A-3）；能不能发言先问 M04 的 `GroupAiPolicy.mayPost`。
5. 预算：S1 记 B1 层，S2 记 B2 层。B1 耗尽降为纯规则（表情/模板），不升级 S2（B-5）。B2 耗尽只回主人私聊，朋友消息回"稍后回"。
6. 缓存：系统提示词、人格卡、卡组前缀作为可缓存前缀传给网关；同群同话题短窗口去重。
7. 梗库命中走 embedding（绑定矩阵 `embedding` 能力）；未绑定时只用正则。
8. 领域卡组只注入本轮上下文，不落历史；领域外 S2 回"这个我不熟"。

## 验收

- [ ] AC-33 寒暄/接梗由 S1 直答，S2 未被调用（用计数的假网关断言）。
- [ ] AC-33 提问/长文/情绪事件触发衬垫 + S2；衬垫可关；拟人延迟可关。
- [ ] AC-33 `unsure` 升级 S2。
- [ ] B-1 S1 回复里提到的生活事件都能在 `activity_log` 找到；没有记录时不提。
- [ ] AC-33 S1 输出不产生记忆候选。
- [ ] AC-34 梗库三层命中与过期正确；AI 提议的新梗进收件箱。
- [ ] AC-34 领域卡组注入 ≤500 字且不落历史。
- [ ] AC-35 五层降级路径各有一条测试；预算观面板数据与用量记录一致。
