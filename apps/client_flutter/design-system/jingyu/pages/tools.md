# 工具页面方案（pages/tools.md）

范围：`lib/features/` 下 search、favorites、attachments、lifecycle、diagnostics 五个目录里的 7 个界面。组件按 MASTER §8 和已定签名（`showJyDialog<T>`/`showJySheet<T>` 只收 builder、`JyBusyIndicator({required label, linear, value})`、`JyExpand.maintainState`、`JySwitcher` 换 key 旧子树当帧移除、`JyPressable` 回调为空只做视觉反馈）。与 TEAM.md 冲突时以 TEAM.md 为准。

| 界面 | 文件 | 入口（不归本组） |
|---|---|---|
| 消息搜索 `SearchScreen` | search/search_screen.dart | 设置·开发者 `open-message-search`（settings_screen.dart:819） |
| 我的收藏 `FavoritesScreen` | favorites/favorites_screen.dart | 聊天 `open-favorites`（chat_pane.dart:66）→ `FavoritesScreen.open` 推 `_FavoritesRoute` |
| 附件元数据 `AttachmentsScreen` | attachments/attachments_screen.dart | 设置 `open-attachment-viewer`（settings_screen.dart:630） |
| 附件列表 `AttachmentsListScreen` | attachments/attachments_list_screen.dart | 设置 `open-attachments-list`（settings_screen.dart:593） |
| 配额与生命周期状态 `BackupQuotaScreen` | lifecycle/backup_quota_screen.dart | 设置·开发者 `open-lifecycle-status`（settings_screen.dart:797；页面在 :68 构造） |
| 备份文件预览 `BackupFilePreviewPanel` | lifecycle/backup_file_preview_panel.dart | 嵌在上一页（backup_quota_screen.dart:449） |
| 模块测试面板 `ModuleTestPanel` | diagnostics/module_test_panel.dart | settings_screen.dart:560、world_screen.dart:64 的 Scaffold body |

lifecycle 下的 backup_files.dart、backup_file_preview.dart 没有界面，不动（test/backup_file_preview_test.dart 和 backup_quota_actions_test 对它们的引用因此不受影响）。

## 0. 通用做法（各节默认遵守，只写例外）

骨架
- 推入页保留 `Scaffold` + `AppBar(title: Text(原标题))` 和自带 BackButton（`tester.pageBack()` 找 tooltip 'Back'，必须只有一个）。AppBar 外观由主题定。标题只在 AppBar，正文不放同名大标题（测试按 findsOneWidget 数标题）。
- 主体仍是一个 `ListView`，它是页面里第一个 `Scrollable`（测试用 `find.byType(Scrollable).first` 滚动）。输入框留在列表里，不做固定顶栏：TextField 内部也有 Scrollable，挪到列表前面就成了 first。
- 原来是一个 ListView 子项的，仍是一个子项（变成一块板或一组行）；不合并、不拆分，顺序不变。原因：列表里的查找只数与视口相交的子项，子项划分一变，测试里的可见性和计数就跟着变。相邻子项用间距在视觉上归组。
- 左右边距窄屏 16、宽屏（≥720）24；宽屏内容列限宽 720 居中，用 padding 算，滚动区仍占满宽度。
- 板：`JySlab`（slab 色、lg 圆角、内边距 16），板间距 12；板内次级块用 `JyTone.raised`。不用 Card、ListTile 和 elevation；原来 Card 上的 Key 原样挪到 JySlab 上。
- 只读信息行用 bodyMedium/bodySmall，不套 64 行高（64 只给可点的行）。数值、时间、计数用 `FontFeature.tabularFigures()`。
- 空、离线、失败整块替换内容时用 `StatusPanel`：Key 挪到 StatusPanel 上，原句整句作 `title`，不另加短标题（新文字可能撞上测试的 textContaining 计数，见问题 3）；需要播报的外包 `Semantics(liveRegion: true)`。
- 页内提示（操作结果、只读说明、锁定）用 `JyBanner`，Key 放在 JyBanner 上，`onClose` 留空；出现和消失用 `JyExpand`。
- 忙碌：`CircularProgressIndicator` 换成 `JyBusyIndicator(label: …)`，只在原来显示进度的地方、同样条件下出现；label 各节列出，已核对不含测试断言的子串。
- 按钮类名不变（测试有 `widget<FilledButton>`、`widget<OutlinedButton>`，还有按 Key 取的 `widget<TextField>`、`widget<Text>`），Key 仍挂在控件本身上，不挪到外层包装；外观由主题定；要次级外观的 FilledButton 只改 `style`，不用 `.tonal`（新主题里 tonal 映射到 emberSoft，那是伙伴色）。
- 现有文案、Key、Semantics 标签一字不改，显示条件不变；每条现有文字仍是一个独立的 Text（测试用 find.text 精确匹配整句、按个数计数），不拆成「标签 + 值」。新增可见文字前先对照该节的计数敏感子串。
- 不加嵌套 Navigator（search、favorites 的测试用 `find.byType(Navigator)` 取唯一的 NavigatorState）。
- 只用有限时长的动画；不用 AnimatedCrossFade 这类同时保留新旧两份子树的过渡（过渡中 find.text 会数到两份）；状态切换用 JySwitcher。

五类动效的通用落点
- 触摸：按钮由主题给按压反馈；只有点了会发生事的行或卡片才包 `JyPressable`。只读的行不加按压效果（看着能点却没反应是误导）。
- 展开：`JyExpand` 用于结果区、提示条；行内摘要「3 行 ↔ 全文」改同一个 Text 的 maxLines，外包 `AnimatedSize`（standard、进场曲线）配 `JyChevron`。
- 缩放：只有配额页的导入确认弹窗（`showJyDialog`）。其他页没有弹窗、图片、打开动作。
- 堆叠：本组没有同类通知，不用 `JyStackDeck`；列表首次出现时前 8 项 `JyEntrance` 错开 30ms，之后不再动。
- 过渡：推入由主题的 `JyPageTransitionsBuilder` 负责（`MaterialPageRoute` 自动走主题）；页内状态切换用 `JySwitcher(fadeThrough)`。

浅色与深色
- 全部取 `JyPalette.of(context)`，不写 Color 字面量。底 canvas；板 slab；输入框和板内次级块 raised；主文字 text1、说明 text2、时间和计数 text3；主按钮和展开箭头 signal；错误 danger/dangerSoft，成功 success，未接入和锁定用 warning 图标加 text2 文字。
- 浅色板为白，靠 hairline 和 edgeHighlight 分层；深色靠 canvas→slab→raised 色阶。状态不只靠颜色，文字本身说明。
- 自查：浅色、深色各一张截图；375dp、宽屏、最大字体档各看一遍（按钮行用 Wrap，放不下就换行，不截断）。

减少动效
- `JyMotion.reducedOf(context)` 为真时：JyPressable 不缩放、只留高亮；JyExpand、JySwitcher 只淡入淡出（≤120ms）；AnimatedSize 时长取 `JyMotion.of(context, JyDurations.standard)`；JyChevron 直接换方向；JyEntrance 不错开；弹窗只淡入。本组没有循环动画要替换。

## 1. 消息搜索（search_screen.dart）

布局（子项顺序和划分不变）
- `search-mechanism-note`：保持是 Text（bodySmall、text2），放在一块 raised 小板里，前面一枚 info 图标（对读屏隐藏）。
- `search-unbound`、`search-invalidated`：JyBanner(info)。
- 查询：`search-query`（TextField，raised 底、md 圆角、前缀放大镜图标）+ `search-submit`（FilledButton）。宽度够时同一行；窄屏或最大字体档放不下时按钮换到下一行（LayoutBuilder）。
- 状态：`search-idle` 原样（text2）；搜索中 `JyBusyIndicator(label: '正在搜索')`；`search-denied`、`search-unavailable`、`search-malformed` → StatusPanel（失败档）；`search-empty` → StatusPanel（空档）。这一块用 JySwitcher，子项各带原 Key。
- 结果：`search-results` 与命中卡的父子结构保持现状。命中卡 = JySlab（Key `search-hit-<messageId>`）：
  - 摘要 Text（titleMedium、text1），收起时 maxLines 3，展开显示全文（摘要本身已截到 160 字）；右上角 JyChevron。
  - 元信息：会话、发送者、类型、序号、时间、命中方式各一个 Text（labelMedium、text2，Wrap 排列，等宽数字），全部默认可见。

组件：JySlab、JyBanner、StatusPanel、JyBusyIndicator、JySwitcher、JyPressable、JyChevron、JyEntrance。

五类动效
- 触摸：提交按钮（主题）；命中卡 `JyPressable(onTap: 切换摘要展开)`，缩到 0.97。点命中卡不打开会话、不重新请求。
- 展开：命中卡摘要 3 行 ↔ 全文（AnimatedSize + JyChevron 旋转）；Semantics 的 onTapHint 写「展开摘要」/「收起摘要」（不是可见文字）。
- 缩放：不用。
- 堆叠：结果首次出现时前 8 张 JyEntrance；再次搜索换一批时重新错开（key 带查询序号）。
- 过渡：推入走主题；状态块 JySwitcher(fadeThrough)。

浅色/深色：命中卡 slab 色，摘要 text1、元信息 text2、时间 text3；深色下卡片靠色阶与底分开，浅色靠 hairline。减少动效：通用。

测试契约（search_screen_test 11 例、settings_message_search_entry_test 3 例、evidence/message_search_capture_test 1 例）
- Key：`search-query`（TextField，取 widget<TextField>、enterText）、`search-submit`（FilledButton，取 widget<FilledButton>、tap）、`search-idle`、`search-empty`、`search-results`、`search-hit-<id>`（tap）、`search-unbound`、`search-unavailable`、`search-mechanism-note`（取 widget<Text>，Key 必须仍在这个 Text 上；内容含「有界解密扫描」）；`search-denied`、`search-malformed`、`search-invalidated` 原样保留。
- byType：`SearchScreen` 唯一；`Navigator` 唯一。
- 文字：AppBar「消息搜索」只出现一次；命中卡各行的「会话：」「发送者：」「类型：」「序号：」「时间：」「命中方式：」原样。
- 卡内计数（`find.descendant(of: 卡)`，findsOneWidget）：`search-hit-msg-1` 内 conv-1、acc-2、text、12、项目代号鲸落；`search-hit-msg-2` 内 image、无文本正文。所以带 Key 的那层要包住摘要和全部元信息；卡内不加带「text」「12」的新文字（如条数、快捷键提示）。
- 页内：「不代表」findsOneWidget（机制说明里那一处）；必须不出现：secret-transport-detail，以及 FTS、BM25、相关度、排名、打分、已覆盖全部（不写「按相关度排序」「结果排名」之类）。label「正在搜索」已核对。
- 其他命中 Key：`search-hit-private-hit`（入口测试）、`search-hit-fixture-msg-1`（取证截图）。入口测试 pageBack 后找 `SettingsScreen`；截图测试断言的「开发者」是设置页分组标题，不归本组。
- 交互顺序：输入 → 提交 → 结果；点命中卡 → 仍在本页、无请求；pageBack 回上一页。

风险
- `search-idle` 等在提交后一帧就要 findsNothing：依赖 JySwitcher「旧子树当帧移除」。
- 命中卡变高后，800×600 里后面的卡可能出视口；若影响断言，测试先 ensureVisible（候选，见文末）。

## 2. 我的收藏（favorites_screen.dart）

硬约束：`_FavoritesRoute` 在有新路由压上来（didChangeNext）或完成（didComplete）时让页面失效。本页不推任何路由：不用 showJyDialog/showJySheet、PopupMenu、DropdownButton、长按菜单、选择器。Tooltip 走 Overlay，可以用。`FavoritesScreen._`、`canOpen`、`open`、`_FavoritesRoute`（MaterialPageRoute、allowSnapshotting: false）都不改。

布局（保留 SafeArea + Center + maxWidth 720 + ListView.builder，第 0 项是头部）
- 头部板（JySlab）：说明「只读显示宿主返回的当前可见收藏，不打开消息、链接或文件。」（bodySmall、text2）；下面一个 JySwitcher 区：
  - 未读取：`load-favorites`（FilledButton.icon、bookmark_outline、「读取收藏」）。
  - 读取中：`JyBusyIndicator(label: '正在读取收藏', linear: true)`（原 semanticsLabel 原样作 label）。
  - 失效、拒绝、不可用、响应无效、空：StatusPanel，Key 用原来的 `favorites-invalidated` / `-denied` / `-unavailable` / `-malformed` / `-empty`，原句作 title，外包 liveRegion。
- 收藏行：每条仍是 builder 的一项，一块 JySlab（间距 8）：
  - 行首 `JyIconTile`，图标按类型（chat_bubble_outline、notes、link、insert_drive_file_outlined），颜色统一，类型靠图标和文字区分。
  - 标题 titleMedium（`title ?? 类型名`，maxLines 2）；时间行 labelSmall、text3、等宽数字（「类型名 · 时间 UTC」或「时间 UTC」）。
  - 消息、文本类型下面是摘要（bodyMedium、text2），收起时 maxLines 3。
- 只有带摘要的行可点：点按展开摘要全文，右侧 JyChevron。链接、文件行不可点、不加按压效果。

五类动效
- 触摸：读取按钮；带摘要的行 JyPressable（0.97）。
- 展开：摘要 3 行 ↔ 全文（同一个 Text，AnimatedSize + JyChevron）。不新增任何字段（测试断言私有字段不渲染）。
- 缩放：不用（不能开弹窗）。
- 堆叠：首次读取成功后前 8 行 JyEntrance。
- 过渡：路由本身是 MaterialPageRoute，走主题；头部状态 JySwitcher。

浅色/深色、减少动效：通用。

测试契约（chat_favorites_route_test 5 例，视口 390×844；evidence/favorites_read_capture_test 1 例）
- Key：`load-favorites`（FilledButton.icon，`widget<FilledButton>` 能取到，保留）、`favorites-invalidated`（findsOneWidget）及其余状态 Key；入口 `open-favorites` 在 chat_pane.dart。
- 文字：「Editorial notes」；预览原文 findsOneWidget（展开不能复制出第二份；取证截图用 find.text 整句匹配「下次读书会讨论《海边的房间》。」，摘要前不加前缀）；「链接收藏」（无标题时的类型名，测试会点它）；私有字段、hidden 内容、fixture.invalid 都 findsNothing。取证截图里的「读书小组」、`create-group`、`refresh-conversations` 属于聊天页，不归本组。
- byType：`Navigator` 唯一。
- 交互顺序：打开不自动读取 → 点读取才读一次 → 点「链接收藏」：不选会话、不再读、预览仍在 → 同帧锁定再解锁、退出、换账号、会话替换：结果清空、显示失效、读取按钮消失 → 有路由压上来再移开：迟到结果不发布（skipOffstage: false 也找不到预览）。

风险
- 任何会推路由的组件（包括以后 lib/ui 里可能加的菜单）都会让页面失效：每批代码逐个查。
- 展开只能用 AnimatedSize（一份 Text），不能用 AnimatedCrossFade。
- 「链接收藏」行不可点，测试点它时什么也不发生，符合断言。

## 3. 附件元数据（attachments_screen.dart）

布局（顺序同现状：输入、按钮、未接线说明、提示、元数据）
- 查询：`attachment-id-input`（TextField，raised 底）+ `attachment-read`（FilledButton）；宽屏同一行，窄屏换行。
- `attachment-unbound`：JyBanner(info)，显示条件不变。
- 结果区：`attachment-notice` → JyBanner(error)；`attachment-metadata` → JySlab，里面是 JyGroup 行：类型·MIME、大小、状态、会话，每行行首 JyIconTile，文字整句一个 Text。两者各自用 JyExpand 出现。

五类动效
- 触摸：读取按钮。
- 展开：提示和元数据板用 JyExpand（展开、内容淡入上移 8）；maintainState 为 false，收起后子树移出，正好满足读之前 findsNothing。
- 缩放：不用。
- 堆叠：元数据行首次出现时 JyEntrance（4 行，总错开 <120ms）。
- 过渡：推入走主题。

浅色/深色、减少动效：通用。

测试契约（attachments_screen_test 3 例、settings_attachment_entries_test 2 例；入口 Key `open-attachment-viewer` 在设置页）
- Key：`attachment-unbound`、`attachment-read` 在 pumpWidget 后首帧就要在；`attachment-id-input`（enterText）；`attachment-metadata`（读之前 findsNothing，读后 findsOneWidget）；`attachment-notice`。
- 精确文字（find.text 整句）：「类型：image · MIME：image/png」「大小：2.0 KiB」「状态：抽取中」「会话：conv-1」。
- textContaining：「未找到或读取失败」；PRIVATE-DETAIL 不出现。
- 标题「附件元数据」只在 AppBar（入口测试转场中同时看到设置行和标题，用 findsWidgets）。

风险：首帧断言要求读取按钮和未接线说明不能放在任何延迟构建的容器里（JyEntrance 只改透明度和位移，构建不延迟，可以用）。

## 4. 附件列表（attachments_list_screen.dart）

布局（顺序同现状）
- `attachments-unbound`：JyBanner(info)，条件不变。
- 查询：`attachments-conversation`（TextField）+ `attachments-refresh`（FilledButton，未接线时不显示，条件不变）。
- 状态：读取中 `JyBusyIndicator(label: '正在读取附件')`；`attachments-denied`、`attachments-unknown` → StatusPanel（失败档）；`attachments-empty` → StatusPanel（空档，原句）。
- 附件卡：每条一个子项（现状），JySlab 带 `attachment-item-<id>`；行首 JyIconTile（按类型选图标），右侧：名称或类型（titleMedium），会话、大小、状态各一个 Text（bodySmall、text2）。卡片只读，不可点。
- `attachments-load-more`：TextButton，居中，禁用逻辑不变。

五类动效
- 触摸：刷新、加载更多按钮；卡片只读，不加按压效果。
- 展开：不用：每张卡的字段测试都要求默认可见；状态块高度变化外包 AnimatedSize。
- 缩放：不用。
- 堆叠：首屏前 8 张 JyEntrance；加载更多追加的卡不再错开。
- 过渡：推入走主题；状态块 JySwitcher。

浅色/深色、减少动效：通用。

测试契约（attachments_list_screen_test 7 例、settings_attachment_entries_test 2 例；入口 Key `open-attachments-list` 在设置页）
- Key：`attachments-unbound`、`attachments-refresh`（tap；未接线时 findsNothing）、`attachments-empty`、`attachments-denied`、`attachments-unknown`、`attachments-conversation`（enterText）、`attachments-load-more`（ensureVisible 后 tap；没有更多时 findsNothing）、`attachment-item-att-1`、`attachment-item-att-2`、`attachment-item-att-3`。
- textContaining：「会话：conv-1」「会话：未绑定会话」「大小：3.0 MiB」「无权限」（findsOneWidget）、「状态：已抽取」（findsWidgets）；secret-denied-detail、secret-transport-detail 不出现。
- 计数敏感：「无权限」只能有一处，StatusPanel 不另加含它的标题；label「正在读取附件」已核对。
- 标题「附件列表」只在 AppBar。

风险：卡片变高后，默认 800×600 里 att-2 可能被挤出视口（测试不滚动就断言）。卡高控制在约 140 以内；仍出视口就把该断言改成先 ensureVisible（候选，先报 lead）。

## 5. 配额与生命周期状态（backup_quota_screen.dart、backup_file_preview_panel.dart）

布局（子项顺序和划分不变）
- 读取中：`JyBusyIndicator(label: '正在读取用量')`，原位置、原条件。
- `lifecycle-unknown`：StatusPanel（失败档），原卡片文字原样（含「状态未知」「不会自动重试」）；原来两段就 title + detail，不合并、不改写。
- 用量（原卡片 → JyGroup，header 沿用原卡片标题，没有就不加）：「已用：…」「配额：…」两枚 raised 小块并排（titleLarge、等宽数字，整句一个 Text）；各类型计数和「对象合计：…」为行；「不代表可用」类说明放在 footer（bodySmall、text3）。不加用量条（问题 7）。
- 导出与导入：说明文字（导出范围、不含人格、不是完整备份、含明文、重启不保留）bodySmall、text2；按钮用 Wrap（间距 12）：`export-lifecycle` FilledButton 主色；`save-lifecycle`、`import-lifecycle` 仍是 FilledButton，style 改成次级（raised 底、text1 字、outline 边）；`lifecycle-write-locked` → JyBanner(info)。
- 清理预览：读取中 `JyBusyIndicator(label: '正在读取清理预览')`；`cleanup-preview-unknown` → JyBanner(error)；每个运行日一组（「运行日：…」作组头，视频、语音等计数各一个 Text）；`cleanup-preview-refresh` 仍是 OutlinedButton；`cleanup-execution-gap`（两个分支）→ JyBanner(info)。没有执行按钮。
- `lifecycle-action-notice`：JyBanner，成功类（已导出、已保存、导入完成、已清除）用 success，失败类用 error，其余 info；仍在列表末尾（问题 6）。

导入确认弹窗：`showDialog` → `showJyDialog<LifecycleImportMode>`，参数原样；builder 仍返回 StatefulBuilder → AlertDialog，content 的 SingleChildScrollView、两个模式选项、「取消」TextButton、`import-confirm` FilledButton 都不变。overlay 色、xl 圆角、缩放进场由 showJyDialog 和主题给。

备份文件预览面板
- `preview-backup-file` 仍是 OutlinedButton；忙碌时按钮文字「正在选择或预检…」不变，不另加 JyBusyIndicator。
- `backup-file-preview-notice` → JyBanner(info)；`backup-file-preview-summary` → raised 子块，行文字原样；两者用 JyExpand 出现。
- 不显示文件路径和 owner 原值。

五类动效
- 触摸：各按钮；弹窗里的两个模式选项（主题的选中反馈）。
- 展开：预览摘要、预览提示、动作结果、写入锁提示用 JyExpand。
- 缩放：导入确认弹窗（0.94→1 淡入，退场 <300ms）。
- 堆叠：清理预览的运行日组首次出现时 JyEntrance；用量行不动。
- 过渡：推入走主题；用量块「读取中 ↔ 未知 ↔ 数据」和清理块各用 JySwitcher。

浅色/深色、减少动效：通用；弹窗遮罩用 scrim。

测试契约（backup_quota_screen_test 4 例、backup_quota_actions_test 16 例、lifecycle_backup_preview_route_test 6 例、evidence/backup_file_preview_capture_test 1 例、settings_developer_groups_test）
- Key：`export-lifecycle`、`save-lifecycle`（FilledButton）、`import-lifecycle`（FilledButton，ensureVisible）、`import-confirm`、`import-mode-personaOnly`、`import-mode-personaAndConversations`（tap）、`lifecycle-unknown`、`lifecycle-write-locked`、`lifecycle-action-notice`、`cleanup-preview-refresh`、`cleanup-preview-unknown`、`cleanup-execution-gap`；`cleanup-lifecycle` 必须不存在；`preview-backup-file`（OutlinedButton，element、tap）、`backup-file-preview-summary`、`backup-file-preview-notice`。
- byType：`TextField` 不存在（本页不加输入框）；`Scrollable.first` 是主列表；`BackupQuotaScreen` 唯一，pageBack 回设置。
- 文字（除注明外都是 textContaining、findsOneWidget；新增文字不能再含这些子串）：
  - 标题：AppBar「配额与生命周期状态」（find.text，只一次；取证截图也找它）。
  - 用量：「已用：5.0 MiB」「配额：20.0 GiB」「conversations：2」「对象合计：5」「状态未知」「不会自动重试」；「不代表可用」findsWidgets。
  - 导出导入：「已导出到内存」「导入完成」「会话 1」「当前仅导出有权读取的聊天记录」「不包含人格、记忆和附件内容」「不是完整账号备份」「已保存导出文件：jingyu-export.json」「文件含聊天明文」「12 B」「已取消保存」「导出文件保存失败或结果未确认」「未接线本机文件保存」「已清除内存中的导出内容」「导出失败或结果未确认」「未接线宿主连接」；「重启后不会保留」findsWidgets；弹窗「取消」（find.text，只一个，测试点它）。
  - 清理预览：「运行日：2026-03-01」「运行日：2026-03-02」「视频：1」「视频：2」「视频：3」「语音：1」「语音：4」「执行尚未提供」「不会删除任何数据」「清理预览读取失败」「宿主未提供清理 HTTP 接口」；「语音：2」「视频：0」findsWidgets。
  - 备份文件预览：「已取消选择」「清单计数：会话 1，消息 1」「不属于当前账号」；「正在选择或预检…」（find.text）选择中在，pump 后 findsNothing：保持现有异步时序。
  - 必须不出现：secret-detail-xyz、secret-persona-text、manifest.json、private、secret-xyz、secret-cleanup-xyz、fixture-other-owner。
  - label「正在读取用量」「正在读取清理预览」已核对，不含以上子串。
- 交互顺序：导出 → 保存 / 取消保存 / 保存失败 / 未接线；导入 → 弹窗 → 选模式 → 确认或取消（取消后不导入）；清理预览刷新；预览：选文件 → 摘要或提示，第二次选择取消。
- 视口：默认 800×600；预览测试有一例 768×900。

风险
- 本页最长。分区变高后，backup_quota_screen_test 里不滚动就断言的按钮可能出视口：板内边距不再加大，按钮行紧凑；仍不行就在该测试里先 ensureVisible（候选）。
- 计数断言和视口有关：有些 findsOneWidget 可能依赖下方分区在视口外，改布局后要逐条跑测试，不能只做静态核对。
- 三个 FilledButton 视觉偏重：用 style 分主次，不换类。

## 6. 模块测试面板（module_test_panel.dart）

宿主：settings_screen.dart:560、world_screen.dart:64 把它当 Scaffold body，AppBar 和返回归宿主。本面板只改 ListView 内容，自带左右边距。测试视口 1200×2600，内容全部在视口内，所以本页模块行可以合成一个 JyGroup（通用规则的例外）。

布局
- 说明：`module-test-help`，raised 小板，info 图标加原文（bodySmall、text2）。默认可见，不折叠。
- 模块组（JyGroup）：每个模块一行 `module-row-<id>`：JyIconTile（模块图标）、名称 titleMedium（如「世界与形象」）、`module-availability-<id>` 原文（bodySmall、text2）。行只读、不可点；行尾状态图标（占位：空心圆、text3；未接入：warning），图标对读屏隐藏，文字说明状态。
- 测量板（JySlab）：「FPS：…」用 headlineSmall、等宽数字（整句一个 Text）；状态行（bodyMedium）；按钮 Wrap：`module-test-start` FilledButton.icon；`module-test-stop` 由 `FilledButton.tonalIcon`（:123）换成 `OutlinedButton.icon`，Key、文字、图标不变；`module-test-reset` TextButton.icon。
- 探针板：`module-test-probe-result`（raised），里面 `module-test-probe-status` 和原有说明。

五类动效
- 触摸：三个按钮（主题）；模块行只读，不加按压效果。
- 展开：不用：说明、模块行、探针卡在 pumpWidget 后的首帧就要断言。
- 缩放：不用。
- 堆叠：不用 JyEntrance：本页测试只 pump 不 settle（问题 5）。
- 过渡：状态行「未开始 ↔ 测量中」用 JySwitcher(fadeThrough)（测试 pump 一帧后断言新文字在、旧文字不在）；FPS 每 500ms 更新，不做动画。
- 测量用的 `Timer.periodic(500ms)` 是原有逻辑，不改；测量中不加转圈，状态文字已说明。

浅色/深色、减少动效：通用。

测试契约（module_test_panel_test 4 例，只用 pumpWidget/pump）
- Key：`module-test-start`、`module-test-stop`（tap）、`module-test-help`、`module-availability-<id>`、`module-test-probe-result`（首帧）；`module-row-<id>`、`module-test-reset`、`module-test-probe-status` 原样保留。
- 精确文字：「世界与形象」「状态：未开始（点击开始测量）」「FPS：0.0」「状态：测量中…」。
- 计数：「不代表模型可用或已授权」×3、「占位：入口存在」×3（findsNWidgets）、「未接入：渲染/能力尚未接入外壳」×1、「GPU 显存」findsWidgets；「本面板证明」「不证明：模型可用」「不代表性能差」「不代表宿主可用性或任何 AI 能力」各一处。状态图标和分组都不带文字。
- 探针状态（textContaining）：首帧「探针状态：未配置」一处；开始后 pump 一帧，「探针状态：测量中」一处、「探针状态：未配置」没有；停止后 pump 一帧，「探针状态：测量中」没有，「探针状态：已测得」与「探针状态：未配置」合计一处。所以探针状态换内容也要在一帧内完成（JySwitcher 或直接换 Text）。
- 交互顺序：开始 → 测量中 → 停止；重置。

风险：宿主若再给 body 包 padding，会和面板自带边距叠加（问题 2）。stop 换成 OutlinedButton.icon 后，测试只按 Key 点，没有类型断言。

## 测试改动候选（只改定位，先报 lead，加入写入范围后再改）

- test/backup_quota_screen_test.dart：不滚动就断言的按钮若出视口，先 ensureVisible。
- test/attachments_list_screen_test.dart：att-2、att-3 若出视口，先 ensureVisible。
- test/search_screen_test.dart：后面的命中卡若出视口，同上。

写完代码按真实布局跑一遍再确定，不预先改。

## 待确认的问题（不阻塞，按括号里的默认做）

1. `JyBusyIndicator` 的 label 是可见文字还是只给读屏？（按可见文字核对计数敏感子串。label：正在搜索、正在读取收藏、正在读取附件、正在读取用量、正在读取清理预览。）
2. ModuleTestPanel 的宿主（settings、world）能否不再给 body 包 padding、背景用 canvas？（面板自带 16/24 边距；要宿主改由 lead 转给 settings 和 world。）
3. StatusPanel 的 title 用原句整句、不加短标题，可以吗？StatusPanel 自带 liveRegion 吗？（整句作 title；外包一层 liveRegion。）
4. JyBanner 能带 Key 吗？有没有 warning 档？（Key 放在 JyBanner 上；锁定和缺口用 info。）
5. JyEntrance 的错开用不用 Timer？如果用，不 settle 的测试结束时会留下 pending timer。（诊断页不用 JyEntrance；其他页的测试都会 settle。）
6. 配额页的动作结果提示在列表末尾，离按钮远。挪进操作区更好，但改顺序会影响测试的 scrollUntilVisible（向下滚找不到上方的提示）。（不挪。）
7. 用量要不要加一条确定进度条？页面反复声明「不代表可用」，进度条容易被读成可用余量。（不加。）
8. 命中卡和收藏行点按只展开摘要、不打开消息，符合只读定位。请确认没有「打开会话」的计划。（按只展开做。）
9. `open-favorites` 入口在 chat_pane.dart:66，各设置入口行在 settings_screen.dart，都不归本组；入口样式由对应负责人定。
10. 契约片段把 owner_chat_entry_test 里点「取消」也归到本组，应是脚本误归（那是别处的弹窗）。（本组不处理。）
11. pageBack 依赖 BackButton 的 tooltip 'Back'；应用以后若加中文本地化，测试的 pageBack 会找不到。这是外壳层面的事，提醒一下。
