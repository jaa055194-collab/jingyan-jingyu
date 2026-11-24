# 会话列表方案（conversations）
> 规范唯一来源 `../MASTER.md`；组件名只用第 8 节里有的（以 lead 的 s8 草稿为准）。范围：lib/features/chat/chat_pane.dart 里的 ConversationList、_ConversationsStatus 和群聊对话框 _GroupActionDialog（创建群聊、添加成员、提及 AI 三种模式，后两种从聊天页打开），以及 lib/app/conversation_mapping.dart；外壳见 shell.md，聊天见 chat.md。
> 原则：回调、Key、测试依赖的文案和控件类型不动，只换外观和动效；读取中、伙伴卡、时间三项要新接口，没有接口时照现在显示。task-3 shell-chat（shell-chat2 接手）。

## 1 盘点（现状：chat_pane.dart 15–105 列表，109–160 空态，162 起对话框）
- 结构：Column[「创建群聊」FilledButton.icon（key create-group；已登录、在线、未锁定、不忙才可用；四周 16 内边距，独占一行）→「刷新会话」TextButton.icon（key refresh-conversations；已登录、未锁定、不忙）→ 有收藏入口时「我的收藏」TextButton.icon（key open-favorites）→ Expanded（列表或空态）]。三个键竖排，占掉约 160 高。
- 行：ListView 里的 ListTile（key ValueKey(会话 id)、selected、CircleAvatar 显示标题首字或「?」、标题、预览单行省略、未读 Badge 数字；忙碌时 onTap 为空）。数据只有 id、title、preview、unread、kind（direct / group / unknown）、ownerAccountId，没有时间、置顶和发送者。
- 空态（StatusPanel fill，取第一个成立的）：未登录 conversations-signed-out「尚未连接宿主」；离线 conversations-offline「暂时离线」；有错误 conversations-error「没有可显示的会话」+ OutlinedButton「重新读取」（key conversations-retry，锁定或忙碌时禁用）；否则 conversations-empty「暂无会话」。读取中和真的为空分不出来（ShellViewModel 没有「已读取」标志）。
- 创建群聊：弹出 _GroupActionDialog；关闭后若选中的会话变了且没有错误，调 onSelected 打开新群聊。
- _GroupActionDialog：失效时换成「会话已锁定或登录已变化」+「关闭」；否则 PopScope（提交中不可返回）+ AlertDialog：标题（创建群聊 / 添加群成员 / 提及 AI 并发送本条消息）、说明、提及时 2 行草稿、TextFormField（group-name / member-account-id / mention-ai-id，自动聚焦）、校验（「请输入1–100个字符的群名」「请输入有效账户 ID」）、未授权提示、失败红字（默认「会话已变化，请重新操作」）、提交中进度条；「取消」+ FilledButton（confirm-create-group「创建」/ confirm-add-member「添加」/ confirm-mention-message「确认提及并发送」）。
- 状态：未登录、离线、读取失败、空、有会话、忙碌（行不可点）、对话框提交中、对话框失效。置顶：会话没有置顶字段，MASTER 第 9 节的伙伴卡是唯一的置顶。

## 2 布局
**窄屏（< 720；测试常用 390×844、375×812、360×640，截图 412 宽）**
- 顶部一排紧凑操作：Wrap（项距、行距 JySpace.sm，左右 JySpace.lg，上 JySpace.sm），依次「创建群聊」「刷新会话」「我的收藏」，类型和启用条件不变；放不下（360 宽、大字号）就换行，不横向滚动。比现在省约 100 高。
- 伙伴卡（有本人 AI 会话时，见问题 2）：JySlab(tone: raised)，左边 JyPresenceOrb(size 56)，右边名字（titleMedium）和一句状态（最后一条预览，单行）。卡里仍是那个会话的 ListTile（Key 不变）；这个会话从下面的列表里拿掉，不重复出现。
- 行：ListTile 最小高 64（JySpace.rowMinHeight），左右内缩 JySpace.sm，形状 JyShapes.rounded(JyRadius.md)。leading JyAvatar(size 44；group→group，其余 person；label 只传首字或「?」，同现在)；标题 titleMedium，有未读时加粗，不限行数（同现在，大字号不截断）；预览 bodyMedium、text2、单行省略；trailing 竖排：时间（有字段时，labelSmall、text3、等宽数字）在上，JyBadge(count) 在下。
- 选中：背景 signalSoft，前缘一条 3dp 的 signal 竖条（不只靠颜色）；忙碌时行不可点，按压反馈也关掉。
- 读取中（有接口时，见问题 1）：3 条静态骨架行 + 一行「正在读取会话」；不闪烁、不循环（忙碌进度由外壳那条线显示）。
**宽屏（≥ 720；测试常用 1280×960、1280×720、800×600，截图 1280 宽）**：放在外壳的会话板里（宽 280，窗口 ≥ 1024 时 320，见 shell.md），结构同窄屏；280 宽时操作行排成两行；选中行常亮。

## 3 用到的 lib/ui 组件
| 用途 | 组件 | 用法 |
|---|---|---|
| 头像 | `JyAvatar` | size 44；群聊 kind group（两枚叠放）；替换 CircleAvatar |
| 未读 | `JyBadge(count)` | 替换 Badge，数字照旧显示 |
| 伙伴卡 | `JySlab`（tone raised）+ `JyPresenceOrb` | 离线时 offline，其余 idle；不循环 |
| 手感 | `JyPressable`（onTap 为空） | 包会话行、伙伴卡、操作键、对话框按钮；忙碌时 enabled 为 false |
| 进场 | `JyEntrance(index)` | 列表第一次出现时前 8 行 |
| 空、离线、失败 | `StatusPanel(fill: true)` | foundation 负责；Key、文案、重新读取键不变 |
| 群聊对话框 | `showJyDialog` | builder 照旧返回 AlertDialog（三种模式和失效态） |
| 对话框提交中 | `JyBusyIndicator(linear: true)` | label 分别为「正在创建群聊」「正在添加成员」「正在发送提及」 |
| 对话框失败提示 | `JyBanner(kind: error)` | 不传 onClose；有图标，不只靠红字 |
| 对话框里的出现 | `JyExpand` | 失败提示、提交进度条 |
- 不用 JyStackDeck：会话不是同类通知，不收成一摞。Key、tooltip、语义都留在 Material 控件本身。

## 4 五类动效落点
| 类 | 落点 | 做法 |
|---|---|---|
| 触摸 | 会话行、伙伴卡、操作键、对话框按钮 | JyPressable，只加手感；onTap 留在 ListTile 和按钮上 |
| 展开 | 对话框的失败提示、提交进度条 | JyExpand 展开并淡入 |
| 缩放 | 群聊对话框（三种模式） | showJyDialog：0.94→1 + 淡入，退场 < 300ms |
| 堆叠 | 群聊头像 | JyAvatar(kind: group) 两枚小头像叠放，静态 |
| 过渡 | 列表第一次出现；打开会话 | 前 8 行 JyEntrance 错开 30ms，只在第一次构建时播放，之后刷新、重排都不再动；打开会话的过渡归外壳（shell.md 第 4 节） |
- 列表和空态之间直接切换：StatusPanel 自带淡入，外面再包一层淡入会让第一帧读不到语义。没有循环动画。

## 5 浅色 / 深色与减少动效
- 颜色只取 JyPalette / ColorScheme：行透明，铺在会话板上；选中 signalSoft + signal 竖条；标题 onSurface，预览 text2，时间 text3；未读徽标由 JyBadge 取色；伙伴卡和骨架行 raised。不写 Color(0x…)。
- 证据：evidence/conversations-{light,dark}-{wide,narrow}.png，另加空、离线、读取失败、群聊对话框各一张。
- 减少动效：不做进场，直接显示；对话框只淡入（≤ 120ms）；按压只留高亮。

## 6 必须保留的测试契约
- ConversationList(model, onSelected) 的构造参数不变（ui_refresh_states_test 直接构造它）。
- 会话行仍是 ListTile，Key 为 ValueKey(会话 id)，onTap 在 ListTile 上（测试按 Key 或标题文字点按会话行）；忙碌时 onTap 为空。
- 会话标题全屏只出现一次：伙伴卡是把会话移上去，不是复制；头像只画首字。
- 三个操作键各出现一次，类型不变：create-group 是 FilledButton，refresh-conversations、open-favorites 是 TextButton。
- 空态顺序不变，新增的「读取中」排在「读取失败」之后、「暂无会话」之前；重新读取键是 OutlinedButton，锁定或忙碌时禁用。
- 群聊对话框：三种模式的 Key、标签、校验、失败文案、提交中不可返回、关闭后打开新群聊，都不变。
逐文件（反引号里的每一项都在该测试文件里 grep 到原文）：
- **ui_refresh_states_test**：类型 `ConversationList` `StatusPanel` `OutlinedButton`；Key `conversations-signed-out` `conversations-offline` `conversations-error` `conversations-empty` `conversations-retry`；文案 `尚未连接宿主` `登录宿主后，这里会显示你的聊天。` `暂时离线` `恢复连接后，会显示你的聊天。` `没有可显示的会话` `暂无会话` `可以创建群聊，或等好友发来消息。`
- **group_chat_ui_test**：Key `create-group` `refresh-conversations` `group-name` `confirm-create-group` `add-group-member` `member-account-id` `confirm-add-member`；文案 `取消` `关闭` `还没有消息`；类型 `FilledButton`
- **mention_message_ui_test**：Key `mention-ai-id` `confirm-mention-message`；文案 `取消`
- **favorites_read_capture_test**：Key `create-group` `refresh-conversations` `open-favorites`（前两个 findsOneWidget）
- **chat_favorites_route_test**：Key `open-favorites`
- **ui_test**：文案 `小鲸` `好友`（默认 800×600 宽屏下按会话标题点按会话行）

## 7 风险
1. 标题重复：伙伴卡、头像都可能再显示一次会话名。伙伴卡是移走会话、头像只画首字；宽屏聊天头部本来就显示会话名，不再新增第三处。
2. 进场动画：JyEntrance 第一帧透明度为 0，读屏在这一帧读不到；点按不受透明度影响，位移只有 8，测试 pump 一帧后点行仍能点中。
3. 操作行：360 宽、大字号时三个键放不下，用 Wrap 换行；不用横向滚动（多一个 Scrollable 会破坏按 Scrollable 找控件的测试）。
4. 新接口：读取中、伙伴卡、时间都要改共享文件（ShellViewModel、ShellConversation、runtime），只做加法、带默认值。实现 ShellViewModel 的两个假模型（settings_own_ai_direct_test、world_screen_test）走 noSuchMethod；实现前确认它们不渲染会话列表，新成员只在列表里读。
5. 280 宽的会话板：时间和徽标占掉右侧约 48，标题可换行，预览单行省略。
6. 新文案「正在创建群聊」「正在添加成员」「正在发送提及」「正在读取会话」已在 lib、test、evidence 里 grep，没有重名。

## 8 问题（不等答复，先按建议做）
1. 读取中：建议 ShellViewModel 加 bool get conversationsLoaded => true（默认 true，现有假模型照旧），runtime 在当前账号第一次读取会话结束（成功或失败）前返回 false。可以吗？runtime 的改动放进 task-7，动手前先告诉你。
2. 伙伴卡：要知道哪个会话是本人 AI。建议 ShellViewModel 加 String? get partnerConversationId => null；没有就不显示伙伴卡（与 chat.md 第 10 节第 4 条是同一件事）。
3. 时间：ShellConversation 没有时间字段。宿主的会话数据里若有最后活动时间，就在 conversation_mapping.dart 映射，ShellConversation 加可空的可选参数（测试里 16 处构造不受影响）；没有就不显示时间。
4. MASTER 第 7 节第 3 条说打开会话用缩放，第 5 条说窄屏列表和聊天之间用共享轴；shell.md 按第 5 条做，要改成缩放由外壳改。
