# 本人私聊 · 手动记忆便签设置

客户端实现为 `ab1bff5020d80848afb448ceb0b15c350706c027`，基线 `b303c0291e326d9245b8d0f8ecfe5db95a06443d`，只依赖协议路由提交 `56df973b094ca751e2947381f54455ca2b213366`（父 `b303c02`，仅 `Routes` 三个常量）。宿主侧 manual notes 实现在 `wt-next-memory-notes` 的 task-23；本切片只改客户端、测试和证据，不改旧 `ownerTextOnly`、回复偏好、规则问候或任何 host/protocol 实现。

## 入口与范围

- **设置 → AI 运行配置 → 记忆便签**：选中并解析一个当前本人 AI 档案后，显式点“读取当前设置”。默认无读取、无写入，不把未读取当成关闭或空。
- 手动便签：非敏感、单行文字；`text.trim()` 非空，UTF-8 字节数不超过 512，拒绝所有 C0/C1 控制字符（含 LF/TAB）；每个 AI 最多 20 条。可添加、编辑、删除单条，或确认后清空全部。便签是手动保存的文字，不是聊天记录、不自动采集、不读取历史、群聊或第三人内容。
- 独立使用授权：「允许在本人私聊回复中使用这些便签」默认关闭。开启前重新读取宿主，核对 revision 和当前接收方 token，再显示确认页：当前 AI、仅当前本人 AI 私聊、receipt 的 provider/model/origin，以及“不是聊天历史、不含第三人、不会主动发送/通知”的说明。确认后仅发送 `PUT settings {expectedRevision, enabled:true, expectedTargetToken}`。
- 关闭授权只撤回使用许可，保留便签；清空便签不关闭许可；重新开启必须再次完成最新目标确认。没有自动重新开启。
- 所有成功宿主回执必须严格增加 1 个 revision 且反映请求；冲突/未知会隐藏旧状态并要求重新读取，绝不自动重试或猜测结果。切换 AI/profile、账号代际、锁定或断开会使旧确认/回执失效。

## Wire 摘要

- `GET /api/v1/ai-profiles/{aiId}/owner-memory-notes` → `{revision,enabled,maxNotes,maxNoteBytes,notes:[{id,text,createdAt,updatedAt}],target:{providerId,model,origin,token}|null}`。
- `POST` 同一 collection `{text,expectedRevision}`；`PATCH`/`DELETE` 单条 `{text,expectedRevision}` / `{expectedRevision}`；`DELETE` collection `{expectedRevision}` 清空全部；`PUT /settings` `{expectedRevision,enabled,expectedTargetToken}`。
- 仅接受精确 200 与严格字段/时间戳；401/403/404/400/409 分类提示，未接受任何认证重放。`target` 的 token 只在内存中用于本次确认，不显示或持久化。

## 验证

- `flutter analyze --no-pub` 无问题。
- 新增 API 10 项 + UI 10 项，共 20 项全部通过；覆盖默认未读取、严格状态解码、添加/编辑/删除/清空、授权确认/撤回/保留便签、无 target、修订冲突、锁定/session 退休、375 / 768 / 1280 布局。
- 同场景 Android 目标 Flutter 捕获：基线（无入口）和候选（入口/列表/确认页）各自通过；四张 390×844 PNG 已校验。真实手机、真实账号、宿主网络和全量套件不在本切片声明范围。
