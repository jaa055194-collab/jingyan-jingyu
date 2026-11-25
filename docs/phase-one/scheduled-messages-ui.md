# 群聊定时文字 · Flutter 设置操作

客户端实现 `7b1043e609fb63825adce4071c068004773c8bfe`，基线 `e7c2ce7b8e406a4c90a5888099f7f4fc3ee107ca`，使用既有 `Routes.scheduledMessages` / `Routes.scheduledMessage` 常量和宿主任务-20 的补强契约（宿主 `ba9b5770b1fca1baffe5990ebd6a546f29c60561`）。仅客户端和证据改动，不改协议、宿主、运行时壳或测试夹具之外的实现。

## 范围与安全边界

- 入口仅出现在当前已认证、已解锁、在线且可见的**普通群聊**；私聊、离线、锁定、AI 私聊和旧宿主不显示入口，不请求也不猜测许可。入口由 ChatPane 的显式按钮打开，不改变现有会话选择、消息同步或草稿。
- 发送内容固定为 `kind:'text'` 的普通文字，不接受附件、Markdown 指令或其它 kind。用户填写本机本地日期 `YYYY-MM-DD`、24 小时时间 `HH:MM`。客户端严格按日期组件回读：Dart 会规范化的不存在日期（如 2 月 30 日）和过去时刻都会被拒绝；不推断夏令时、旅行时区或本地重复规则。
- 确认页展示目标群名、将要发送的普通文字、本机本地时间及其固定 UTC 偏移，同时展示提交给宿主的绝对 UTC ISO 时间。只有用户明确点“确认安排”才发出一次 POST；不自动重试。
- 状态列表只读宿主同一会话、同一发送者的有界 GET（最多 50 条，可带已知 `scheduledId`）；不读取正文、他人记录或其它会话。`cancelled` 明确显示为“已取消/未发送”：既可能是本人取消成功，也可能是到期时权限/可见性变化而被宿主终止；`delivered` 表示已追加消息，`expired` 表示超过 24 小时未投递。界面对所有状态给出简短说明。
- 只允许取消状态为 `pending` 的已知本人记录，且需确认。取消返回 `{cancelled:true}` 才显示成功；未知结果只允许按已知 ID 重读，不能把列表里多出/缺少行当成创建或取消证据。创建只有收到精确 200 pending 回执（id/conversationId/deliverAt/status 完全匹配）才显示成功；未知创建不会重试或凭列表猜测 ID。
- 设置页与聊天草稿相互独立：进入定时流程不写入、不覆盖、不预填 `${composer}`；返回后聊天草稿仍保留。此切片不发送手机通知、不启动 AI、不写主动联系、不跨设备同步，也不承诺送达时间。

## 实现位置

- `apps/client_flutter/lib/net/scheduled_messages_api.dart`：精确 200/严格 DTO、64 KiB 响应体上限、POST/DELETE 单次请求、GET 列表/已知 ID 校验。
- `apps/client_flutter/lib/net/scheduled_messages_scope.dart` + `lib/app/runtime.dart`：仅在 authenticated/unlocked/online 当前 group 下签发 scope，scope 的每个回调和异步回执都复核会话与代际。
- `apps/client_flutter/lib/features/chat/chat_pane.dart`：当前群聊标题栏的定时消息入口。
- `apps/client_flutter/lib/features/chat/scheduled_messages_dialog.dart`：本地时间确认、发送者状态列表及确认取消。

## 本地验证

- `flutter analyze --no-pub` 无问题。
- 新增 `test/scheduled_messages_api_test.dart` 7 项与 `test/scheduled_messages_ui_test.dart` 11 项全部通过（共 18 项），相邻 `chat_reactions_ui_test.dart` 9 项同时通过（定向合跑 27 项）；基线同入口用例因缺失 RED，候选 GREEN。覆盖精确 wire（200 pending 回执/DELETE cancelled true）、非法/过期/被 Dart 规范化的日期、只读旧宿主、未知创建、取消确认、未知取消的已知 ID 重读、切换会话退役确认、私聊/离线禁用、375/768/1280 布局及 `已取消/未发送` 状态说明。
- 同场景 Android 目标 Flutter 捕获：基线与候选捕获各通过；图片为 390×844、DPR 1、浅色主题、SimHei/Material Icons 测试字体；不含真机、真实账号或线上网络。
- 本切片未跑全量 Flutter 套件（交集成方执行），不声明集成通过。
