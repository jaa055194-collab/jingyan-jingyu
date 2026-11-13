# M03 · messages 完整版

> 依据：v4.2 FR-13～21、FR-55、AC-18/19/20/32；口径 A-8、C-2、C-5、C-6、B-4。依赖：storage、accounts。
> 起点：`apps/host/lib/src/messages/` 已有 seq、幂等、差集、ack 的内存实现和契约测试。**在它上面扩展，不要重写。**

## 要写的文件

```text
apps/host/lib/src/messages/
  sqlite_message_store.dart   SqliteMessageStore implements MessageStore（通过 message_store_contract.dart）
  message_ops.dart            abstract class MessageOps：recall / edit / react / pin / remind / forward
  scheduled.dart              定时消息：入库、到点投递、取消
  ephemeral.dart              闪照与阅后即焚
  search.dart                 FTS5 全文检索
  attachments.dart            附件索引 + 分片上传
  messages_migrations.dart    迁移 200–299
apps/host/test/messages_full_test.dart
```

## 接口

```dart
abstract class MessageOps {
  Future<Result<void>> recall(Principal who, String messageId);            // 自己的消息，24h 内
  Future<Result<StoredMessage>> edit(Principal who, String messageId, Map<String, Object?> body);
  Future<Result<void>> react(Principal who, String messageId, String emoji);
  Future<Result<void>> pin(Principal who, String conversationId, String messageId);
  Future<Result<List<StoredMessage>>> forward(Principal who, List<String> messageIds, String toConversationId, {bool merged = false});
}

abstract class MessageSearch {
  /// 只返回 [who] 可见的结果；可见性由服务端判定（FR-17）。
  Future<Result<List<SearchHit>>> search(Principal who, String query, {String? senderId, MessageKind? kind, DateTime? from, DateTime? to});
}
```

## 规则

1. 编辑、重新生成：旧版本写 `message_edits`（正文加密存），界面标"已编辑"。审计条目只存 `edit_id` 引用；管理端读旧版正文走单独的 `Access.admin` 路由（口径 A-8）。
2. 撤回留审计，不记正文。
3. 定时消息到点由宿主投递；宿主离线错过的按 `02-decisions.md` B-4 处理。
4. 闪照（口径 C-6）：宿主暂存；某查看者打开 5s 后，删除**该查看者**的全部痕迹（同步记录、缓存键）；其他人不受影响。闪照不进差集同步、不进搜索、不进记忆、不发给任何模型。
5. 闪照、私密动态、群消息不得作为"问 AI"或转发的上下文发给另一 AI 或外部模型（口径 C-2）。在 `forward` 与"问 AI"入口统一检查。
6. 授权撤回后的引用、索引：标记待删，10 分钟后物理删除；10 分钟内可撤销（口径 C-2）。
7. 拉黑、L0、撤销等操作与正在发送的任务并发时，1 分钟内生效即可（口径 C-5）。
8. 附件：库里只存 id、sha256、mime、size、rel_path、宽高、时长；分片 8MB、断点续传；配额检查调用 M12 的接口（M12 未完成前用放行假实现）。

## 验收

- [ ] AC-18 断网发送 3 条，恢复后补传且服务端不重复（用同一 clientMsgId 重放）。
- [ ] AC-18 双设备 ack 后未读一致。
- [ ] AC-19 撤回超过 24h 失败；撤回留审计且审计里无正文。
- [ ] AC-19 编辑后旧版本可由管理员路由读到，普通用户读不到别人的旧版本。
- [ ] AC-19 定时消息到点投递；取消后不投递。
- [ ] C-6 两人看同一闪照：A 看满 5s 后 A 处无痕迹，B 仍可看。
- [ ] C-2 闪照/私密动态/群消息作为"问 AI"上下文被拒绝。
- [ ] AC-20 搜索不返回请求者不可见的消息（串数据测试）。
- [ ] SqliteMessageStore 通过 `message_store_contract.dart`。
