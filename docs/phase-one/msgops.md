# 第一期消息操作：编辑、撤回、复制

本切片复用宿主已有接口，不改宿主、协议、会话差量同步或 ACK。宿主仍判定成员资格、发送者及撤回的 24 小时窗口；**24 小时限制不适用于编辑**。

- 在会话内点已发送消息旁的 **⋯**。未撤回文本可复制到系统剪贴板；本人文本可编辑，编辑对话框预填正文，不改聊天草稿。本人 24 小时内的消息可经二次确认撤回。
- 编辑只替换 `text`，保留原 body 的其他字段。确认回执必须匹配会话、消息、序号、发件人、类型、时间和完整正文；撤回只接受 `{"recalled":true}`。客户端不重放写请求。宿主拒绝和结果未确认分别提示；未确认时不显示成功，当前客户端会话拦住同一消息的继续写入，不以「刷新会话」承诺核对结果。
- 确认编辑在原序号原子写入新正文和独立的本地「已编辑」标记，重启保留；不把标记放进消息 body。已收到的宿主墓碑或本机确认撤回显示「消息已撤回」，不渲染正文，也不提供复制、收藏或附件操作。
- 连接断开时，同一登录会话中已有文本仍可复制；编辑和撤回需要连接。切换会话、锁定或登录变化后的旧确认不能提交，旧弹窗隐藏编辑文本。同一登录会话切换到别的聊天时，已经提交且确认的回执可更新原聊天缓存，但不会把结果提示发到新聊天。

## 验证

代码修订 `845937c57c3ae0c4e0cea80c0130dd9fa162058b`，Windows 上 Flutter 3.50.0 / Dart 3.14.0：

- `flutter analyze --no-pub`：无问题。
- `flutter test --no-pub test/message_operations_api_test.dart test/runtime_message_operations_test.dart test/message_actions_ui_test.dart test/chat_favorites_route_test.dart test/message_image_preview_ui_test.dart test/runtime_attachment_send_test.dart test/search_screen_test.dart`：53 项通过。覆盖真实回环 HTTP、精确回执、本地重启恢复、拒绝/未知结果、错误会话不提示、锁定中隐藏编辑框、精确剪贴板字段与旧操作失效；收藏、搜索、图片预览、附件发送相关回归通过。
- 客户端内核：`dart analyze --fatal-infos` 无问题；`dart test` 293 项通过，包含同序号替换、不改游标/已读、终态墓碑、检查点失败不发布。
- 既有宿主：`dart test test/message_edit_test.dart test/message_recall_test.dart` 10 项通过，使用原有真实 SQLite 测试（包含恰好 24h、超时、拒绝非本人、审计）。Flutter 捕获与客户端测试的回环服务是合成夹具，不是部署或双端互通验收。
- [同场景 Flutter 前后对照与复现命令](../../apps/client_flutter/evidence/message-operations.md)。

## 未覆盖 / 边界

- 「已编辑」是本设备确认的本地标记，不补标来自旧版本或其他设备的编辑。本切片不设计跨设备冲突合并、重放或推送：宿主编辑/撤回原行不增序号，已缓存该行的其他客户端未必收到更新。新拉取到墓碑的客户端可以显示占位。
- 撤回不清除他人既有缓存、历史备份、已复制文字或系统剪贴板，不承诺本地快照备份的安全擦除。客户端在 24 小时之外主动禁用撤回入口（本机时钟只做提示，宿主复核）。
- 置顶、表情回应、定时消息、联系人「打开私聊」未纳入本切片；未做发布、打包或真实 Windows/Android 设备输入验证。
