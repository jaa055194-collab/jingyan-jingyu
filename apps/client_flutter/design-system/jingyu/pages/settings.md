# 设置页方案（settings）
> 规范唯一来源 `../MASTER.md`；组件签名照 MASTER 第 8 节（含 lead 20:15 补充）。范围 `lib/features/settings/**`；解锁页 UnlockScreen 见 `onboarding.md`。
> 原则：只换外观和动效；业务流程、回调结构、Key、测试依赖的文案和 tooltip 都不动。

## 1 盘点（现状）
- 设置主页 `SettingsScreen`：一个 ListView，分区依次为 隐私与安全（应用锁、PIN、隐藏通知正文）→ 通用 → 外观（主题「浅色」「深色」、字体大小）→ 开发者（调试入口）→ 我的 AI（最后）。自带返回钮 tooltip「返回」，调 `onBack`。
- 弹窗：PIN 设置（`new-pin`、「保存」）、`_OwnAiDirectDialog`（`own-ai-direct-confirm`，提交中有进度条）、`_CreateOwnAiDialog`。
- 推入页：设备会话（列表、确认区、提交进度条）、安卓 AI 目录、规则问候设置（`global-stop` `global-confirm` `global-cancel`）、开发者各页。
- 状态：加载、空、错误、离线、提交中、失效（换会话、锁定、断开后整块内容换成失效态）。

## 2 布局
- SettingsScreen 内只有一个 Scrollable：主 ListView。每个分组是它的独立子项（懒加载；Windows 首屏不能构建「我的 AI」），不把整页包进一个 Column。
- 顶部新增账户卡「我的账户」：显示名 + 宿主状态「已连接宿主」/「未连接到宿主」，只读 ShellViewModel 已有数据。账号 ID 用普通 Text，不用 SelectableText，也不用「账号 ID：」前缀。卡高 ≤ 88，保证 800×600 下「应用锁」「隐藏通知正文」不滚动就能点到。
- 分组 = 小标题 + 圆角卡片；行仍是 ListTile / SwitchListTile 原控件；断开、删除类放分组末尾，用 error 色。
- 外观分区顺序：主题 → 字体大小 → 减少动效（新增）。开发者分区默认展开、可收起，展开状态存在 SettingsScreen 的 State 里（子项懒加载会被回收）。我的 AI 永远在最后。
- 宽屏内容列限宽居中（按 MASTER 断点），窄屏满宽。推入页 Scaffold + AppBar，保留自带 BackButton。
- 主页不放 SelectableText、内联 TextField、横向滚动列表；要输入的都进弹窗（PIN 继续用弹窗）。

## 3 用到的 lib/ui 组件
| 用途 | 组件 | 用法 |
|---|---|---|
| 分组卡 | `JyGroup` | 标题 + 行；Key 不挂在包装上 |
| 离线/错误横幅 | `JyBanner` | 放在主列表第一个子项里 |
| 空 / 错 / 失效 | `StatusPanel` | foundation 负责，本页只调用 |
| 状态切换 | `JySwitcher` | 换 key 时旧子树当帧移除，只给新子树进场 |
| 展开收起 | `JyExpand` | 只用于开发者分区 |
| 弹窗 | `showJyDialog`（`JyDialogRoute`） | builder 照旧返回 AlertDialog，内容长时 `scrollable: true` |
| 手感 | `JyPressable` | onTap 为空，包在 ListTile / 按钮外，只加按下缩放和高亮 |
| 进度 | `JyBusyIndicator(label, linear, value)` | 替换现有 Linear / Circular 进度条 |
- 不用 `JyStackDeck`（测试要点第 2、3 行，叠卡只有第一张可交互）；`showJySheet` 本页暂不用。
- Key、tooltip、语义都留在 Material 控件本身。

## 4 五类动效落点
| 类 | 落点 | 做法 |
|---|---|---|
| 页面转场 | 进入设备会话、安卓 AI 目录、规则问候、开发者页 | 用主题统一转场（≤360ms），本页不自定义 Route；问候页 GET 在 initState，不等转场 |
| 状态切换 | 加载→内容/空/错；问候失效态；设备确认区出现/消失；直连弹窗 表单→提交中→结果 | JySwitcher；回退方向 `reverse: true` |
| 展开收起 | 开发者分区 | JyExpand，默认展开 |
| 弹层 | PIN、直连我的 AI、创建我的 AI、删除/断开确认 | showJyDialog（0.94→1 + 淡入），退场 < 300ms |
| 按压反馈 | 可点的行、账户卡、主按钮 | JyPressable 包裹，不改语义 |
- 循环动画只有进度（JyBusyIndicator）；页面不加常驻动画，免得 pumpAndSettle 卡住。

## 5 浅色 / 深色
- 颜色、圆角、间距全取主题 token / ColorScheme，不写色值：卡片 surfaceContainer 系，正文 onSurface，次要 onSurfaceVariant，危险 error。深色不加阴影，层次靠 token。
- 主题选项文案「浅色」「深色」不变，切换后整页即时换色。
- 证据：两种主题各截宽、窄两张，放 `evidence/settings-{light,dark}-{wide,narrow}.png`。

## 6 减少动效
- 生效条件：系统 `disableAnimations` 为真，或应用内开关打开。页面不自己分支，交给 lib/ui 组件按 MASTER 第 7 节处理（如循环换静态 + 文字）。
- 开关：外观分区新增 SwitchListTile「减少动效」，Key `reduce-motion`；系统已开启时显示为开且禁用，副标题「系统已开启」。
- 偏好存哪（共享文件，只做加法，实现前再和 lead 确认）：
  - runtime：新增持久化成员 `reduceMotion` + `setReduceMotion(bool)`，与主题、字体大小存在同一处，默认 false。
  - ShellViewModel：新增 `bool get reduceMotion` + `Future<void> setReduceMotion(bool)`，写入 runtime 后 notifyListeners。
- 生效方式（建议）：根 MaterialApp 的 builder 里 `MediaQuery.copyWith(disableAnimations: 系统 || 偏好)`；lib/ui 组件和 StatusPanel 只读 `MediaQuery.disableAnimationsOf`，不关心来源。
- 本页表现：切换、展开、弹窗直接出现；进度换静态条 + 文字（label 用现有提交文案）；按压只留高亮。

## 7 字体大小（保留提交 2036f56 的行为）
- 拖动只预览（onChanged 改本地值），松手 onChangeEnd 保存一次；正在保存时又松手 → 等空闲后保存最新值。
- 读屏读百分比：Slider 语义 value 为「N%」；整页只有这一个 value 以 % 结尾的语义节点（预览文字不带 %）。
- 改版只换外观：两端放小号 / 大号「A」，下方一行实时预览；回调、Key、保存时机都不改。

## 8 必须保留的测试契约
手写要点（大文件只摘本页相关）：
- `ui_test.dart`：点「设置」后不滚动直接点「应用锁」「隐藏通知正文」（800×600 首屏）；PIN 弹窗 `new-pin`，「保存」唯一；`scrollUntilVisible('深色')` 取 SettingsScreen 下 Scrollable 的 `.single`；`pageBack()` 要唯一 tooltip `Back`；world 页 SelectableText `账号 ID：$id` 只能有它一个。
- 安卓「我的 AI」测试：Windows 首屏 `find.text('我的 AI')` findsNothing；`Jo · 未停用` 是一个 Text；`widgetWithText(ListTile, 'Jo')` findsNothing（Windows 行别拆成 ListTile(title: 名)）。
- 开发者分组测试：Key `open-module-test` `world-status` `voice-profile` `ai-config` `lifecycle-status` `ai-config-write`；pageBack 回设置后开发者分区仍展开。
- `owner_rule_greeting_settings_panel_test.dart`：换会话 pumpAndSettle 后 confirm / stop 都消失；进页 pump() + pump(400ms) 已发出 GET。
- `device_sessions_screen_test.dart`：900×1600；提交中有进度条，测试不用 pumpAndSettle；`device-confirm-cancel`。
- owner_chat_entry 测试：关弹窗后 pump(300ms) 弹窗已移除 → 退场必须 < 300ms。
- `ui_refresh_states_test.dart`：disableAnimations 下 StatusPanel 不包 `TweenAnimationBuilder<double>`。
逐文件摘录（Key / 文案 / tooltip / byType；提交前由脚本从 test/ 抽取，原样保留）：
- `device_sessions_api_test.dart`：无直接字面量，见上方要点
- `device_sessions_screen_test.dart`：Key `device-confirm-submit` `device-sessions-unbound` `device-sessions-refresh` `device-row-device-a` `device-row-device-b` `device-current-device-b` `device-current-device-a` `device-current-unknown` `device-sessions-empty` `device-sessions-denied` `device-sessions-unavailable` `device-sessions-malformed` `device-revoke-device-a` `device-revoke-device-b` `device-confirm-panel` `device-confirm-cancel` `device-sessions-notice` `device-failure-device-a` `device-confirm-name` `device-row-private-device` `device-sessions-discarded` `open-device-sessions`；文案 「工作站」「手机」「本机」「设备：工作站（device-a）」「私密设备名」「旧会话设备名」「2026-11-18T02:03:04.000Z」「secret」「secret detail」「已远程下线：工作站」「已远程下线」「不会自动重试」「未确认下线」；byType `Card` `DeviceSessionsScreen`
- `owner_chat_entry_test.dart`：Key `own-ai-direct-chat-ai-owner` `own-ai-direct-refresh-ai-owner` `composer` `own-ai-direct-toggle-ai-owner` `open-world-status` `own-ai-direct-chat-ai-other`；文案 「此私聊在当前会话列表中不可见。」「确认撤销私聊授权」「取消」「世界状态」「联系人」「正在核对私聊…」；tooltip 「设置」；byType `AlertDialog` `SettingsScreen` `WorldStatusScreen` `Scrollable` `NavigationRail`
- `owner_rule_greeting_settings_panel_test.dart`：Key `owner-rule-greeting-global-stop` `owner-rule-greeting-global-confirm` `open-owner-rule-greeting-global` `owner-rule-greeting-offset` `owner-rule-greeting-global-unknown`；文案 「未授权规则问候」「opaque」
- `settings_attachment_entries_test.dart`：Key `open-attachments-list` `attachments-unbound` `open-attachment-viewer` `attachment-unbound`；文案 「附件列表」「附件元数据」
- `settings_chat_model_picker_test.dart`：文案 「聊天绑定已保存」「catalog-model」「stale-a」「current-a」「old-choice」「stale-ai-catalog」「current-choice」「late-locked-model」「not-displayable」「untrusted-detail」；tooltip 「设置」；byType `Scrollable`
- `settings_developer_groups_test.dart`：Key `open-ai-config-write`；文案 「只读检查」「AI 运行配置编辑」；byType `screenType` `SettingsScreen`
- `settings_font_scale_test.dart`：Key `font-scale-preview`；文案 「字体大小 · ${(saved * 100).round()}%」
- `settings_message_search_entry_test.dart`：Key `open-message-search` `search-query` `search-submit` `search-hit-private-hit` `search-unbound`；文案 「消息搜索」；byType `SearchScreen` `SettingsScreen`
- `settings_model_diagnostics_test.dart`：Key `open-model-diagnostics` `diagnostics-catalog-provider-input` `diagnostics-catalog-load` `open-ai-config` `model-diagnostics-unbound`；文案 「· private-model-fixture」「模型能力与预算诊断」「不会自动重试」「api_key」「****」；byType `ModelDiagnosticsScreen` `SettingsScreen`
- `settings_own_ai_direct_test.dart`：Key `own-ai-direct-refresh-ai-account` `own-ai-direct-toggle-ai-account` `own-ai-direct-confirm` `own-ai-create`；文案 「ai-account」「授权操作已失效」「取消」「Nora」「当前单条文本」「历史、记忆」「已保存的人格」「profile-id」「尚未确认」「结果未确认」「保留已有历史」「请关闭后刷新状态」；byType `Scrollable` `AlertDialog`
- `settings_own_ai_test.dart`：Key `own-ai-refresh` `own-ai-create` `own-ai-name` `own-ai-confirm`；文案 「canonical-ai」「private-same-account」「private-name」「回复仍需宿主配置」
- `settings_persona_history_route_test.dart`：文案 「初始化」「2026-02-05」「synthetic-error-opaque」；tooltip 「设置」；byType `Scrollable`
- `settings_voice_call_list_test.dart`：Key `open-voice-call-list` `voice-call-list-unbound`；文案 「语音通话列表」
- `ui_refresh_states_test.dart`：Key `conversations-retry` `conversations-signed-out` `conversations-offline` `conversations-error` `conversations-empty` `composer`；文案 「尚未连接宿主」「登录宿主后，这里会显示你的聊天。」「暂时离线」「恢复连接后，会显示你的聊天。」「暂无会话」「没有可显示的会话」「可以创建群聊，或等好友发来消息。」「选择一个会话，开始聊天」「还没有消息」「发一条消息，开始这段对话。」「没能读取」「小鲸」「自动发送」；语义 「没能读取」；byType `StatusPanel` `TweenAnimationBuilder<double>` `Opacity` `MaterialApp`

## 9 风险
- 账户卡挤掉首屏 → 卡高 ≤ 88，实现后先跑 ui_test 设置段。
- 多一个 Scrollable 就让 `.single` 失败（SelectableText、TextField、横向列表都算）。
- JyExpand 收起和弹窗退场期间子树还在树上 → 测试要求当帧消失的地方用 JySwitcher 或直接换。
- 新文案撞测试：「我的账户」「已连接宿主」「未连接到宿主」「减少动效」「系统已开启」已 grep 不撞；后加的同样先 grep。
- 常驻动画让 pumpAndSettle 超时 → 不加。
- 共享文件（ShellViewModel、runtime、根 MaterialApp）只做加法，先问 lead。

## 10 待确认（不等答复，先按建议做）
1. 减少动效偏好的成员名和存储位置（建议与字体大小同处，默认 false）。
2. 根 MaterialApp.builder 覆盖 disableAnimations 由谁改。
3. JyDialogRoute 退场时长是否 < 300ms。
4. 账户卡的宿主状态读哪个现有字段；没有就只显示名字。
