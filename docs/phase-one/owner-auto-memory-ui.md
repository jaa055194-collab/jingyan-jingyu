# 本人私聊 · 聊天历史自动记忆设置（客户端切片）

客户端为自动记忆提供默认关闭的按 AI 开关与有界管理器，只依赖协议路由 `aiOwnerAutoMemory` / `aiOwnerAutoMemorySettings` / `aiOwnerAutoMemoryEntry` 三个常量。本切片只改客户端 API、UI 与测试，不改旧 `ownerTextOnly`、手动便签、回复偏好、规则问候或任何 host/protocol 实现。

## 入口与范围

- **设置 → AI 运行配置 → 自动记忆**：选中并解析一个当前本人 AI 档案后，显式点“读取当前设置”。默认无读取、无写入，不把未读取当成关闭或空。
- 授权开关默认关闭。开启前重新读取宿主，核对 revision 与当前接收方 token，再显示二次确认页：当前 AI、仅采集当前本人 AI 私聊、receipt 的 provider/model/origin、明确记忆指令立即生效 / 其余待确认、以及“不采集群聊或第三人内容、不主动发送/通知”的说明。确认后仅发送 `PUT settings {expectedRevision, enabled:true, expectedTargetToken}`。
- 列出 entries（t0/t1 与 active/pending 标签、创建时间），删除单条需确认，清空全部需确认。关闭授权保留已采集内容；清空不关闭授权；重新开启必须再次完成最新目标确认，没有自动重新开启。
- 所有成功宿主回执必须严格增加 1 个 revision 且反映请求；冲突/未知会隐藏旧状态并要求重新读取，绝不自动重试或猜测结果。设置与列表共享同一 revision，任何一侧变更后另一侧同步。切换 AI/profile、账号代际、锁定或断开会使旧确认/回执失效。

## Wire 摘要

- `GET /api/v1/ai-profiles/{aiId}/owner-auto-memory/settings` → `{revision,enabled,target:{providerId,model,origin,token}|null}`。
- `PUT` 同一 settings `{expectedRevision,enabled,expectedTargetToken}`。
- `GET /api/v1/ai-profiles/{aiId}/owner-auto-memory` → `{revision,maxEntries,entries:[{id,text,tier,status,createdAt}]}`。
- `DELETE .../owner-auto-memory/{memoryId}` 与 `DELETE .../owner-auto-memory`：`{expectedRevision}`，返回当前列表。
- 仅接受精确 200 与严格字段/时间戳；401/403/404/400/409 分类提示，未接受任何认证重放。`target` 的 token 只在内存中用于本次确认，不显示或持久化。

## 验证

- `flutter analyze` 无问题。
- 新增 API 测试与 UI 测试全部通过；覆盖默认未读取、严格状态解码、开关二次确认/撤回/保留条目、删除单条/清空、无 target、修订冲突（读后变更会在二次确认前作废旧动作）、宿主 409 不重试、离线不读写。
- 真实手机、真实账号、宿主网络和全量套件不在本切片声明范围。

## 接线（给 Lead）

`settings_screen.dart` / `ai_config_editor.dart` 里按现有 memory notes section 的方式挂载即可：

```dart
OwnerAutoMemorySection(
  api: OwnerAutoMemoryApi(connection),
  profile: <canonical AiId>,
  aiLabel: <显示名>,
  isCurrent: () => <当前 profile 且会话未失效>,
  canContactHost: () => <宿主连接可用>,
)
```

section 自身管理读取/写入状态、二次确认与 CAS 校验，不需要额外回调；切换 profile 或会话失效时由 `isCurrent` 使其隐藏并作废旧确认。
