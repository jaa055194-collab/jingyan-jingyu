# 表情回应：宿主权限与审计验证

本切片从 `fda8453735016b88f4a89040d62ee09a5c3169e9` 开始，补强 FR-15 / AC-19 的宿主表情回应接口，不改协议、迁移、差集同步、ACK 或既有置顶调用方。

## 行为与边界

- 既有 `GET/POST /api/v1/conversations/{conversationId}/messages/{messageId}/reactions` 路径不变。对有权查看且未撤回的消息，`GET` 返回 `{"reactions":[{"accountId":"…","emoji":"…"}]}`，顺序不变，没有回应时返回空数组。`POST {"emoji":"…"}` 需要当前发帖权限，成功仍返回 `{"emoji":"…","active":true|false}`。同一账号用同一精确字符串再次发送会取消；**不是幂等请求，不应自动重放**。宿主沿用非空、Dart 字符串长度不超过 32 的既有输入边界；不增表情白名单或规范化。
- 服务端在同一 SQLite 事务里检查当前会话权限、可见历史下界、准确的会话与消息身份、未撤回条件，并据此读出列表或执行切换。对格式有效的请求，不可见、入群前不可读、已撤回、错误会话、消息不存在或发帖权限丧失均返回 `404 {"error":"not_found"}`。有历史读取权限时，已拉黑的双人私聊或已撤销授权的本人 AI 私聊仍能读取其合法历史，但不得切换回应。匿名为 401，格式无效为 400；不返回内部说明文本。
- 每次成功新增/取消与一条 `message.react` / `message.unreact` 审计同事务提交。审计只写时间、操作者、消息 ID、会话 ID 和动作，不保存表情值（旧接口可接受任意短文本）、消息正文或凭据。审计写失败会回滚新增或取消。旧回应行未批量清除；不可见或撤回消息的回应不会由此接口返回。

## 隔离回归

Windows，Dart 3.14.0。以下均从 `apps/host` 运行。回归用数据目录与 bearer 均为测试临时合成，不连接现有宿主或供应商。

```powershell
dart pub get --offline
dart test --reporter expanded test/regression/message_reactions_boundary_test.dart
dart analyze --fatal-infos
dart test --reporter expanded test/message_reactions_test.dart test/regression/message_reactions_boundary_test.dart test/message_pins_test.dart test/conversation_membership_test.dart test/private_conversations_test.dart
# 在不设置外部供应商与 age 演练 opt-in 变量时：
dart test --reporter expanded
```

[定向回归](../../apps/host/test/regression/message_reactions_boundary_test.dart) 走真实默认宿主路由、SQLite、bearer 校验与事务；不经过 socket，不涉及真机 UI。

- **修复前**：同一文件 `+2 -6`、退出 1。入群前不可读及已撤回两个用例中 `GET/POST` 实际都为 200（应均为 404）；不存在消息的 GET 实际为 200（应为 404）；两次切换无审计记录；模拟审计失败时新增和取消均回复 200（应为 500，原状态不变）。两项原来就成立的拉黑和本人私聊撤销规则通过。
- **修复后**：`dart analyze --fatal-infos` 返回 `No issues found!`；上述反例、保留的 200 响应、旧表情输入与置顶/会话权限等相关合跑为 `+42: All tests passed!`（退出 0）。
- 宿主离线全套件为 `26:55 +1588 ~17: All tests passed!`（退出 0；跳过实时供应商、age opt-in 及既有明确未覆盖用例）。这不是 Android 真机验证。
