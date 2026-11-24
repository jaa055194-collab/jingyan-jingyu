# 世界页方案（world）
> 规范唯一来源 `../MASTER.md`；组件签名照 MASTER 第 8 节和 lead 的补充（`JyBusyIndicator`、`JySonarRings`）。范围 `lib/features/world/**`：`world_screen.dart`（dock 上的「世界」页）、`world_status_screen.dart`（从设置的开发者分组推入的「世界状态」页）；外壳头部和 dock 见 `shell.md`，形象设置流程（引导页）见 `onboarding.md`。
> 原则：重做布局和观感；设置入口的可用条件、性能探针入口、世界状态的只读查询流程不变；Key、测试依赖的文案和控件类型不动。两页都只读，不修改世界配置。

## 1 盘点（现状）
- `WorldScreen`（无状态，参数 model、onOpenSetup）：一个 `ListView`（padding 24），依次是「世界与形象」标题；状态句（已设置是「形象与房间已设置。」，未设置是「形象和房间属于可选世界设置，可稍后在这里完成；聊天不受影响。」）；来源说明（`world-live-note`）；未设置时有 `FilledButton.icon`「设置形象与房间（可选）」（`world-open-setup`，已登录且不忙时可点，调 onOpenSetup 打开引导页）；分隔线；「形象模型（各端本地）」和一段说明；分隔线；「3D 渲染」和一张写着三维渲染尚未接入的 `Card`；最后是 `OutlinedButton.icon`「打开模块测试与性能探针」（`world-open-perf`，推入「模块测试与性能探针」页，页内是 `ModuleTestPanel`，不归本页）。外壳 AppBar 已经显示「世界」。
- `WorldStatusScreen`（参数 initialSpaceId、load、title，title 默认「世界状态」）：`Scaffold` + `AppBar(title)`，下面一个 `ListView`，依次是说明（`world-help`）；`TextField`「空间标识（需显式填写）」（`world-space-id`，有 helper，回车也会读取）；空间为空时的提示（`world-space-unconfigured`）；`TextButton`「刷新/加载」，读取中显示「加载中…」（`world-status-refresh`，读取中或没有 load 时禁用）；读取中的 `CircularProgressIndicator`；没有 load 或读取失败时的未知块（`world-status-unknown`，两句话）；各节 `Card`（`world-section-<标题>`：标题、状态「已读取/未找到/无权限/未知/未指定」、若干行）。进页就读一次；重读时上次的结果留着，进度显示在上面；失败不显示细节，不自动重试。

## 2 布局：世界页
- 仍是一个 `ListView`：ui_test 在 375×350、1.5 倍字号下用 ensureVisible 找设置键。左右边距窄屏 16、宽屏 24；宽屏内容列限宽 720 居中；底部按 shell.md 给 dock 留位。从上到下三块板，板间 12：
  1. **状态板**（`JySlab`）：宽屏分左右两栏，左栏是文字，右栏是 `JySonarRings(size: 144)`，环心一枚 `Icons.public_rounded`（signal）；窄屏环缩到 72，放在标题行右侧。左栏依次是「世界与形象」（titleLarge）、状态句（bodyMedium、text2）、未设置时的「设置形象与房间（可选）」（`FilledButton.icon`，Key、图标、可用条件都不变，窄屏满宽）、一条发丝线、来源说明 `world-live-note`（bodySmall、text3，前面一枚装饰 info 图标）。设置键紧跟在状态句后面，小屏大字号时也在列表前段。已设置时环用 signal，未设置时用 outline 色；状态由那句话说明，不只靠颜色。
  2. **形象模型板**（`JySlab`）：行首 `JyIconTile(Icons.face_outlined)`，标题「形象模型（各端本地）」（titleMedium），说明照旧（bodyMedium、text2）。
  3. **3D 渲染板**（`JySlab`，替换现在的 `Card`）：行首 `JyIconTile(Icons.view_in_ar_outlined)`，标题「3D 渲染」，说明照旧；板底右对齐「打开模块测试与性能探针」（`OutlinedButton.icon`，Key、图标不变，窄屏满宽）。探针入口和 3D 接入说明放在一起，两条分隔线去掉。

## 3 布局：世界状态页
- 推入页保留 `Scaffold` + `AppBar`（title「世界状态」，自带返回键）。`ListView` 的边距、限宽同上，从上到下：
  1. 说明 `world-help`：raised 底的内缩板，前面一枚装饰 info 图标，bodySmall、text2，文字照旧。
  2. 查询板（`JySlab`）：`TextField` `world-space-id`（标签、helper 照旧，用主题的输入框样式，md 圆角）；下面是空间为空的提示 `world-space-unconfigured`（bodySmall、text2，装饰 info 图标；出现条件不变，输入后当帧消失）；右对齐 `TextButton` `world-status-refresh`（文字、禁用条件不变，高 ≥48）。
  3. 读取中：查询板下面居中 `JyBusyIndicator(label: '正在读取世界状态')`；上次的结果留在下面（同现在）。
  4. 未知：`world-status-unknown` 是 raised 底的中性提示板（`Icons.help_outline_rounded`，text2），两句话照旧。未知不是错误，不用 danger 色。
  5. 各节：每节一块 `JySlab`（Key `world-section-<标题>`）。行首 `JyIconTile`（世界布局 `Icons.map_outlined`、在场 `Icons.wifi_tethering_rounded`、形象 `Icons.face_outlined`，其他 `Icons.layers_outlined`），标题 titleMedium，右侧一枚状态胶囊（第 6 节）；下面每行一个 `Text`（bodyMedium、text2，不合并）。

## 4 用到的 lib/ui 组件
| 用途 | 组件 | 用法 |
|---|---|---|
| 板 | `JySlab` | 世界页三块；状态页的查询板和各节；说明和未知用 raised |
| 声呐环 | `JySonarRings` | 世界页状态板；`pulseOnAppear: true`，只放一次 |
| 行首 | `JyIconTile` | 形象模型、3D 渲染、各节 |
| 首现 | `JyEntrance` | 世界页三块板；状态页第一次拿到结果时的各节，之后刷新不再播 |
| 结果切换 | `JySwitcher(fadeThrough)` | 状态页的未知块和各节结果（key 用这次的快照对象） |
| 进度 | `JyBusyIndicator` | 状态页读取中；正常动效时内部仍是 `CircularProgressIndicator` |
| 手感 | `JyPressable` | onTap 为空，包在「设置形象与房间（可选）」「打开模块测试与性能探针」「刷新/加载」外 |
- 不用 `StatusPanel`：未知块要保留两句原文和 Key，而且未知不是错误；世界页没有空态和失败态。
- 不用 `JyExpand`、`JyStackDeck`、弹窗和底部面板。

## 5 五类动效落点
| 类 | 落点 | 做法 |
|---|---|---|
| 触摸 | 三个按钮 | `JyPressable`；板不可点，不加按下效果 |
| 展开 | 无 | 说明文字要一进页就能找到；空间提示要在输入后当帧消失，收起动画会让它多留几帧 |
| 缩放 | 无 | 两页都没有弹窗和图片 |
| 堆叠 | 无 | 世界页三块、状态页各节内容各不相同，都要一直可见 |
| 过渡 | 推入探针页、从设置推入状态页；状态页结果切换；首现；声呐波 | 推入用主题的 `JyPageTransitionsBuilder`，本页不自定义 Route；结果用 `JySwitcher`；板用 `JyEntrance` 错开 30ms；状态板出现时 `JySonarRings` 放一圈声呐波（gentle，只放一次） |
- 循环动画只有状态页读取中的进度；声呐波和首现都在有限时间内停（测试大量 `pumpAndSettle`）。

## 6 浅色 / 深色
- 颜色全取 `JyPalette` / ColorScheme：canvas 底、slab 板、raised 说明和未知板、hairline；环和环心图标 signal（未设置时 outline）；标题 text1，说明 text2，来源说明 text3；设置键 signal 实色，探针键 outline 描边、signal 字。不用 ember：世界和形象不是 AI 伙伴。页面里不写色值。
- 状态胶囊：raised 底、pill、labelMedium，图标加原文字：已读取（success，勾）、未找到（text2，搜索无结果）、无权限（warning，锁）、未知（text2，问号）、未指定（text3，减号）。
- 板不加阴影；环在浅色、深色里都是 signal 越外越淡（组件负责）。
- 截图：世界页未设置、已设置，状态页有结果、未知、读取中；浅色、深色各出宽屏和窄屏。

## 7 减少动效、大字号、读屏
- 减少动效交给组件：`JySonarRings` 只画静态环；`JyEntrance`、按压缩放关掉，按压只留高亮；`JySwitcher` 只淡入淡出（≤120ms）；推入页只淡入；读取中换静止的环加文字「正在读取世界状态」。
- 大字号：375×350、1.5 倍字号下世界页不能溢出（ui_test 要求没有异常）；文字都换行；窄屏按钮满宽；状态胶囊放不下时换到标题下一行。
- 读屏：环和环心图标是装饰，对读屏隐藏；板和节的标题加 header 语义；状态胶囊读出原文字；两页都没有单独的图标按钮。

## 8 必须保留的测试契约（已逐个 grep `test/`、`evidence/` 核对）
- `world_screen_test.dart`（2）：1000×2200；文案「世界与形象」正好一个；包含「尚未接入」「各端本地」各正好一个；Key `world-open-perf` 一个；点 `world-open-setup` 调一次 onOpenSetup（测试的模型已登录、不忙）；已设置时没有 `world-open-setup`。
- `honest_copy_test.dart`（本页部分）：`WorldScreen(model: TestShellModel())` 下 Key `world-live-note` 一个，包含「数据来自宿主实时读取」「不修改世界配置」各正好一个。
- `ui_test.dart`（本页部分）：点 dock 的「世界」；文案「世界与形象」「设置形象与房间（可选）」各正好一个；点设置键进引导页（「选择你的形象」、`defer-world-setup`、「账号 ID：account-9」都在引导页上）；375×350、1.5 倍字号下进页没有异常，`ensureVisible` 找得到「设置形象与房间（可选）」。
- `world_status_screen_test.dart`（8）：Key `world-help` `world-space-id` `world-space-unconfigured` `world-status-refresh` `world-status-unknown` `world-section-世界布局` `world-section-在场` `world-section-形象`，设置页的 `open-world-status`；文案「已读取」「未找到」「无权限」各正好一个（胶囊里的整串）；包含「不做 3D 渲染」「密钥」「需显式填写空间标识」「未填写空间标识」「客厅」「未知不代表已配置，也不代表未配置」各正好一个，「未知≠错误」「未知不代表已配置」至少一个，必须找不到「secret-token」；byType `CircularProgressIndicator`（点刷新后 pump() 一帧正好一个，读完没有）、`Scrollable`（设置页 `.first`）、`WorldStatusScreen`；`widget<TextButton>`（没有 load 时刷新键 onPressed 为 null）；`enterText('  home  ')` 后读取收到 `home`；输入 `home` 后 pump() 一帧提示就不在。
- `owner_chat_entry_test.dart`（本页部分）：byType `WorldStatusScreen`；文案「世界状态」正好一个（按整串匹配，只有 AppBar 标题是这一串）。`module_test_panel_test.dart` 测的是探针页的内容，不归本页。tooltip：两页都没有。

## 9 风险
- `ListView` 懒加载：小屏大字号时设置键要落在首屏加缓存区以内，所以紧跟状态句，状态板窄屏只放 72 的环。
- 「各端本地」「尚未接入」「密钥」「未填写空间标识」「需显式填写空间标识」「不做 3D 渲染」按包含匹配，要唯一：新文案、胶囊、副标题里都不能出现。「世界状态」按整串匹配，新文案「正在读取世界状态」不撞，已 grep；它只进语义，减少动效时才显示。
- 结果切换时旧子树要当帧移除，否则「已读取」会找到两个；空间提示直接按条件移除，不用 `JyExpand`。
- 状态胶囊里只有原文字一个 `Text`，不加别的字（`find.text` 按整串匹配）；长说明保持一个 `Text`，不拆。

## 10 待确认（不等答复，先按建议做）
1. `JySonarRings` 用 lead 补充里的签名；还没合入时先画静态环，合入后换。
2. 「未知」用中性色，不用 danger：文案本身就说未知不是错误。
3. 两页的 `Card` 都换成 `JySlab`；按类型找 `Card` 的只有设置的 device_sessions 测试，和本页无关。
4. 世界页去掉两条分隔线，探针入口挪进 3D 渲染板。
