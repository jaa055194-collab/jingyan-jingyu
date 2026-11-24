# 外壳方案（shell）
> 规范唯一来源 `../MASTER.md`；组件名只用第 8 节里有的（以 lead 的 s8 草稿为准）。范围：lib/app/shell_app.dart、lib/main.dart、lib/features/share/**；会话列表见 conversations.md，聊天见 chat.md。
> 原则：外壳的状态（destination、settings、mobileChat、_chatOpenRevision、导航代数）和回调结构不动，只换外观和动效，再补上系统返回键。task-3 shell-chat（shell-chat2 接手）。

## 1 盘点（现状：shell_app.dart 584 行，shared_text_panel.dart 306 行）
- 根 WhaleChatApp：MaterialApp「鲸言鲸语」，builder 把系统字号乘以 model.fontScale（2036f56 的字体大小靠它）；home 依次是：未就绪→居中转圈；已锁→UnlockScreen；未完成引导→OnboardingScreen；否则进外壳 _ShellHome。
- 外壳状态：destination 0–4（聊天/联系人/动态/收件箱/世界）、settings、mobileChat、_chatOpenRevision；_NavigationIntentObserver 在路由变化（push、pop、remove、replace、返回手势）时给导航代数 +1，分享面板和前台提醒靠它判断失效。
- 头部 AppBar：标题是当前目的地名，设置里是「鲸言鲸语」；右侧「在线」/「离线」文字和设置 IconButton（tooltip「设置」，再点一次关闭）。
- 宽屏（maxWidth ≥ 720）：NavigationRail（labelType all）+ 竖分隔线；聊天页 = 会话列表（宽 280）+ 分隔线 + ChatPane。窄屏：底部 NavigationBar；聊天页在会话列表和 ChatPane（mobileChat）之间切换；打开聊天或设置时隐藏底栏。
- 内容区上方依次：分享面板（已登录、未锁定、有分享时）→ 忙碌进度条（出现时内容下跳）→ 错误条（errorContainer，liveRegion，关闭键 tooltip「关闭提示」）→ 前台消息提醒 ForegroundMessageNotice（social 的组件，key 为 ValueKey(destination)，只在现有条件下出现）。
- 其他：模块未开放的空页（文案 + module-status-<id> 胶囊）；openOwnAiChat 的 4 条 SnackBar；openWorldSetup 推入 route-world-setup 或 route-login。
- 分享：面板（预览 3 行、提示、「选择会话」「丢弃分享」，忙碌时禁用）→「选择接收会话」对话框（单选列表、草稿状态提示、「取消」「加入草稿」；提交中转圈、不可返回；状态失效时换成「分享状态已变化」）。
- 状态：启动中、锁定、引导、在线/离线、忙碌、错误、有分享、有前台提醒、设置打开、窄屏聊天打开。
- 缺陷：外壳没有返回处理（lib 里 PopScope 只在各弹窗和面板里）；窄屏聊天和设置都只是 setState 状态，按系统返回直接退出应用。

## 2 布局
**窄屏（< 720；测试常用 390×844、375×812、360×640）**
- 底色铺满，头部不再是色带。头部仍用 AppBar，高 56 不变：左边大标题（headlineSmall，文字同现在），右边状态胶囊（JyStatusDot +「在线」/「离线」，不只靠颜色）和设置键（IconButton，tooltip「设置」；设置打开时 isSelected，换实心图标）。
- 忙碌进度线叠在头部下沿（AppBar.flexibleSpace 底部对齐），不另占高度，忙碌开关时布局不跳。
- 头部下方依次（顺序同现在）：分享面板 → 错误横幅 → 前台提醒 → 内容；前三者左右内缩 JySpace.lg，彼此隔 JySpace.sm。
- 底部悬浮 dock：JyDock（overlay 色、pill，离底 12 加安全区），放在 Scaffold.bottomNavigationBar，不用 extendBody，内容不钻到 dock 下面。显示条件同现在（不在聊天、不在设置）。
- 图标：未选中沿用现有 outline 图标（联系人必须仍是 Icons.people_outline），选中用实心版；文字一直显示。

**宽屏（≥ 720；测试常用 1280×960、1280×720，以及默认的 800×600）**
- 头部同窄屏，横跨全宽。头部下面是一排板，板之间露出底色：左边导航竖板（JySlab 里放 NavigationRail，背景透明，指示器 signalSoft + JyShapes.pill，labelType 仍是 all）；聊天页分成会话板和聊天板；其他目的地和设置各占一块板。
- 板间缝和左右外缝都是 JySpace.md（12）。窗口高 < 720 时上下不留缝（保住 800×600 下设置首屏的高度，见风险 1）；≥ 720 时底边留 12。
- 会话板宽：窗口 ≥ 1024 用 320（第 9 节），否则保持 280，免得 800 宽时聊天板太窄。
- 错误横幅、分享面板、前台提醒放在导航竖板右边那一列的顶部，宽度同内容区。

## 3 用到的 lib/ui 组件
| 用途 | 组件 | 用法 |
|---|---|---|
| 窄屏导航 | `JyDock` + `JyDockItem` | 5 项，selectedIndex = destination；onSelected 照旧：导航代数 +1、mobileChat = false |
| 导航竖板、内容板 | `JySlab`（tone slab，radius lg，padding 0） | 只给背景和圆角，不带滚动、不是 Card；NavigationRail 本身保留 |
| 连接状态 | `JyStatusDot(online)` | 旁边保留「在线」「离线」文字 |
| 忙碌 | `JyBusyIndicator(label: '正在处理', linear: true)` | 替换 LinearProgressIndicator |
| 错误 | `JyBanner(message, kind: error, onClose: clearError)` | closeTooltip 用默认「关闭提示」 |
| 出现 | `JyExpand` | 错误横幅、分享面板；常驻在列里，expanded = 有内容 |
| 目的地和层的切换 | `JySwitcher` | 见第 4 节 |
| 手感 | `JyPressable`（onTap 为空） | 包设置键（pressedScale 0.92）、分享面板按钮、对话框单选行 |
| 分享面板 | `JySlab(tone: raised)` + `JyIconTile` | 替换现在的 Container，Key 挂在最外层 |
| 分享对话框 | `showJyDialog` | builder 照旧返回 AlertDialog；提交中的转圈换 `JyBusyIndicator(label: '正在加入草稿')` |
| 启动中 | `JyPresenceOrb` + `JyBusyIndicator(label: '正在启动')` | 替换居中转圈；光核静态，循环只在指示器里 |
| 模块空页 | `StatusPanel(fill: true)` | foundation 负责；module-status-<id> 胶囊保留 |
| 减少动效 | `JyMotionScope` | 放在 MaterialApp.builder，见第 6 节 |
- 不用 JyStackDeck：外壳没有同类卡片，前台提醒一次一条（MASTER 第 7 节）。Key、tooltip、语义都留在 Material 控件本身。

## 4 五类动效落点
| 类 | 落点 | 做法 |
|---|---|---|
| 触摸 | dock 各项、导航竖板各项、设置键、分享面板按钮、对话框单选行 | dock 和 Rail 自带反馈；其余 JyPressable，只加手感 |
| 展开 | 错误横幅、分享面板 | JyExpand 展开并淡入；消失时子项当帧换成空再收起，旧文字不留在树上（只 pump 一帧的断言也找不到） |
| 缩放 | 分享对话框、失效对话框 | showJyDialog：0.94→1 加淡入（emphasized），退场 < 300ms |
| 堆叠 | 无 | 见第 3 节末 |
| 过渡 | 切换目的地；窄屏列表↔聊天；主页↔设置；推入页 | 目的地用 JySwitcher(fadeThrough)，key = destination；列表↔聊天、主页↔设置用 JySwitcher(sharedAxisX)，返回时 reverse: true；推入页用主题里的 JyPageTransitionsBuilder，外壳不自定义 Route |
- JySwitcher 换 key 时旧子树当帧移除，过渡中同一文字不会出现两份（测试按「联系人」等文字点按，必须唯一）。宽屏选会话不换 key、不播过渡。
- 不加常驻动画；循环的只有忙碌线和启动、提交中的指示器（原本就是不定进度）。

## 5 浅色 / 深色
- 全部取 JyPalette / ColorScheme：底色用第 4 节的底色 token；板 JyTone.slab；dock JyTone.overlay + JyShadows.floating（只给悬浮物）；选中胶囊 signalSoft；进度线 signal；横幅颜色由 JyBanner 按 kind 取。不写 Color(0x…)。
- 深色靠板的明度分层，阴影交给 JyShadows（第 6 节）。themeMode 照旧，切换即时生效。
- 证据：evidence/shell-{light,dark}-{wide,narrow}.png，另加窄屏聊天、设置打开、有错误横幅、忙碌各一张（qa 的截图工具）。

## 6 减少动效
- 根 MaterialApp.builder 在现有 MediaQuery（textScaler × fontScale，2036f56 依赖，不能丢）外面包 JyMotionScope(reduce: 偏好)，同时把 disableAnimations 设为「系统 || 偏好」，lib/ui、StatusPanel 和 Material 自带动画都能读到（回答 settings.md 第 10 节第 2 条：这处由外壳改）。
- 偏好成员由 settings 加（runtime + ShellViewModel 默认 getter 返回 false，共享文件只做加法）；合入前外壳传 false。
- 外壳表现：切换只剩 ≤ 120ms 淡入淡出；dock 胶囊直接到位；横幅直接出现；进度换静态条，仍读出 label；对话框只淡入。

## 7 系统返回键（修缺陷）
- 外壳 Scaffold 外面包 PopScope：canPop = !(settings || (!wide && showChat))。
- onPopInvokedWithResult(didPop, _)：didPop 为真就返回；设置打开时执行 _closeSettings()（导航代数 +1、settings = false）；窄屏聊天打开时执行 _closeMobileChat()（mobileChat = false），回到会话列表。两个方法由 SettingsScreen.onBack、ChatPane.onBack 和返回键共用。其余情况放行，在列表页按返回仍退出应用。
- 参照 settings_screen.dart:1211 的 PopScope（canPop 由状态算出）。不新增 BackButton，也不用 LocalHistoryEntry：它会让 AppBar 自动出现 tooltip 为 Back 的返回键，而 pageBack() 要求全屏只有一个。
- 弹窗和底部面板是上层路由，返回键先交给它们自己的 PopScope，外壳不参与。
- 测试思路（新增 shell_back_navigation_test）：① 390×844 打开会话 → handlePopRoute → 「返回会话列表」消失，会话列表和 dock 回来，SystemNavigator.pop 没被调用（mock SystemChannels.platform 记录）；② 打开设置 → handlePopRoute → SettingsScreen 消失；③ 列表页 handlePopRoute → 记录到 SystemNavigator.pop；④ 窄屏聊天里打开消息操作面板 → handlePopRoute → 只关面板，聊天还在；⑤ 1280×960 选会话后 handlePopRoute 不拦。

## 8 必须保留的测试契约
手写要点：
- 头部标题等于当前目的地名，导航里也有同名文字。测试按文字点按别的目的地，所以除了标题和导航，别处不能再出现这五个词。设置打开时标题仍是「鲸言鲸语」。
- 宽屏导航必须是 NavigationRail，selectedIndex 语义不变（设置打开时仍是 destination）。
- 设置键全屏唯一，tooltip「设置」，点一次打开、再点一次关闭。外壳不出现 tooltip 为 Back 的返回键（pageBack() 要唯一）。
- 设置打开时内容区直接放 SettingsScreen，外面不套任何 Scrollable（设置页要求 Scrollable 唯一）；800×600 下内容区高度不少于现在（风险 1）。
- 根仍是 MaterialApp（不是 router），builder 里的 fontScale 乘法保留。
- 宽屏聊天页 ConversationList 和 ChatPane 同时在树上；窄屏 ChatPane 带 onBack（显示「返回会话列表」）。
逐文件（反引号里的每一项都已在该测试文件里 grep 到原文）：
- **owner_chat_entry_test**：类型 `NavigationRail` `SettingsScreen`；tooltip `设置`；文案 `此私聊在当前会话列表中不可见。` `宿主的私聊授权已变化，未打开会话。` `正在更新会话，请稍后再试。` `暂时无法核对私聊，请检查连接或登录状态后再试。`（openOwnAiChat 的 SnackBar，原样保留）
- **foreground_message_notice_test**（1280×720）：tooltip `设置` `关闭新消息提示`；文案 `聊天` `动态` `收件箱`
- **shell_contacts_wiring_test**：文案 `联系人`；联系人未选中图标 Icons.people_outline（按图标点按）
- **contact_friend_request_route_test**：文案 `聊天` `联系人`
- **shell_creative_wiring_test**：文案 `动态`
- **shell_friend_actions_test**：文案 `联系人`
- **shell_inbox_invite_actions_test**：文案 `收件箱`
- **ui_test**：文案 `世界`
- **share_target_confirmation_test**（高 844，宽度参数化）：文案 `选择会话` `加入草稿` `丢弃分享`；Key 前缀 `share-target-`；对话框打开时 handlePopRoute 只关对话框，不应用也不丢弃
- **chat_reactions_ui_test**：面板打开时 handlePopRoute 由面板处理，Key `message-reactions-sheet`
- **ui_refresh_states_test**：类型 `MaterialApp` `StatusPanel`；减少动效经 MediaQuery 的 disableAnimations 传到 StatusPanel
- **chat_history_opening_test**：类型 `ChatPane`（外壳直接放 ChatPane）

## 9 风险
1. 800×600 首屏：ui_test 点「设置」后不滚动直接点「应用锁」「隐藏通知正文」。外壳给内容区的高度不能少于现在的 544（600 − 56）：头部保持 56、进度线不占高、窗口高 < 720 时板上下不留缝。实现后先跑 ui_test 的设置段。
2. 过渡中出现重复文字：JySwitcher 若没有当帧移除旧子树，按「联系人」等文字 tap 会报 ambiguous。合入后先跑 shell_contacts_wiring_test、shell_creative_wiring_test。
3. 板的实现：JySlab 若内部是 Card，会改变 find.byType(Card) 的计数；若带滚动，会破坏设置页 Scrollable 的唯一性。
4. 宽屏聊天板变窄（800 宽时约 390，原来约 438）：输入行可能溢出。先跑 composer_busy_focus_test、group_chat_ui_test、mention_message_ui_test。
5. dock 若用 extendBody 钻到内容下面，测试点列表底部的行会点到 dock，所以不用。
6. 返回键：PopScope 挂在 home 路由上，只在没有弹窗和面板时生效；不要用 LocalHistoryEntry 或 BackButton。
7. 大字号：标题不截断，放不下时头部按内容长高；dock 文字由 JyDock 保证不截断。
8. 新的语义文案「正在处理」「正在启动」「正在加入草稿」已 grep，不与测试撞；后加的文案同样先 grep。

## 10 问题（不等答复，先按建议做）
1. 减少动效：偏好成员（runtime + ShellViewModel，默认 false）由 settings 加；根 MaterialApp.builder 的 JyMotionScope 和 disableAnimations 由我加。这样分工可以吗？
2. JySlab 内部是不是 Card、会不会带滚动？外壳的板只要背景和圆角。
3. 宽屏会话板按「窗口 ≥ 1024 用 320，否则 280」，可以吗？
4. 返回键在宽屏的设置里也拦（关设置），比 handoff 只拦窄屏聊天多一步，依据 MASTER 第 9 节。
5. 启动中用静态 JyPresenceOrb 加 JyBusyIndicator，可以吗？（循环只在指示器里）
