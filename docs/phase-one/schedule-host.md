# 定时消息：宿主投递与可恢复状态

基线 `e7c2ce7b8e406a4c90a5888099f7f4fc3ee107ca`。本切片补强 FR-20/B-4 的宿主定时消息路径；不新增调度器、不改通知、轮转或主动消息。现有 `POST`/`DELETE` 成功响应保持原形。

## 既有接口（未改成功 wire）

- `POST /api/v1/conversations/{conversationId}/scheduled-messages`：正文 `{kind, body, deliverAt}`；成功返回 `{id, conversationId, deliverAt, status:'pending'}`。未来时间、成员和正文形状沿用既有规则；所有既有消息 kinds 继续接受（新增 UI 只发普通文本）。
- `DELETE /api/v1/conversations/{conversationId}/scheduled-messages/{scheduledId}`：成功返回 `{cancelled:true}`；未知/非本人/非本会话统一 404，存在但非发送者 403，非 pending 400。
- `POST` 没有客户端幂等键；客户端不得自动重放未知结果的创建请求。

## 新增只读回读

`GET /api/v1/conversations/{conversationId}/scheduled-messages`，无查询参数或仅 `?scheduledId=<id>`：

```json
{"scheduledMessages":[{"id":"…","conversationId":"…","deliverAt":"2026-11-22T01:00:00.000Z","status":"pending"}],"hasMore":false}
```

- 只返回当前认证发送者自己的行；没有正文、其他账号、提供方或凭据。集合按最新在前，最多 50 条并带 `hasMore`；指定 `scheduledId` 时最多一条、`hasMore:false`。
- 指定 ID 但不存在/不属于发送者/不属于该 conversation：`404 {"error":"not_found"}`。没有自有行（包括语法有效但实际不存在的 conversation）时集合为 `200` 空数组，查询本身绑定 conversation+发送者，不会读取其他 conversation 的行。
- `status`：`pending`、`delivered`、`cancelled`、`expired`。`cancelled` 也用于到点后当前发帖权限已失效的终态扣留（旧状态枚举没有 rejected 值），表示该槽不会重放或复活；`expired` 保持原有超过 24 小时不补发语义。

## 投递事务

原实现先读取 pending 快照，再用普通 `MessageStore.append` 追加、另一次写更新状态。本切片改为：每个到点候选在一个 SQLite 事务内重新读取 exact row；仍为 pending 且到点、未超过 24 小时；按 `CombinedMembership.firstVisibleSeqInTransaction` 复核当前发帖/群组或私聊权限；若 body 含 `attachmentId`，用既有 `AttachmentService.assertSendableInTransaction` 复核发送者自己且同 conversation 的附件。通过后在同一个事务中 `appendInTransaction` 普通消息、更新 `delivered`；权限/内容失效则更新终态 `cancelled` 并回滚/不追加；超过 24 小时更新 `expired`。取消和投递因此不会出现“已成功取消但仍发送”的旧快照路径。
- 创建也使用同一 Tx 检查当前发帖权限及附件可发送性后才插入 pending。
- 数据库/加密异常整体回滚；失败不会把未追加的行误标 delivered。进程异常中断可能留下 pending，后续定时轮询按上述规则重新复核；这仍是既有轮询边界，不新增重试队列。
- `cancelled`/`expired` 是终态；重新加入群或恢复权限不会使旧槽复活。

## 验证

从 `apps/host` 运行：

```powershell
dart analyze --fatal-infos
dart test --reporter expanded test/message_scheduled_test.dart
```

结果：`No issues found!`，定向 `+9: All tests passed!`。测试使用真实默认 SQLite/`MessagesModule`/`Pipeline`、合成账号与 `FakeClock`，覆盖：正常一次投递、未来时间、取消、24h 过期、亚秒不提前、sender-only GET 与缺失 conversation 空结果、群内移除发送者后终态扣留且重新加入不复活、候选快照后取消不发送、旧非文本 kind 仍可投递、无正文/其他发送者数据不外泄。未使用真实宿主、真实用户数据或外部 provider。

## 已知限制

- 回读仅面向发送者自己的调度元数据，不补发丢失的 POST 回执；客户端遇到未知创建结果必须显示“结果未知”并按产品要求由用户处理，不能自动 POST 重试。
- 既有 `POST` 仍接受 legacy 非文本 kinds；新增 UI 只使用普通 `kind:'text', body:{text:…}`，不展示附件/媒体定时消息。
- 未覆盖客户端入口、通知、后台执行或正式发布验收。
