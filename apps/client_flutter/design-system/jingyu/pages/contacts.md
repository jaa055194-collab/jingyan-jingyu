# 联系人页方案（contacts）
> 规范唯一来源 `../MASTER.md`；组件签名照 MASTER 第 8 节和 lead 的补充（`JyBusyIndicator`、`showJyDialog` 用的 `JyDialogRoute`）。范围 `lib/features/contacts/**`；外壳头部和 dock 见 `shell.md`。
> 原则：重做布局和观感；读取、接受/拒绝、发起好友请求、查询关系的流程和回调不变；Key、测试依赖的文案和控件类型不动。

## 1 盘点（现状，`contacts_screen.dart`）
- 一个 `SingleChildScrollView` 里居中的 `Column`：40 号 `Icons.people_outline`、「联系人」标题、来源说明（`contacts-live-note`）、好友列表、发起好友请求、按账号 ID 查询关系。外壳 AppBar 已经显示「联系人」。
- 行：`ListTile`（Key `contacts-friend-<账号>`，title 是显示名 `Text`，subtitle「<账号> · <关系>」）；`incomingPending` 行尾两个 `TextButton`「接受」「拒绝」。关系文案：未添加、已发出请求，待对方确认、对方请求添加你、好友、已拉黑/被拉黑。
- 状态：未连接（`loadFriends` 为空）、读取中（`CircularProgressIndicator`）、失败（读取或处理邀请失败：整块换成一句说明，按钮消失，不自动重试）、空、列表。处理邀请成功后整张列表重读。
- 发起好友请求：输入账号 ID →「核对好友请求」→ 根导航上 push 的 `DialogRoute` 确认弹窗 →「确认发送」。会话或导航变化时 `removeRoute` 当帧撤掉弹窗；结果放在 liveRegion 里，只在同一会话内显示。
- 查询关系（`lookupState`）只有测试传；外壳没连宿主时给空的 `ContactsScreen()`，登录后才传 `requestFriend`。

## 2 布局
- 仍是一个 `SingleChildScrollView` + `Column`，不换懒加载的 `ListView`：测试在 800×600 下直接 `enterText`、`tap` 表单，每个分区都要构建出来。
- 去掉页内的大图标和「联系人」标题（外壳头部已有）。页内不用 `Icons.people_outline`：`shell_contacts_wiring_test` 按这个图标点 dock。
- 左右边距窄屏 16、宽屏 24；宽屏内容列限宽 640 居中；底部按 shell.md 给 dock 留位。从上到下：
  1. 来源说明 `contacts-live-note`：一行 bodySmall、text3，前面一枚装饰 info 图标（对读屏隐藏），文字照旧；所有状态下都显示，包括未连接。
  2. **发起好友请求**板（有 `requestFriend` 和会话时）：小标题「发起好友请求」，胶囊输入框 `contacts-request-account`（标签「对方的账号 ID」，错误文案照旧），说明「输入对方提供的账号 ID。请求需对方同意，不会自动开启聊天。」，右对齐 `FilledButton`「核对好友请求」/「正在发送…」，下面是结果条。MASTER 第 9 节的「顶部胶囊搜索框」就落在这里，不另做本地筛选。
  3. **好友申请**（有 `incomingPending` 时）：`JySectionHeader`「好友申请」；1 条是一张卡，≥2 条收进 `JyStackDeck`，summary「N 条好友申请」。
  4. **我的好友**（`friends`）、**其他关系**（已发出、未添加、已拉黑）：各一个 `JyGroup`，空的组不显示；行样式同会话列表：44 头像、名字 titleMedium、「账号 · 关系」bodyMedium text2；组内保持接口顺序。
  5. **查询关系**板（有 `lookupState` 时）：输入框 `contacts-account-id`、`FilledButton`「查询关系」、结果文字。
- 申请卡：`JySlab(tone: raised)`，上面是原来的 `ListTile`（Key、title、subtitle 不变），下面一行 `OverflowBar`（放不下就竖排），右对齐：「拒绝」`TextButton`（text2 字）、「接受」`TextButton`（signalSoft 底、onSignalSoft 字、md 圆角）。类型都还是 `TextButton`，只改 style；高 ≥48，间距 8。
- 状态区（第 3、4 段的位置）：
  - 未连接：`StatusPanel`（离线 tone，`Icons.link_off_rounded`，title「当前未连接宿主，无法读取联系人。」，不给操作键）。
  - 读取中：居中 `JyBusyIndicator(label: '正在读取联系人')`。
  - 读取失败：`StatusPanel`（错误 tone，title「没能读取联系人」，detail 是原文案，操作 `TextButton`「重新读取」，Key `contacts-retry`，点了才读）。
  - 处理邀请失败：同上，title「没能处理好友申请」。实现时把 `_friendsMessage` 拆成「哪类失败 + 原文」，原文一字不改。
  - 空：`StatusPanel`（`Icons.group_outlined`，title「暂无联系人或待处理的好友邀请。」）。
- 结果条：自己画内缩圆角条（成功 signalSoft、失败 dangerSoft，图标加文字），文字仍是带 Key `contacts-request-result` 的 `Text`，外面仍包 `Semantics(liveRegion: true)`。结果记录加一个是否成功的字段，只用来选底色。

## 3 用到的 lib/ui 组件
| 用途 | 组件 | 用法 |
|---|---|---|
| 板 | `JySlab` | 发起好友请求、查询关系各一块；申请卡用 raised |
| 分区 | `JySectionHeader` + `JyGroup` | 「好友申请」「我的好友」「其他关系」；Key 留在 ListTile 上 |
| 头像 | `JyAvatar(kind: person)` | label 用 `_contactTitle(friend)`（控制字符已回落成账号），不读原始 displayName；对读屏隐藏 |
| 申请摞 | `JyStackDeck` | ≥2 条时用；`expanded` 存在页面 State 里，重读后不丢 |
| 状态切换 | `JySwitcher(fadeThrough)` | 未连接、读取中、失败、空、列表各给 key；结果条出现和消失也用它 |
| 首现 | `JyEntrance` | 好友组前 8 行；只在页面第一次读取成功时播，处理邀请后的重读不播 |
| 状态面板 | `StatusPanel` | 未连接、失败、空 |
| 进度 | `JyBusyIndicator` | 读取中；正常动效时内部仍是 `CircularProgressIndicator` |
| 弹窗 | `JyDialogRoute<bool>` | 替换 `DialogRoute`，builder 照旧返回同 Key 的 `AlertDialog`，`themes` 照旧捕获 |
| 手感 | `JyPressable` | onTap 为空，包在「接受」「拒绝」「核对好友请求」「确认发送」「查询关系」「重新读取」外 |
- 不用 `JyExpand`：结果条、失败态要在条件变化的当帧离开树（测试 findsNothing），收起动画期间子树还在。
- 不用 `JyBanner`：它只收字符串，没法把 Key 挂在文字上。

## 4 五类动效落点
| 类 | 落点 | 做法 |
|---|---|---|
| 触摸 | 上表的按钮；收起的申请摞 | `JyPressable`；行本身不可点，不加按下效果 |
| 展开 | 申请摞展开、收起 | `JyStackDeck` 自带：逐张错开 30ms、弹簧落位，`JyChevron` 转 180° |
| 缩放 | 「发送好友请求？」弹窗 | `JyDialogRoute`：0.94→1 加淡入（emphasized），关闭 252ms；失效时仍用 `removeRoute` 当帧撤掉，不改成 pop |
| 堆叠 | ≥2 条好友申请 | 收起时只有第一张（接口顺序第一条）在最上面、可点；后两张 0.95、0.90，下移 8、16；展开收起只由摘要行（summary + `JyChevron`）触发，点卡片不展开，免得吞掉「接受」「拒绝」 |
| 过渡 | 状态切换、结果条、列表首现 | `JySwitcher` fadeThrough、`JyEntrance`；进出本页由外壳负责 |
- 循环动画只有读取中的进度；不加常驻动画（测试大量 `pumpAndSettle`）。

## 5 浅色 / 深色
- 颜色全取 `JyPalette` / ColorScheme：canvas 底、slab 板、申请卡 raised、组内发丝线 hairline；「接受」signalSoft；失败 dangerSoft；说明 text3。页面里不写色值。
- 这页没有 AI 伙伴，不用 ember。板不加阴影，层次靠色阶、发丝线和上沿高光（`JySlab` 按 MASTER 处理）；只有展开的申请摞带一层柔和阴影（`JyStackDeck` 负责，深浅色参数不同）。
- 截图：浅色、深色各出宽屏和窄屏，状态覆盖 2 条申请（收起、展开）、空、未连接、失败，用 qa 的截图工具，自己看过。

## 6 减少动效、大字号、读屏
- 减少动效由 lib/ui 组件按 MASTER 第 7 节处理，页面不自己分支：申请摞展开收起直接换位，只留 ≤120ms 淡入淡出，收起时的叠放形状照旧（静态的，提示还有几张）；`JyEntrance`、弹窗缩放、按压缩放都关掉，按压只留高亮；读取中换静止环加文字「正在读取联系人」。
- 最大字号：标题、副标题换行不截断；按钮行竖排；胶囊输入框随字号变高，不写死高度。
- 申请摞的 summary 和展开状态进语义，收起时后面的卡不进语义（`JyStackDeck` 负责）；关系靠文字表达，不只靠颜色；本页没有单独的图标按钮。

## 7 必须保留的测试契约（已逐个 grep `test/`、`evidence/` 核对）
- `contacts_screen_test.dart`（8）：Key `contacts-query` `contacts-account-id` `contacts-friend-fixture-inviter`；文案 「当前未连接宿主，无法读取联系人。」「关系状态：好友」「Alice」「alice · 好友」「Bob  Li」（两个空格）「暂无联系人或待处理的好友邀请。」；包含 「查询失败」「alice」「对方请求添加你」「未认证或无权限」「读取失败或结果未知」，以及必须找不到的「private-upstream」「无法读取联系人」「upstream-secret」「private-upstream-detail」；byType `CircularProgressIndicator`（读取中正好一个）；`widget<ListTile>`，且 `row.title` 直接是 `Text`。
- `contacts_friend_actions_test.dart`（7）：Key `friend-accept-acct-b` `friend-deny-acct-b` `friend-accept-acct-a` `friend-deny-acct-a`；文案 「接受」「拒绝」「acct-a · 好友」「未认证或无权限处理邀请；不会自动重试」「好友操作响应无效；不会自动重试」；包含 「未添加」，必须找不到「secret-detail-xyz」；`widget<TextButton>`（处理中 onPressed 为 null）。
- `contact_friend_request_route_test.dart`（8）：Key `contacts-request-account` `contacts-request-review` `contacts-request-confirmation`（含 `skipOffstage: false` 的 findsNothing）`contacts-request-send` `contacts-request-result` `contacts-friend-fixture-peer` `contacts-request-cancel` `contacts-friend-$_target`；文案 「联系人」「聊天」（点 dock）「Unrelated test page」（测试自建页）；包含 「宿主已确认」「不代表」「不会自动重试」、弹窗里的目标账号，必须找不到「opaque upstream」；`widget<FilledButton>`（review 的 onPressed）。
- `shell_contacts_wiring_test.dart`（1）：byIcon `Icons.people_outline`；文案 「联系人」「当前未连接宿主，无法读取联系人。」；Key `contacts-friend-x`（findsNothing）。
- `shell_friend_actions_test.dart`（1）：Key `friend-accept-fixture-alice` `friend-deny-fixture-bob`；文案 「联系人」；`widget<TextButton>`。两条申请同时在，先接受 alice（第一条），再拒绝 bob。
- `honest_copy_test.dart`（本页部分）：Key `contacts-live-note`；包含「数据来自宿主实时读取」，都要求正好一个；测试用无参数的 `ContactsScreen()`（未连接），所以未连接时也显示来源说明，状态面板里不重复这句。
- `ui_test.dart`（本页部分）：文案 「联系人」「当前未连接宿主，无法读取联系人。」。
- `evidence/contact_friend_request_capture_test.dart`：Key `contacts-friend-fixture-friend` `contacts-request-account` `contacts-request-review` `contacts-request-confirmation` `contacts-request-send` `contacts-request-result`；文案 「联系人」；包含 「Fixture_Target-02」。
- tooltip：本页无。

## 8 风险
- 叠放顺序反了，`shell_friend_actions_test` 会点到别的卡：第一条必须在最上面，收起时只有它可交互。
- `JyStackDeck` 要是为了测量把 children 多建一份，要求 `findsOneWidget` 的名字和文案就会找到两个：每个 child 只建一份。
- 换成懒加载列表，表单不在树上，`enterText` 找不到；首屏要在 800×600 下不滚动就点得到「核对好友请求」。
- 弹窗失效改成 pop，退场期间 `skipOffstage: false` 仍找得到弹窗。
- 新文案「好友申请」「N 条好友申请」「我的好友」「其他关系」「没能读取联系人」「没能处理好友申请」「正在读取联系人」「重新读取」已 grep，不撞。summary 不放名字或账号（`alice` 要唯一），新文案里不能出现「对方请求添加你」「不会自动重试」「当前未连接宿主」「数据来自宿主实时读取」；也不出现单独的「好友」「连接宿主」（ui_test 按全文找）。

## 9 待确认（不等答复，先按建议做）
1. `JyDialogRoute` 要公开构造（context、builder、themes、barrierDismissible），本页要拿 route 对象做 `removeRoute`；没有就保留 `DialogRoute`，只换 `AlertDialog` 外观。
2. `JyStackDeck` 收起时 children[0] 在最上、只有它可交互，展开收起由摘要行触发、不拦截卡内按钮；做不到就让申请摞默认展开，收起交给用户点摘要行。
3. 「顶部胶囊搜索框」落为发起好友请求的输入框，不做本地筛选。
4. 失败态加手动「重新读取」（`contacts-retry`），不自动重试。
