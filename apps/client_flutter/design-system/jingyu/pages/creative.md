# 动态页方案（creative）
> 规范唯一来源 `../MASTER.md`；组件签名照 MASTER 第 8 节和 lead 的补充（`JyBusyIndicator`）。范围 `lib/features/creative/**`（`creative_screen.dart`、`creative_report_detail.dart`）；外壳头部和 dock 见 `shell.md`。
> 原则：重做布局和观感；读取、刷新、手动重试、会话失效的流程不变；Key、测试依赖的文案和控件类型不动。本页只读，不触发生成或播放。

## 1 盘点（现状）
- 顶部一行：状态说明（读取中「正在读取宿主创作数据…」，否则「只读展示；可下拉或点右侧刷新重新读取（无自动重试）。」）+ `TextButton.icon`「刷新」（`creative-refresh`，读取中或未连接时禁用）。除会话失效外，所有状态都有这一行。
- 下面按状态换：读取中（居中 `CircularProgressIndicator`）、未连接（`creative-unbound`：图标、「动态」、说明）、失败（图标、「动态」、「读取失败，请稍后重试；不会自动重试。」、`FilledButton.tonal`「手动重试」`creative-retry`）、内容。会话失效（登录、锁定、换账号）时整页换成 `creative-session-invalid`，清掉数据，不自动重读。
- 内容：`RefreshIndicator` + `ListView`：来源说明（`creative-live-note`）→「关系周报 / 年报」→ 报告行或空行（`creative-empty-reports`）→ `Divider` →「深夜电台」→ 电台行或空行（`creative-empty-radio`）。
- 报告行：Key 是 `(aiId, kind, periodKey)` 的 `ValueKey`；标题「周报 · <周期>」/「年报 · <年>」，副标题两行：「AI：<id>」和状态（已生成 · 话题、已生成 · 缺少报告内容、已错过、待重试、状态未知）。报告内容可用时是 `ExpansionTile`，展开显示 `CreativeReportDetail`；不可用时是 `ListTile`，点了不展开。
- 详情：统计区间、生成时间、话题、心情、约定和打卡、年度关键词和里程碑（年报）、最热闹的一天、信件、来源范围；节名带 `Semantics(header: true)`。
- 电台行：`ListTile`（`radio-<日期>`），图标区分可离线和在线，标题是日期，副标题「音色 … · 可离线播放/在线播放」，行尾是截短的脚本。

## 2 布局
- 页内不再显示「动态」标题（外壳头部已有）。现在未连接、失败、失效三处都有 `Text('动态')`，和 dock 的「动态」重复，而测试用 `find.text('动态')` 点 dock。
- 左右边距窄屏 16、宽屏 24；宽屏内容列限宽 720 居中（同 tools.md），滚动区占满宽度；底部按 shell.md 给 dock 留位。
- 工具行：左边状态说明（bodySmall、text3，文字照旧），右边 `TextButton.icon`「刷新」（signal，高 ≥48）。类型、Key、禁用条件不变，未连接时也显示。
- 内容是单列卡片流（MASTER 第 9 节），仍用 `RefreshIndicator` + `ListView`：
  1. 来源说明 `creative-live-note`：bodySmall、text3，前面一枚装饰 info 图标（对读屏隐藏），文字照旧。
  2. `JySectionHeader`「关系周报 / 年报」；每条报告一块 `JySlab`（padding 0，lg 圆角，卡间 12），里面仍是原来的 `ExpansionTile` / `ListTile`，Key 留在它们身上。去掉两节之间的 `Divider`，节间留 24。
  3. 报告卡：行首 `JyIconTile`（周报 `Icons.article_outlined`、年报 `Icons.auto_awesome_outlined`，emberSoft 底，因为报告是伙伴写的）；标题 titleMedium；「AI：<id>」bodySmall text2；状态一行 bodyMedium text2，文字照旧。可展开的卡尾部放 `JyChevron`（signal）；不可展开的卡没有箭头，也没有按压效果。卡内的 `ExpansionTile` 去掉展开时的上下边线。
  4. 详情（展开在卡内）：第一行是区间和生成时间（bodySmall，等宽数字）；每节是 labelMedium text2 的节名加内容；话题、心情排成胶囊（raised 底、pill，`Wrap` 间距 8），每枚仍是一个 `Text`，文字照旧；年度关键词「旅行、电影」、来源范围「私聊、朋友圈」仍是一整串 `Text`，不拆成胶囊；约定和打卡天数做成两块并排的小板，每块仍是原来那一个 `Text`（「完成的约定：2 项」整串不拆）；信件放在 raised 底的引文块里，左上角一枚 ember 小光点；来源范围放最后，bodySmall text3。
  5. `JySectionHeader`「深夜电台」；期次放进一个 `JyGroup`（行间发丝线），行仍是 `ListTile`（`radio-<日期>`）：行首 `JyIconTile`（offline_pin / play_circle，emberSoft 底），标题是日期（等宽数字），副标题两行：「音色 … · 可离线播放/在线播放」和截短的脚本（bodySmall text3）。脚本从行尾挪到副标题，窄屏不挤标题。行不可点，不加按压效果。
  6. 空：`creative-empty-reports`「暂无周报或年报。」、`creative-empty-radio`「暂无电台期次。」各是一块小的内缩板（text2，装饰图标），Key 在板上，文字照旧。不用 `StatusPanel`，一页两个太重。
- 整页状态（工具行下面）：
  - 读取中：居中 `JyBusyIndicator(label: '正在读取动态')`。
  - 未连接：`StatusPanel`（Key `creative-unbound`，offline tone，`Icons.link_off_rounded`，title「还没有连接宿主」，detail「创作内容需要接入宿主连接后显示；宿主读取接口已就绪。」，fill），不给操作键。
  - 失败：`StatusPanel`（error tone，`Icons.cloud_off_rounded`，title「没能读取动态」，detail「读取失败，请稍后重试；不会自动重试。」）。操作键「手动重试」仍是 `FilledButton.tonal`（`creative-retry`），在调用处把底色换成 signalSoft、字色换成 onSignalSoft：主题里 tonal 是 ember 底（foundation 00:43 查明），交互要用 signal。
  - 会话失效：整页一个 `StatusPanel`（Key `creative-session-invalid`，`Icons.lock_outline_rounded`，title「动态已清除」，detail 原文案），没有工具行，不自动重读。

## 3 用到的 lib/ui 组件
| 用途 | 组件 | 用法 |
|---|---|---|
| 卡片 | `JySlab` | 每条报告一块；空行用 raised 小板 |
| 分节 | `JySectionHeader`、`JyGroup` | 两个节名；电台期次放进 JyGroup |
| 行首 | `JyIconTile` | 报告、电台都用 emberSoft 底 |
| 展开箭头 | `JyChevron` | 可展开报告卡的 trailing；展开状态由 onExpansionChanged 记在 State 里，失效时清空 |
| 状态切换 | `JySwitcher(fadeThrough)` | 读取中、未连接、失败、内容、失效各给 key |
| 首现 | `JyEntrance` | 首次读取成功时前 8 张卡；详情展开时各节错开 |
| 状态面板 | `StatusPanel` | 未连接、失败、会话失效 |
| 进度 | `JyBusyIndicator` | 读取中；正常动效时内部仍是 `CircularProgressIndicator` |
| 手感 | `JyPressable` | onTap 为空，包在可展开的报告卡、「刷新」「手动重试」外 |
- 不用 `JyExpand`：展开收起交给 `ExpansionTile`（测试按类型断言），时长和曲线从 motion tokens 传进去（第 4 节）。
- 不用 `JyStackDeck`、弹窗和底部面板。

## 4 五类动效落点
| 类 | 落点 | 做法 |
|---|---|---|
| 触摸 | 可展开的报告卡；「刷新」「手动重试」 | `JyPressable`：卡缩到 0.97，按钮用默认值；不可展开的卡和电台行不加 |
| 展开 | 报告详情 | `ExpansionTile` 就地展开，`expansionAnimationStyle` 用 `JyMotion.of(context, JyDurations.standard)` 和 `JyCurves.enter` / `exit`；`JyChevron` 转 180°；详情各节用 `JyEntrance` 错开 30ms |
| 缩放 | 无 | 本页没有弹窗和图片；详情就地展开，不做 MASTER 第 9 节说的缩放转场（理由见第 8 节） |
| 堆叠 | 无 | 每条报告属于不同周期或 AI，要逐条能点开；收成一摞会藏住入口 |
| 过渡 | 状态切换、列表首现 | `JySwitcher` fadeThrough；首次读取成功时前 8 张卡 `JyEntrance`，刷新后不再播 |
- 循环动画只有读取中的进度和下拉刷新的指示器，两者原来就是不定进度；不加常驻动画。

## 5 浅色 / 深色
- 颜色全取 `JyPalette` / ColorScheme：canvas 底、slab 卡、raised 胶囊和引文块、hairline 行间线；节名 text2，说明 text3；报告和电台的图标底 emberSoft、图标 onEmberSoft；可点的东西（刷新、箭头、重试）用 signal 系。页面里不写色值。
- 板不加阴影，层次靠色阶、发丝线和上沿高光（`JySlab` 负责）；展开的卡也不加阴影。
- 截图：浅色、深色各出宽屏和窄屏；状态覆盖内容（周报和年报各展开一张，另有已错过、待重试）、两节都空、未连接、失败、会话失效。

## 6 减少动效、大字号、读屏
- 减少动效由组件处理，页面不另写分支：`JyMotion.of` 归零时 `ExpansionTile` 用 `AnimationStyle.noAnimation`，否则 ≤120ms；`JyEntrance` 和按压缩放关掉，按压只留高亮；`JySwitcher` 只淡入淡出；读取中换静止的环加文字「正在读取动态」；下拉刷新照旧（系统手势，指示器本来就是进度）。
- 最大字号：标题、副标题、胶囊都换行，不截断；工具行放不下时说明换行，「刷新」不缩；约定和打卡两块小板改成竖排。
- 读屏：展开状态由 `ExpansionTile` 报出；节名保留 header 语义；装饰图标隐藏；状态不只靠颜色（已错过、待重试、可离线都有文字）；本页没有单独的图标按钮。

## 7 必须保留的测试契约（已逐个 grep `test/`、`evidence/` 核对）
- `creative_screen_test.dart`（11）：Key `creative-unbound` `creative-refresh` `creative-empty-reports` `creative-empty-radio` `creative-retry`；文案 「关系周报 / 年报」「深夜电台」「周报 · 2026-11-15」「周报 · 2026-11-08」「周报 · 2026-11-01」「年报 · 2026」「已错过」「待重试」「2026-11-17」「这一周我们聊了很多。」「旅行 · 3 次」「电影 · 1 次」「完成的约定：2 项」「打卡天数：4 天」「2026-11-11：4.0」「2026-11-12：3.5」「私聊、朋友圈」「年度关键词」「旅行、电影」「2026-08-15 一起看海」「最热闹的一天：2026-08-15」「完成的约定：0 项」「打卡天数：0 天」「暂无心情记录」「未附信件」「未记录来源范围」「AI：ai-one」「AI：ai-two」「只属于 AI 乙的信。」「只属于 AI 甲的信。」「暂无周报或年报。」「暂无电台期次。」；包含 「创作内容需要接入宿主连接后显示」「可离线播放」「在线播放」「2026-11-09 至 2026-11-15」「2026-11-15 13:31:00 UTC」「已生成 · 缺少报告内容」「读取失败，请稍后重试；不会自动重试」，必须找不到「2026-11-11：」（零计数时）「PRIVATE-UPSTREAM-SENTINEL」「PRIVATE」；byType `CircularProgressIndicator`（未连接时没有，点刷新后正好一个）`ListTile`（未连接时没有）`ExpansionTile`（报告不可用时没有）；`widget<TextButton>`（未连接时 `creative-refresh` 的 onPressed 为 null）。交互：1280×960 下点标题展开、再点收起，收起后详情不在树上；点「AI：ai-two」只展开那一行。
- `honest_copy_test.dart`（本页部分）：内容态下 Key `creative-live-note`、包含「数据来自宿主实时读取」「不触发生成或播放」，各正好一个。
- `ui_test.dart`（本页部分）：点「动态」；文案「创作内容需要接入宿主连接后显示；宿主读取接口已就绪。」正好一个，整句是一个 `Text`。
- `shell_creative_wiring_test.dart`：点「动态」（必须唯一）；未连接时包含「创作内容需要接入宿主连接后显示」一个，没有 `ListTile`；已连接时「周报 · 2026-11-15」「2026-11-16」各一个，包含「可离线播放」一个；375、768、1280 宽（高 960）下不滚动直接点「周报 · 2026-11-15」展开；reports、radio 各只读一次；lock、logout、account、session 中断后详情和标题都消失，不重读；迟到的列表响应要丢掉。
- `creative_api_test.dart`：只测接口，没有界面契约。tooltip：本页无。

## 8 风险
- 页内多一个「动态」文字，dock 点按就不唯一。
- `ExpansionTile` 改成 `maintainState: true` 或换成别的折叠组件：收起后详情还在树上，或者 byType 断言失效。所以详情就地展开，不推详情页；推出去的页在会话失效时也不会跟着清掉。
- `JySwitcher` 换 key 时旧子树没有当帧移除，中断后标题还在。
- 375×960 下第一张报告卡要在首屏：工具行和来源说明保持紧凑。
- `JySlab` 里要有 `Material`（或者 JySlab 自己用 Material 画底），否则 ListTile、ExpansionTile 的水波会被板的底色盖住。
- 胶囊每枚是独立的 `Text`，不要合成 RichText；关键词和来源范围是整串，不要拆开。测试都按整串找。
- 新文案「还没有连接宿主」「没能读取动态」「动态已清除」「正在读取动态」已 grep，不撞；新文案里不能出现「数据来自宿主实时读取」「不触发生成或播放」「创作内容需要接入宿主连接后显示」「可离线播放」「在线播放」「不会自动重试」。

## 9 待确认（不等答复，先按建议做）
1. 详情就地展开，不做缩放转场，覆盖 MASTER 第 9 节（理由见第 8 节）。
2. 页内去掉「动态」标题；状态面板标题改成「还没有连接宿主」「没能读取动态」「动态已清除」。
3. 「手动重试」在调用处改用 signalSoft 底（brief 的要求）。
4. 报告和电台的图标底用 emberSoft，算作伙伴写的内容；如果觉得 ember 用得太宽，就改成 raised 底、text2 图标。
