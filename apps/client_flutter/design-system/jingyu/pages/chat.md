# 聊天方案（chat）
> 规范唯一来源 `../MASTER.md`；组件名只用第 8 节里有的（以 lead 的 s8 草稿为准）。范围：lib/features/chat/** 里的 ChatPane、消息操作、表情回应、置顶、收藏、语音、定时消息、看图，以及安卓「私聊我的 AI」页；会话列表和群聊对话框见 conversations.md，外壳见 shell.md。
> 原则：业务流程、回调、Key、测试依赖的文案和 tooltip 不动，只换外观和动效；另修草稿竞态和私聊页两项缺陷。task-3 shell-chat（shell-chat2 接手）。

## 1 盘点（现状）
- ChatPane：未选会话→StatusPanel「选择一个会话，开始聊天」。头部是 ListTile：窄屏返回键（tooltip「返回会话列表」）、会话名、连接状态（「已连接」/「离线 · 消息将加入待发送队列」）、按条件出现的定时消息、置顶消息、添加成员键；有待发送时显示「N 条待发送 · 联网后自动重试」（key queue-status）。
- 消息列表：ListView.builder（reverse，key 含会话和 openRevision）；空→StatusPanel「还没有消息」，说明分在线、离线。气泡左右对齐、最宽 560：撤回→「消息已撤回」；正文 SelectableText；图片→「查看图片」；语音→播放控件；收藏键；状态行（发送状态、「已编辑」、消息操作 IconButton）。
- 输入区：群聊有「提及 AI 并发送」；附件待发条（文件名、「取消附件」、「发送附件」需在线）；输入行（添加图片、添加文件、TextField key composer 1–5 行、发送键 IconButton.filled + Icons.send，忙或空时禁用）。输入框在 build 里按 model.draft 同步，忙时仍可输入（218de50）。首次发附件先问「允许 AI 读取附件？」。
- 消息操作面板：复制、编辑（需在线）、表情回应、管理置顶、撤回（需在线、24 小时内）、关闭；失效、离线各有提示。编辑、撤回走对话框（提交中进度条、不可返回，失败和结果未确认各有文案）。
- 表情回应面板：不可拖动关闭，保存中不可返回；读取中、确认中有进度条；FilterChip 的 tooltip 和语义带数量、我是否已回应；九种反馈在 liveRegion；刷新、关闭。置顶对话框：读取、空、失败、四种回执，置顶/取消置顶、刷新、关闭。
- 收藏键：「收藏消息」→「正在收藏…」→「已收藏」，或「收藏需联网」；被拒、未确认各有提示。语音：播放/取消加载/停止，状态在 liveRegion。
- 定时消息：推入整页（目标、说明、读取失败、编辑段、确认段、本人待发送列表 Card + ListTile、取消确认对话框）。
- 看图：失败 SnackBar「图片暂不可用；不会自动重试。」；对话框 key message-image-dialog：InteractiveViewer（1–4 倍）+ Image（BoxFit.contain，按 1080 缩放解码）+「关闭」（f61a2cc）。
- 私聊我的 AI：AppBar「私聊我的 AI」+ 菜单（欢迎与说明、模型设置、查看人格、会话同步）；摘要（模型、人格）；处理中插入进度条（内容下跳）；记录（你/AI 气泡，正文不可选）；空或受阻时的说明和按钮；notice 只靠底色区分错误；底部提示条 _ComposerHint + 输入框（处理中被禁用，会失焦）+ 发送键；会话失效时只剩一行居中文字。

## 2 布局
**窄屏（< 720；测试常用 390×844、375×812、360×640）**
- 头部仍是 ListTile，只换 leading 和样式：返回键 + JyAvatar（单聊 person、群聊 group、本人 AI 用 ai 光核）、会话名（titleMedium）、状态（JyStatusDot + 原文字）、右侧操作键。待发送数放在状态下方的小胶囊里（key queue-status 保留）。
- 消息区：气泡最宽取可用宽度的 80%，且不超过 560。同一方向连续的消息间距收到 JySpace.xs，相邻角用 JyShapes.bubble(joinedAbove/joinedBelow)；群聊里对方消息没有发送者字段，不合并。跨天或间隔超过 10 分钟插一枚居中时间胶囊（labelSmall、等宽数字，取 sentAt）。
- 气泡：己方 signal 实色；对方 JyTone.raised + 发丝线；本人 AI 的回复 raised，左上角一枚 ember 小光点。状态行在气泡下方，操作键 48dp。
- 输入区：悬浮 overlay 胶囊（左右内缩 JySpace.md，离底 JySpace.md 加安全区）：附件键 ×2、多行输入（随行数长高，圆角从 pill 变 JyRadius.xl）、圆形发送键。附件待发条和「提及 AI 并发送」放在胶囊上方的 raised 板里。
**宽屏（≥ 720；测试常用 1280×960、1280×720、800×600）**：ChatPane 在外壳的聊天板里（见 shell.md），无返回键；内容最宽 760 居中，输入胶囊同宽。
**私聊页**：顶部摘要板（JyPresenceOrb + 模型、人格两行）；处理中的进度线叠在摘要板下沿，不占高度；记录用聊天同款气泡（正文 SelectableText）；notice 用 JyBanner（带图标，限高 44/96 可滚动、显示 Scrollbar）；底部提示条 + 输入胶囊。会话失效换成 StatusPanel（标题「会话已失效」，说明「已隐藏私聊记录和输入，请返回后重新进入。」）。

## 3 用到的 lib/ui 组件
| 用途 | 组件 | 用法 |
|---|---|---|
| 头像、状态 | `JyAvatar`、`JyStatusDot` | 状态旁保留文字 |
| 气泡形状 | `JyShapes.bubble` | mine、joinedAbove、joinedBelow |
| 按压、长按 | `JyPressable` | 气泡 onLongPress 打开消息操作面板；按钮外层 onTap 为空，只加手感 |
| 新消息 | `JyEntrance` | 打开时前 8 条错开进场，之后只给新到的消息；滚回来的不再播 |
| 发送反馈 | `JySonarPulse` | trigger = 本页已发送条数，包住发送键 |
| 展开 | `JyExpand`、`JyChevron` | 附件待发条、待发送胶囊、私聊 notice；私聊提示条的箭头 |
| 弹窗 | `showJyDialog` | 看图、置顶、编辑、撤回、附件授权、私聊各对话框；builder 照旧返回 AlertDialog |
| 底部面板 | `showJySheet` | 消息操作（带拖动条）；表情回应把 isDismissible、enableDrag、showDragHandle 都传 false（同现在） |
| 进度 | `JyBusyIndicator` | 替换各处进度条，Key 挂在它上面，label 用现有语义文案（如「正在处理私聊请求」「正在确认回应」） |
| 状态、提示 | `StatusPanel`、`JyBanner` | 未选会话、无消息、私聊失效；私聊 notice |
| 定时消息页 | `JyGroup`、`JySectionHeader` | 分区成组；Card 和 ListTile 行保留 |
| 光核 | `JyPresenceOrb` | 私聊摘要板；thinking 只在处理中（原本就有进度） |
- 不用 JyStackDeck（消息不收成一摞）。Key、tooltip、语义都留在 Material 控件本身。

## 4 五类动效落点
| 类 | 落点 | 做法 |
|---|---|---|
| 触摸 | 气泡、发送键、附件键、头部操作键、面板里的行 | JyPressable；气泡长按开面板 |
| 展开 | 附件待发条、待发送胶囊、私聊 notice、私聊提示条 | JyExpand 展开淡入，消失时内容当帧换成空再收高度；提示条见第 7 节，箭头 JyChevron 转 180° |
| 缩放 | 看图和各对话框 | showJyDialog：0.94→1 + 淡入，退场 < 300ms；看图保留双指缩放 |
| 堆叠 | 无 | 连续气泡只收紧间距 |
| 过渡 | 新消息、切换会话、推入定时消息页和私聊页 | JyEntrance；宽屏换会话时消息区用 JySwitcher(fadeThrough) 淡入新列表（外壳那层不动，见 shell.md）；推入页用主题的 JyPageTransitionsBuilder |
- 发送时发送键放一圈 JySonarPulse。循环的只有原本就有的进度（JyBusyIndicator、私聊光核 thinking）。

## 5 浅色 / 深色与减少动效
- 颜色只取 JyPalette / ColorScheme：己方气泡 signal 及配对前景色，对方 raised + 发丝线，撤回文字 text2 斜体，错误 error；输入胶囊 overlay + JyShadows.floating。不写 Color(0x…)。证据：evidence/chat-{light,dark}-{wide,narrow}.png，另加操作面板、表情面板、看图、私聊页各一张。
- 减少动效交给 lib/ui：进场、声呐波、缩放、弹簧都关掉，只留 ≤ 120ms 淡入淡出；光核和进度换静态，仍读出 label；私聊提示条高度直接变。

## 6 草稿竞态（runtime.sendMessage）
结论：成立。在线发送时，从入队完成到网络 flush 结束，输入框一直显示已发出的文字；这期间打字，会把「已发文字 + 新字」写回草稿并落盘，下次发送就把旧文重复发出。入队（checkpoint）期间打字也是这样。
证据：
- runtime.dart:2611-2613 记下 text 和草稿版本，await enqueueTextDraft（定义在 packages/jingyu_client_kit/lib/src/shell_controller.dart:154）。
- runtime.dart:2615-2618 草稿和版本都没变才清空 _draft，清空后没有 notifyListeners；runtime.dart:2620 接着 await sessionShell.flush()。
- runtime.dart:1603-1616 _run 只在开始（1608）和 finally（1615）通知；runtime.dart 里没有 addListener 或 listen，1310-1311 的 15 秒重连定时器在 _busy 时跳过，所以 flush 期间没有通知去刷新输入框（除非别的异步操作碰巧完成）。
- chat_pane.dart:653-656 输入框只在 build 时按 model.draft 重设；chat_pane.dart:996 onChanged 调 updateDraft；chat_pane.dart:1006 忙时只禁发送键（218de50）。runtime.dart:2566-2585 updateDraft 写 _draft、版本 +1、saveDraft、通知。
- 提及发送同样：runtime.dart:2743-2749（2746 清空不通知，2749 await flush）。
- 入队期间改过就保留草稿是有意的（runtime_text_send_test:109 锁定）；毛病在界面没先清空，用户是在旧文后面接着打字。
修法（runtime.dart 是共享文件，task-7 动手前先告诉 lead）：
- 推荐：发送一开始就清空 _draft 并通知，记下 text 和版本号；入队成功后不再动草稿；入队失败时，期间没输入就放回原文（持久化草稿本来没动），已输入新字就把原文接在新字前面并保存。两个窗口里输入框都已是空的，期间输入的都是新草稿；:20、:53、:85、:109 的断言照旧成立，持久化时机不变。提及发送照此改。
- 最小：在 2618、2746 清空后立即 notifyListeners() 再 flush；只修网络窗口，入队窗口仍在。
测试思路（runtime_text_send_test 新增）：① 在线、卡住宿主提交：入队后 draft 已空且收到通知；此时 updateDraft('新字')，放行后 draft 和持久化草稿都是「新字」，只提交 1 次且是原文。② 卡住 checkpoint（同 :109 的钩子）：期间 draft 已空。③ checkpoint 失败：草稿放回原文、未入队。界面：卡住 flush 时 composer 为空、焦点还在。

## 7 私聊页两项（lead 18:37，task-7 一起修）
1. 处理中输入框失焦：android_private_ai_screen.dart:500 的 enabled 去掉 !_working，只禁发送键（同 218de50）。配套：页内发送成功时只在 _draft.text == draft 才清空（:142-143），可输入后会留下「旧文 + 新字」，所以同样改成发送一开始就清空；失败时输入框仍空就放回原文，已有新字就把原文接在前面，让「未完成发送，草稿仍在」成立。
2. 提示条 _ComposerHint（:559 起）：保留 Material 祖先、InkWell（key private-ai-composer-hint-toggle）、≥ 48dp、Semantics(button, expanded)；外加 JyPressable（onTap 为空），箭头换 JyChevron。展开仍是同一个 Text（key private-ai-composer-hint，maxLines 1→null，测试读它），外面套限高（compact 72，否则 144）+ Scrollbar + 滚动；高度过渡见问题 2。

## 8 必须保留的测试契约
- 两个已有修复：看图保持比例和双指缩放（f61a2cc：按 1080 缩放解码、BoxFit.contain、InteractiveViewer 1–4 倍；测试量 RawImage 宽高比）；模型忙时输入框不失焦（218de50：忙时 TextField 仍可用、键盘不收，只禁发送键）。
- 消息列表仍是 ChatPane 里的 ListView（reverse、现有 key）；发送键仍是带 Icons.send 的 IconButton；Key 挂在原控件上（测试读 onPressed），JyPressable 包在外面。
- 操作面板和对话框不新增消息正文预览（测试按正文找消息，多一份就 ambiguous）；退场 < 300ms；返回键先由面板和对话框处理。
逐文件（反引号里的每一项都在该测试文件里 grep 到原文）：
- **chat_history_opening_test**：类型 `ChatPane` `ListView`；文案 `还没有消息`；tooltip `返回会话列表`
- **composer_busy_focus_test**：Key `composer`；类型 `EditableText` `IconButton`；忙时保持焦点、键盘可见
- **ui_test**：Key `composer`；tooltip `发送` `返回会话列表` `添加图片` `添加文件`；文案 `允许 AI 读取附件？` `允许并继续` `暂不允许` `发送附件` `取消附件`
- **ui_refresh_states_test**：类型 `StatusPanel`；文案 `选择一个会话，开始聊天` `发一条消息，开始这段对话。` `离线时发出的文字消息会先排队，联网后会自动尝试发送。`
- **share_target_confirmation_test**：Key `composer`；tooltip `发送`
- **message_actions_ui_test**：Key `message-actions-mine` `message-actions-peer` `message-actions-pending` `message-actions-removed` `message-action-copy` `message-action-edit` `message-action-recall` `message-actions-sheet-close` `edit-message-input` `message-edited-mine` `message-recalled-removed`；文案 `已复制` `消息已编辑` `消息已撤回` `已编辑`；类型 `ListTile` `TextField`
- **chat_reactions_ui_test**：Key `message-reactions-sheet` `message-action-reactions` `message-reaction-heart` `message-reaction-thumbsUp` `message-reactions-refresh` `message-reactions-close`
- **chat_pins_ui_test**：Key `open-chat-pins` `message-action-pin` `chat-pins-loading` `chat-pins-empty` `chat-pins-read-failure` `chat-pins-refresh` `chat-pin-confirm` `chat-pin-confirmed` `chat-pin-refused` `chat-pin-unknown` `close-chat-pins`；文案 `置顶` `取消置顶` `连接宿主后才能查看或修改置顶。`
- **message_favorite_action_test**：Key `save-favorite-msg` `save-favorite-pending` `save-favorite-recalled`；文案 `已收藏` `正在收藏…` `宿主拒绝收藏。` `收藏结果未确认，请到「我的收藏」核对。`；类型 `TextButton`
- **message_image_preview_ui_test**：Key `message-image-dialog` `open-image-message-image` `open-image-message-text`；文案 `图片暂不可用` `关闭`；类型 `RawImage`
- **voice_message_playback_test**：文案 `正在加载语音…`；类型 `ChatPane` `TextButton`
- **runtime_voice_playback_test**：文案 `正在加载语音…`
- **scheduled_messages_ui_test**：Key `open-scheduled-messages` `schedule-compose` `schedule-text` `schedule-review` `schedule-confirm` `schedule-loading` `schedule-retired` `schedule-read-unavailable` `schedule-list-refresh` `schedule-status-legend` `schedule-cancel-dismiss` `schedule-confirm-cancel`
- **mention_message_ui_test**：Key `mention-ai-message`；文案 `取消`
- **group_chat_ui_test**：Key `add-group-member`（头部「添加成员」）
- **android_private_ai_screen_test**：文案 `私聊我的 AI` `会话已失效` `欢迎与说明` `模型设置` `查看人格` `会话同步` `直连模型服务 · 不在本机运行大模型` `待同步（仅本机）` `已同步 #7`；类型 `Material` `IconButton` `TextField` `AlertDialog` `SwitchListTile`；提示条的展开语义、≥ 48dp、Material 祖先；处理中发送键 onPressed 为空

## 9 风险
1. 长按和选词：正文是 SelectableText，长按会被选词抢走。正文长按保持选词，并在选择菜单里加「消息操作」；气泡留白、状态行、图片和语音行长按开面板；「消息操作」IconButton 保留。
2. 新文字（时间胶囊、菜单项）可能撞测试文案：加之前 grep。
3. JyEntrance、JySwitcher 期间控件必须已在树上且可点：测试多在 pump 一帧后就点消息。
4. 360 宽 + 大字号：三颗 48dp 键后输入框约剩 160 宽，靠多行长高，不截断。
5. 表情面板用 showJySheet 时，默认的拖动条和可拖动要显式关掉，否则保存中可被拖走。
6. 私聊页：处理中可输入、发送即清空、提示条展开后多出的滚动区、气泡改 SelectableText（会多出 EditableText），都可能碰到现有断言；先跑整份 android_private_ai_screen_test。

## 10 问题（不等答复，先按建议做）
1. 草稿竞态用推荐修法（发送开始就清空），runtime.dart 由我在 task-7 改并补测试，可以吗？
2. 私聊提示条的高度过渡：lib/ui 没有尺寸过渡组件（JyExpand 只从 0 展开）。建议用 AnimatedSize 配 JyDurations.standard、JyCurves.enter（减少动效时为 0），或由 foundation 给 JyExpand 加「收起时保留一行」。
3. MASTER 要长按面板里放一排表情；表情回应要先读宿主状态，建议保留独立的表情面板，操作面板第一行就是「表情回应」。
4. 本人 AI 会话用哪个字段判断（ai 光核头像、ember 点）？没有现成字段就先不区分。
