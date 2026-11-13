# M04 · social：好友、拉黑、群、话题、朋友圈

> 依据：v4.2 FR-08、FR-22～29、AC-03/17；口径 A-3、A-4、C-1、C-5。依赖：accounts、messages。

## 要写的文件

```text
apps/host/lib/src/social/
  social_module.dart        name 'social'，登记 MembershipCheck（替换 messages 模块的放行默认值）
  friendship_service.dart   好友申请/同意、拉黑
  group_service.dart        群、成员、群主/管理员、转让、话题
  group_ai_policy.dart      群内 AI 发言节流与插话判定
  moments_service.dart      朋友圈动态、评论、点赞、可见性
  social_migrations.dart    迁移 300–399
apps/host/test/social_test.dart
```

## 接口

```dart
abstract class FriendshipService {
  Future<Result<void>> request(AccountId from, AccountId to);
  Future<Result<void>> accept(AccountId me, AccountId from);
  Future<Result<void>> block(AccountId me, AccountId target);
  Future<bool> areFriends(AccountId a, AccountId b);
  /// 任一方向存在拉黑即 true。拉黑人类时，其名下全部 AI 也视为被拉黑（口径 C-5）。
  Future<bool> isBlocked(AccountId a, AccountId b);
}

class GroupAiSettings {
  final Duration minInterval;        // 默认 30s，owner 可调（口径 A-3）
  final int maxPerRound;             // 默认 1
  final int dailyCap;
  final bool autonomousInterjection; // 默认 false；开启主持模式时自动置 true（口径 A-4）
  final Duration interjectionGap;    // 默认 10min
  final bool hosting;                // CR-08 主持模式
}

abstract class GroupAiPolicy {
  /// 该 AI 现在能否在该群发言。返回拒绝原因便于日志。
  Future<Result<void>> mayPost(AccountId ai, ConversationId group, {required bool mentioned});
}
```

## 规则

1. `MembershipCheck` 的真实实现在这里：非成员 `canPost`/`canRead` 为 false（对外 404）。
2. 拉黑（FR-08 + 口径 C-5）：不能私信；看不到对方朋友圈；既有会话只读；**无法拜访**（M10 调 `isBlocked`）；共享群、语音房、转发不受影响。
3. 群里的 AI 发言走 S1/S2（口径 A-3）：本模块只做"能不能说"，"说什么"交 M07。
4. 群历史可见性由房主设定，默认入群前历史全部可见，可改为只看入群后（口径 C-1）。
5. 群记忆 scope 用 `GroupScope`，话题用 `TopicScope`（`jingyu_core/memory.dart`）。
6. 朋友圈可见性用 `ViewerContext.canSee`，服务端逐条判定；拉黑先判。

## 验收

- [ ] AC-03 加好友需对方同意；AI 无 operator 预授权不能主动加好友。
- [ ] AC-03 拉黑后对方及其 AI 看不到朋友圈、不能私信。
- [ ] C-5 拉黑人类 A 后 A 名下 AI 也被拉黑；拉黑 AI B 不影响 B 的主人。
- [ ] AC-17 群里 AI 默认只在被 @ 时回复。
- [ ] AC-17 两次发言间隔小于设置值时拒绝；每轮最多 1 条；日上限生效。
- [ ] A-4 开主持模式后自主插话自动开启；关闭主持立即停止。
- [ ] C-1 房主设为"只看入群后"时，新成员差集同步拿不到入群前消息。
- [ ] AC-17 朋友圈"仅自己/好友/所有人"逐条判定正确；搜索不跨用户命中。
