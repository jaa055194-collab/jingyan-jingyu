# 收件箱方案（inbox，含前台消息提醒）
> 规范唯一来源 `../MASTER.md`；组件签名照 MASTER 第 8 节和 lead 的补充（`JyBusyIndicator`、`showJyDialog` 用的 `JyDialogRoute`）。范围 `lib/features/inbox/**`：`inbox_screen.dart`、`foreground_message_notice.dart`、`foreground_message_activity.dart`（只有逻辑，不改）；提醒放在外壳的哪里见 `shell.md`。
> 原则：重做布局和观感；读取、刷新、二次确认、接受/拒绝、会话失效的流程不变；前台提醒的出现条件、8 秒自动消失和隐私设计（不计数，不显示内容和发送者）不变；Key、测试依赖的文案、tooltip 和控件类型不动。

## 1 盘点（现状）
- 未连接（`loadNotifications` 为空）：居中的图标、「收件箱」、「当前未连接宿主，无法读取收件箱。」（`inbox-gap`）、「连接后可查看待处理的好友邀请。」（`inbox-after-wiring`），没有刷新键。
- 已连接：顶部右对齐 `TextButton.icon`（`inbox-refresh`，「刷新收件箱」，失败后是「重试读取」；读取中或有邀请在处理时禁用）。下面按状态换：读取中（`CircularProgressIndicator` +「正在读取收件箱…」，liveRegion）、失败（居中 `Text`，`inbox-message`）、列表。
- 列表 `ListView`：通知行或空（「暂无新通知。」，Key `inbox-empty` 在 Text 上），最后是范围说明（`inbox-footer`）。行是 `ListTile`（`notification-<refId>`）：图标、标题、「来自 <refId> · <时间>」，处理失败时多一行红字（`inbox-action-failure-<refId>`，liveRegion）。行尾三选一：结果「已接受」/「已拒绝」；可处理时两个 `TextButton`「接受」「拒绝」（`inbox-accept/deny-<refId>`，有一条在处理时全部禁用）；其他情况原样显示 status（如 `pending`）。
- 可处理 = friendRequest、pending、还没有结果、有回调、有会话、refId 合法。点「接受」「拒绝」先在根导航上 push `DialogRoute` 确认（`inbox-confirm-dialog`，「接受好友邀请？」/「拒绝好友邀请？」，`inbox-confirm-cancel`「取消」，`inbox-confirm-ok`「确认接受」/「确认拒绝」）；锁定、登出、换账号时用 `removeRoute` 当帧撤掉，不写宿主；写的途中会话变了，结果丢弃。
- 前台提醒 `ForegroundMessageNotice`：外壳在内容区上方放一条（key 是 `ValueKey(destination)`），只在现有条件下出现。固定一句「收到新消息，可在聊天中查看。」（liveRegion）加关闭键（tooltip「关闭新消息提示」）；新提醒替换旧的，8 秒后自动消失，切页、锁定、登出时当帧撤掉。底色是 secondaryContainer，换主题后成了 emberSoft。

## 2 布局：收件箱
- 页内不放「收件箱」标题和大图标（外壳头部已有）。左右边距窄屏 16、宽屏 24；宽屏内容列限宽 720 居中，滚动区占满宽度；底部按 shell.md 给 dock 留位。仍然只有一个 `ListView`。
- 未连接：`StatusPanel`（offline tone，`Icons.link_off_rounded`，title「当前未连接宿主，无法读取收件箱。」配 `titleKey: Key('inbox-gap')`，detail「连接后可查看待处理的好友邀请。」配 `detailKey: Key('inbox-after-wiring')`，fill）。不给操作键，也没有工具行。
- 工具行（已连接时一直在）：右边「刷新收件箱」/「重试读取」，类型、Key、禁用条件不变，高 ≥48。
- 读取中：居中 `JyBusyIndicator(label: '正在读取收件箱…')`，外面保留 `Semantics(liveRegion: true)`。
- 失败：`StatusPanel`（error tone，`Icons.cloud_off_rounded`，title「没能读取收件箱」，detail 是原文案，配 `detailKey: Key('inbox-message')`）。面板里不放重试键，重试用工具行的「重试读取」（`inbox-refresh` 要唯一）。
- 列表：同类通知（同 kind）收成一组。组的顺序按每组第一条在接口里的位置，组内保持接口顺序。
  - 一组只有 1 条时是一张卡；≥2 条时进 `JyStackDeck`，summary 是「N 条好友邀请」（friendRequest）或「N 条同类通知」（其他 kind），N 用等宽数字。
  - 卡：`JySlab`（padding 0），上面是原来的 `ListTile`（Key、标题、「来自 …」副标题、失败红字都不变，时间用等宽数字），行首 `JyIconTile`（好友邀请 `Icons.person_add_alt_rounded`，其他 `Icons.notifications_none_rounded`）。
  - 可处理时卡底一行 `OverflowBar`（放不下就竖排），右对齐：「拒绝」`TextButton`（text2 字）、「接受」`TextButton`（signalSoft 底、onSignalSoft 字）。高 ≥48，间距 8；类型和 Key 不变，只改 style。
  - 有结果或不可处理时，卡底右侧是一枚状态胶囊：「已接受」（success 色加勾）、「已拒绝」（text2 加叉）、原样 status（raised 底、text2）。不只靠颜色。
  - 空：`StatusPanel`（`Icons.mark_email_read_outlined`，title「暂无新通知。」配 `titleKey: Key('inbox-empty')`，不 fill），是列表的一项。
  - 范围说明 `inbox-footer` 是列表最后一项：bodySmall、text3，前面一枚装饰 info 图标，文字照旧。
- 确认弹窗：`JyDialogRoute<bool>`，builder 照旧返回同 Key 的 `AlertDialog`；文案、按钮、失效时 `removeRoute` 都不变。

## 3 布局：前台消息提醒
- 位置和间距由外壳决定（shell.md：头部下方，左右内缩 16，和分享面板、错误横幅相隔 8）；组件只画自己。
- 外观：`JyBanner(kind: JyBannerKind.info, message: '收到新消息，可在聊天中查看。', onClose: _dismiss, closeTooltip: '关闭新消息提示')`：signalSoft 底、info 图标、关闭键 48dp。不用 ember：ember 只给伙伴，而提醒不透露是谁发的。
- 隐私照旧：不计数，不显示发送者、头像、会话名和内容，不区分人和伙伴；读屏只读这一句。提醒本身不可点，不跳转、不选中会话、不写宿主。
- 一次一条，不堆叠：新提醒替换旧的。8 秒自动消失不变，不画倒计时条。

## 4 用到的 lib/ui 组件
| 用途 | 组件 | 用法 |
|---|---|---|
| 卡片 | `JySlab` | 每条通知一张 |
| 同类收摞 | `JyStackDeck` | 同 kind ≥2 条；展开状态按 kind 存在 State 里，刷新后不丢 |
| 行首 | `JyIconTile` | 按 kind 换图标 |
| 状态切换 | `JySwitcher(fadeThrough)` | 读取中、失败、列表各给 key；卡底的按钮行和结果胶囊也用它换 |
| 首现 | `JyEntrance` | 第一次读取成功时前 8 项，刷新后不播 |
| 状态面板 | `StatusPanel` | 未连接、失败、空 |
| 进度 | `JyBusyIndicator` | 读取中；正常动效时内部仍是 `CircularProgressIndicator` |
| 弹窗 | `JyDialogRoute<bool>` | 二次确认 |
| 提醒 | `JyBanner` + `JySwitcher` | info 样式；JySwitcher 的 child 用这次提醒的对象作 key |
| 手感 | `JyPressable` | onTap 为空，包在「接受」「拒绝」「刷新收件箱」「确认接受」「确认拒绝」外 |
- 不用 `JyExpand`：结果、失败、提醒都要在变化的当帧离开树。

## 5 五类动效落点
| 类 | 落点 | 做法 |
|---|---|---|
| 触摸 | 上表的按钮；收起的摞的摘要行 | `JyPressable`；卡本身不可点，不加按下效果 |
| 展开 | 摞展开、收起 | `JyStackDeck` 自带：逐张错开 30ms、弹簧落位，`JyChevron` 转 180°；只由摘要行触发，不拦截卡里的按钮 |
| 缩放 | 二次确认弹窗 | `JyDialogRoute`：0.94→1 加淡入，关闭 252ms；失效时仍用 `removeRoute` 当帧撤掉，不改成 pop |
| 堆叠 | 同类通知 ≥2 条 | 收起时接口顺序第一条在最上面、只有它可交互；后两张 0.95、0.90，下移 8、16。前台提醒不堆叠 |
| 过渡 | 状态切换、按钮行换成结果胶囊、首现、提醒出现 | `JySwitcher`；提醒出现时淡入并下移 8（quick）；关闭、到时、失效时当帧移除，不播退场 |
- 循环动画只有读取中的进度；不加常驻动画（测试大量 `pumpAndSettle`）。

## 6 浅色 / 深色
- 颜色全取 `JyPalette` / ColorScheme：canvas 底、slab 卡、raised 胶囊、hairline；「接受」signalSoft；「已接受」success；失败红字 danger（现在取 `colorScheme.error`，就是 danger）；提醒 signalSoft / onSignalSoft。页面里不写色值，不用 ember。
- 板不加阴影；只有展开的摞带一层柔和阴影（`JyStackDeck` 负责）。
- 截图：浅色、深色各出宽屏和窄屏：2 条好友邀请加 1 条系统通知（收起、展开）、确认弹窗、已接受、空、未连接、失败；前台提醒在联系人页上出 1280×720 一张。

## 7 减少动效、大字号、读屏
- 减少动效交给组件：摞直接换位，只留 ≤120ms 淡入淡出，收起时的叠放形状照旧；`JyEntrance`、弹窗缩放、按压缩放都关掉，按压只留高亮；读取中换静止环加文字；提醒只淡入（≤120ms），没有位移。
- 最大字号：标题、副标题、红字换行不截断；按钮行竖排；提醒文字换行，关闭键不缩。
- 读屏：摞的 summary 和展开状态进语义，收起时后面的卡不进语义；结果和失败各自在 liveRegion 里（照旧）；装饰图标隐藏；单独的图标按钮只有提醒的关闭键，tooltip 照旧。

## 8 必须保留的测试契约（已逐个 grep `test/`、`evidence/` 核对）
- `inbox_screen_test.dart`（9）：Key `inbox-gap` `inbox-refresh` `notification-acct-a` `inbox-accept-acct-a` `inbox-deny-acct-a` `inbox-footer` `inbox-empty` `inbox-message`；文案 「当前未连接宿主，无法读取收件箱。」「连接后可查看待处理的好友邀请。」「好友邀请」「pending」「暂无新通知。」「未认证或无权限读取通知；不会自动重试」「通知读取失败或结果未知；不会自动重试」，必须找不到「本页只读，不修改好友关系。」，只读时没有「已接受」；包含 「来自 acct-a」「接受/拒绝需要再次确认」「结果以宿主返回为准」「其他通知只读」，必须找不到「请在“联系人”页处理」「opaque-failure」「secret-detail-xyz」；byType `ListTile`（未连接时没有）`CircularProgressIndicator`（读取中正好一个）；`widget<TextButton>`（`inbox-refresh` 读取中 onPressed 为 null，读完恢复）。
- `inbox_invite_actions_test.dart`（13）：Key `inbox-accept-acct-a` `inbox-deny-acct-a` `inbox-accept-acct-b` `inbox-deny-acct-b` `inbox-accept-acct-c` `inbox-deny-acct-c` `notification-acct-a` `notification-bad id!` `inbox-accept-bad id!` `inbox-deny-bad id!` `inbox-confirm-dialog` `inbox-confirm-cancel` `inbox-confirm-ok` `inbox-refresh` `inbox-empty`（`unrelated-route` 是测试自建页）；文案 「已接受」「已拒绝」「未认证或无权限处理邀请；不会自动重试」「邀请处理响应无效；不会自动重试」；包含 「acct-a」（findsWidgets），必须找不到「secret-detail-xyz」，取消或会话失效后找不到「不会自动重试」；`widget<TextButton>`（接受、拒绝、刷新的 onPressed）；被上层页盖住的确认弹窗失效后，`skipOffstage: false` 也找不到。数据有 [acct-a 待确认, acct-b 已拒绝, acct-c systemNotice] 和 [acct-a, acct-b 都待确认]；只点第一条的按钮。
- `shell_inbox_invite_actions_test.dart`（4）：文案 「收件箱」（点 dock）「已接受」「已拒绝」；Key `inbox-accept-fixture-alice` `inbox-deny-fixture-alice` `inbox-confirm-dialog` `inbox-confirm-cancel` `inbox-confirm-ok`；必须找不到「不会自动重试」；锁定时确认弹窗关闭、不写；写的途中登出，结果丢弃。
- `honest_copy_test.dart`（本页部分）：`InboxScreen()` 下 Key `inbox-gap` `inbox-after-wiring`，包含「当前未连接宿主」「连接后可查看待处理的好友邀请」各正好一个，没有 `ListTile`。
- `ui_test.dart`（本页部分）：点「收件箱」；文案「当前未连接宿主，无法读取收件箱。」「连接后可查看待处理的好友邀请。」各正好一个。
- `foreground_message_notice_test.dart`（只在 Windows 跑，1280×720）：文案「收到新消息，可在聊天中查看。」（出现时正好一个；点关闭后 pump() 一帧就找不到；pump(10 秒) 后找不到；登出、锁定后找不到；在「聊天」「动态」页不出现、也不排队）；tooltip「关闭新消息提示」「设置」；Key `inbox-refresh`；联系人空态「暂无联系人或待处理的好友邀请。」；必须找不到对方的消息内容和会话名；测试自建弹窗「Synthetic dialog」。
- `test/support/foreground_notice_fixture.dart`：等 Key `inbox-empty` 或联系人空态文案出现。
- `evidence/inbox_invite_actions_capture_test.dart`：文案「收件箱」「好友邀请」「已接受」；Key `notification-fixture-alice` `inbox-accept-fixture-alice` `inbox-confirm-dialog` `inbox-confirm-ok`；包含「来自 fixture-alice」。`evidence/inbox_manual_refresh_capture_test.dart`：Key `inbox-message` `inbox-refresh` `notification-fixture-alice`；文案「收件箱」。`evidence/foreground_message_notice_capture_test.dart`：1280×720，提醒文案在，对方内容不在，没有异常。

## 9 风险
- 摞的顺序和交互：收起时第一条必须在最上面、只有它可交互，摘要行以外不拦截点击；每个 child 只建一份，否则「好友邀请」「来自 acct-a」会找到两个。
- 按 kind 分组后，不同 kind 交错的列表会把同组排到一起；测试只按 Key 找，不受影响。
- 确认后当帧不能还留着「接受」按钮：按钮行和结果胶囊在 `JySwitcher` 里换。
- 失效的确认弹窗必须 `removeRoute`，改成 pop 的话，退场期间 `skipOffstage: false` 仍找得到。
- 提醒的退场必须当帧完成；不加倒计时动画：8 秒的动画会让 pumpAndSettle 一直推进时间，把提醒提前关掉。
- 新文案「N 条好友邀请」「N 条同类通知」「没能读取收件箱」已 grep，不撞；summary 不放账号和时间；新文案里不能出现「不会自动重试」「当前未连接宿主」「连接后可查看」。

## 10 待确认（不等答复，先按建议做）
1. 「同类」按 kind 分；summary 文案「N 条好友邀请」「N 条同类通知」。
2. `JyStackDeck` 和 `JyDialogRoute` 的要求同 contacts.md 待确认 1、2。
3. 提醒改用 `JyBanner(kind: info)`：需要 `closeTooltip` 可设、关闭键当帧回调 onClose、组件自己不做收起动画；底色从 emberSoft 换成 signalSoft。
4. 失败态的重试只放在工具行（「重试读取」），面板里不重复。
