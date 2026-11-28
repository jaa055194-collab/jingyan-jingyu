# AI 配置页面方案（pages/ai-config.md）

范围：`lib/features/ai_config/**`（13 个文件，约 7000 行）。本文补充 MASTER.md，冲突时以本文为准；组件签名以 MASTER 第 8 节（含 lead 11-24 20:15 的补充）为准。逐文件盘点和契约底稿在工单目录 `.team-notes\ai-config*`，不进仓库。

## 1. 界面清单

| 界面 | 文件 | 内容 |
|---|---|---|
| AI 运行配置（桌面写入台） | ai_config_editor.dart | 一个 ListView：页头（选 AI、档案）→ 伙伴卡 5 张 → 人格 → Provider → 聊天绑定 → 预算 |
| AI 配置（安卓详情） | android_ai_config_details.dart（editor 的 part） | 伙伴头 → 读取 → 模型与 API → 人格 → 活人感 4 卡 → 高级配置（读取后出现，默认收起） |
| 伙伴行为卡 | owner_reply_preferences_section、owner_rule_greeting_card、owner_model_proactive_card、owner_social_level_section | 读取 → 编辑 → 卡内复核 → 已授权/未授权，各有通知 |
| 记忆 | owner_memory_notes_section、owner_auto_memory_section | 读取 → 授权开关（弹窗确认）→ 条目增删改、清空（弹窗确认） |
| 模型能力与预算诊断 | model_diagnostics_screen.dart | 只读：目录、今日用量、7 日趋势、预算上限四块，按需读取 |
| AI 运行配置体检 | ai_config_panel.dart | 只读：人格、绑定、预算、Provider 四个条目 |
| 人格历史 | persona_history_screen.dart | 嵌在人格组里，分页只读 |
| 人格卡解析、文件选择 | persona_card_import.dart、persona_file_picker.dart | 纯逻辑，不改 |

桌面伙伴卡 5 张：回复偏好、规则问候、记忆便签、自动记忆、主动联系。安卓活人感 4 卡：社交等级、回复偏好、规则问候、主动联系（记忆在高级配置里）。

## 2. 总体做法

- 组件：`JySlab` `JyGroup` `JySectionHeader` `JyIconTile` `JyExpand`+`JyChevron` `JyPressable` `JySwitcher` `JyStackDeck` `JyEntrance` `JyBanner` `JyPresenceOrb` `JySonarPulse` `showJyDialog` `StatusPanel`。表单控件仍用 Material（TextField、FilledButton、OutlinedButton、TextButton、ChoiceChip、SwitchListTile、DropdownButton，测试按类型找），外观交给主题。
- 版式：底色 canvas，每组一块 `JySlab`（组间 12），去掉 Card 和整宽 Divider；组内多行用 `JyGroup` 的发丝线；页内小节（活人感）用 `JySectionHeader`。左右边距窄屏 16、宽屏 24，内容最宽 720 居中（安卓保留 680），滚动区仍占满整宽。宽屏短字段两列，可用宽度 <560 或字体放大后退回单列，不截断。
- 标题只在 AppBar（'AI 运行配置''AI 配置''模型能力与预算诊断''AI 运行配置体检'），正文不放同名大标题（测试要求只出现一次）。
- 组头：`JyIconTile` + 标题（titleMedium）+ 右侧操作。可折叠的组头整行 `JyPressable`（onTap 切换，带按钮语义和展开状态）+ `JyChevron`，内容放 `JyExpand`。
- 颜色：ember 只给伙伴：安卓头部和桌面选 AI 行的 `JyPresenceOrb`，人格、记忆、活人感、伙伴卡的 `JyIconTile`，「已授权…」状态胶囊（emberSoft 底、onEmberSoft 字、图标加原文案）。signal 给交互和技术配置：按钮、ChoiceChip 选中、开关、进度线、焦点、锚点胶囊，Provider、绑定、预算、诊断的 `JyIconTile`。success、warning、danger 只表示结果，都带图标和文字。
- 图标：人格 person_outline、Provider dns_outlined、聊天绑定 link_rounded、预算 data_usage_rounded、记忆便签 sticky_note_2_outlined、自动记忆 auto_awesome_outlined、主动联系 waving_hand_outlined、规则问候 schedule_outlined、回复偏好 tune_rounded、社交等级 diversity_3_outlined、模型 memory_outlined。
- 保存状态和错误就近：结果出现在触发它的组底部、操作键上方。页面级状态（未连接宿主、会话失效、整页读取失败）留在页顶；整页的空、离线、失效用 `StatusPanel`，Key 挂在 StatusPanel 上（这几个 Key 测试只数个数），原文案原样放进 title 和 detail（原来几个 Text 就几段，不拆句，不加同义新标题）。
- 数字（版本、token、时间、偏移、计数）用等宽数字。

## 3. 各界面

**桌面写入台**：保持单一 `ListView`，每组仍是它的一个子项，顺序不变（测试的查找默认只数视口里的列表子项；换成 SingleChildScrollView 会把页头说明也数进去，'key_mask' 这类精确计数就会断）。

- 页头板：说明（text2）；选 AI 行 = 28dp 光核 + `ai-config-write-select`（DropdownButton，raised 底）；'档案：<id>'；无 writer 时一条 warning 行 '未连接宿主；无法编辑配置。'，表单照常显示但禁用。
- 伙伴卡 5 张不折叠（有读取结果，收起会卸载）。人格、Provider、聊天绑定、预算四组可折叠，默认展开；收起时组头显示一行摘要（只在收起时渲染，不和正文重复）；help 说明是组头下第一行，Key 不变。
- 写入状态 `ai-config-write-status`（内含 `ai-config-write-state`：'成功' success、'失败/未知' danger，各带图标）从页顶移到触发它的组 `ai-config-group-<name>`（persona/provider/binding/budget）里、该组操作键正下方（人格组在历史之前），图标键 `ai-config-write-icon`，外层 `Semantics(liveRegion)`；页级状态（档案解析失败）仍在页顶。同一时刻只有一处。
- 人格组：导入两键用 Wrap 排一行（放不下换行），`persona-import-status`、`-error` 紧随其下；P0、P1、P2 三个多行框；当前版本 + 修改原因（宽屏两列）；'初始化人格'（Filled）与 '保存人格修改'（Outlined）同一行；人格历史在组底。
- Provider 组：名称和 Base URL 一行，API Key 单独一行（遮蔽），能力和已有 ID 一行；结果只显示掩码。
- 聊天绑定组：目录模型列表放在 raised 小板（最高 176，内部滚动），行是 ListTile（Key 留在 ListTile 上）外包 `JyPressable`，选中 signalSoft；'读取已保存 Provider 模型' 仍是 OutlinedButton。
- 预算组：每日上限和时区偏移一行；分层上限、能力上限两个多行框。

**安卓 AI 配置**：保留 `SingleChildScrollView`（`android-ai-config-scroll`）和 680 最宽。

- 伙伴头板：`JyPresenceOrb`（48）+ 名字（`android-ai-config-name`，headlineSmall）+ 一句说明；宿主离线时光核 offline，说明换离线文案。下一行：'读取配置'（FilledButton）+ 两枚锚点胶囊 '人格''活人感'（TextButton 外包 `JyPressable`）。
- `android-ai-config-progress` 保留 4dp 占位，忙时 signal 进度线（原条件）；读取问题用 `JyBanner`（error）。
- 模型与 API 板：聊天、快脑两行 `JyGroup`；模型名 SelectableText，API 地址 text3。
- 人格板：版本和锁定状态胶囊；三层是可折叠行（默认收起，同现状）；编辑草稿在 raised 底里，增删字段的 Key 不变；保存键内 16dp 圆形进度 + '正在保存并核对…'（全页只此一处圆形进度）；结果用 `JyBanner`（success/error），出错时 '重新读取配置' 键放在提示条下。
- 活人感：`JySectionHeader`（ember 图标 + '活人感'）+ 原说明；四张卡不折叠（测试跳锚点后直接点读取）。
- 高级配置：原 ExpansionTile 换成可折叠组头 + `JyExpand`，默认收起，读取前不出现；内含写入状态、Provider/绑定/预算、记忆便签、自动记忆。

**卡片与其他页**

- 伙伴行为卡：一块 slab：标题 + 状态胶囊（'已授权…' ember，'未授权…' 中性，胶囊里就是原文案）+ 说明；读取键在说明下；时间字段宽屏两列；「复核」替换卡内容（`JySwitcher`）；主动联系的账户级停止放卡底，停止复核用 danger。社交等级的五枚 ChoiceChip 用 Wrap。
- 记忆便签、自动记忆：授权开关（SwitchListTile）在顶部；计数胶囊（等宽）；条目 ListTile，编辑、删除图标键保留 tooltip；新增的单行输入用 `JyExpand` 展开，编辑时该行当帧换成输入框（原文和输入框不同时在树上）；'清空全部…' 放底部，danger 文字键；确认弹窗改 `showJyDialog`（AlertDialog 和 Key 不变）。
- 模型诊断：ListView；介绍板；四块 slab，读取键宽屏在组头右侧、窄屏在副标题下（仍是 TextButton）；状态行 = 图标 + 原文案（未读取 text3、已读取 success、未知 warning、无权或不可用 danger）；读取中只有文字和静态图标；7 日趋势每天一行加一条静态横条（按 tokens 比例，ExcludeSemantics），含未结算记录的日子用 warning 图标。
- 运行配置体检：四个条目各一块 slab，头部仍是一整句 '<标题> · <状态>'（测试按整句找），前加状态图标；首次加载用 `JyEntrance` 错开；页内不放 FilledButton、TextField、Switch。

## 4. 五类动效

1. 触摸：可折叠组头用 `JyPressable`（onTap 切换）；目录模型行、锚点胶囊在原控件外包 `JyPressable`（onTap 为空，只加手感）；其余按钮和 ChoiceChip 靠主题的按下态。
2. 展开：桌面四个表单组、安卓高级配置和人格三层、便签新增行用 `JyExpand`（组头配 `JyChevron`）。读取中与结果、通知和状态文案、编辑行的更替一律当帧替换（`JySwitcher` 或直接条件渲染），不用 JyExpand 收起，也不用 AnimatedSwitcher 默认的淡出：owner_social_level_android_test 有 11 处在一次 pump 后就断言 select、save、'未配置' 等已不在，settings_persona_history_route_test 有 5 处断言版本条目和翻页键已不在。会话失效、锁定后清空导入也直接移除。
3. 缩放：自动记忆 4 个、便签 4 个、粘贴人格 1 个弹窗走 `showJyDialog`（0.94→1）；进入详情、诊断、体检页用主题的页面转场。
4. 堆叠：人格历史读取后放进 `JyStackDeck`，默认展开（测试逐条找版本和标签），摘要行只写「已读取 N 条历史」，不重复任何版本文案；用户点摘要可收成一摞；换页和清空时整块换 Key 或移除，当帧生效；'读取下一页' 在牌堆外。其他列表测试要逐项找 Key，不堆叠。
5. 过渡：卡内「编辑 ↔ 复核」、人格「浏览 ↔ 编辑」、保存键文字、各卡通知和状态行的切换用 `JySwitcher`（fadeThrough，旧子树当帧移除）；锚点跳转和卡片读写后的 ensureVisible 改用 `JyMotion.of(context, JyDurations.emphasized)` + `JyCurves.emphasized`。

安卓头部光核：平时 idle，宿主离线 offline，读取中 thinking（只在进度线显示的同一时段循环），读取成功放一次 `JySonarPulse`（trigger 是读取代次）。体检、诊断页不放光核。

## 5. 浅色与深色

只取 `JyPalette` 或 ColorScheme：输入框和板上的小板 raised，弹窗 overlay；ember 胶囊 emberSoft/onEmberSoft；危险操作 danger 字，不用实底。两种主题各截 4 张自查：桌面写入台顶部、安卓详情（读取后）、活人感、诊断（已读取）。

## 6. 减少动效

全部经 `JyMotion`：展开、弹窗、过渡只剩 ≤120ms 淡入淡出；`JyEntrance`、声呐波、弹簧关掉；光核 thinking 换静态环（旁边本来就有 '正在读取…' 一类文字）；锚点跳转直接定位。

## 7. 必须保留的测试契约（按测试文件）

通用：主滚动是树里第一个 `Scrollable`（测试都用 `find.byType(Scrollable).first` 向下 `scrollUntilVisible`，回顶用 `drag(0, 6000)` 或 `jumpTo(0)`）；各组顺序不变；滚动区上不盖悬浮物（ensureVisible 后要 hitTestable）；卡片能直接放进 `SingleChildScrollView`（测试这样挂，卡内不用 Expanded 和无界列表）；Key、文案、tooltip 原样，Key 留在原来的控件类型上（除第 2 节的 StatusPanel 外；通知和状态的 Key 仍挂在 Text 上，外面再包胶囊或提示条；按钮、开关、输入框、ChoiceChip 同理）；有测试在一次 pump 后就断言 findsNothing（见第 4 节第 2 条）。Card、ExpansionTile、Divider 没有测试按类型找，可以替换；ListTile 保留在目录模型行（settings_chat_model_picker_test 按类型取）和记忆条目上。AppBar 和列表前不放输入框或横向滚动区，否则 Scrollable.first 会变。

- ai_config_editor_test（9）：provider-{name,base-url,api-key,capabilities,create}、persona-{p0,p1,p2,initialize}、binding-{provider,model,save}、budget-{daily,offset,layers,caps,save}、help-{persona,provider,binding,budget}、ai-config-write-{status,state,icon}、ai-config-group-{persona,provider,binding,budget}（写入状态只在触发它的组内、操作键下方，全页 1 个）；TextField(provider-api-key).obscureText 为真；无 writer 时 FilledButton(provider-create).onPressed 为空；'成功''失败/未知' 精确各 1；包含 '****abcd''未连接宿主''历史可回滚''key_mask''Provider ID 与模型 ID''预算四字段''能力限额''未认证或无权限''操作失败或结果未知' 各 1；'super-secret-key' 永不出现；顺序 人格 < Provider < 绑定 < 预算；预算组必须在最后，保存键下面不放高内容（测试 ensureVisible(budget-save) 后再上拖 250 才点它）。
- persona_import_ui_test（6）：persona-import-{file,paste,status,error,paste-dialog,paste-input,paste-apply,paste-cancel,paste-error}、persona-{p0,edit,initialize}、ai-config-session-invalid；TextField 按 Key 取；包含 '仅填充表单''粘贴内容''64 KiB''synthetic-card.json''P0 2 项'；粘贴弹窗改走 `showJyDialog` 后 Key 仍在 Dialog 上。
- owner_reply_preferences_ui_test（9）、owner_rule_greeting_ui_test（9）：经 test/support 夹具从设置进入写入台（Scrollable.first 向下找 open-ai-config-write，再找卡）；按类型 DropdownButton 切换 AI 后 '档案：profile-b'；owner-reply-{length-brief,length-detailed,format-paragraphs,format-bullets}、owner-reply-preferences-{read,review,save,disable,clear,clear-confirm,cancel,confirm,state,saved,conflict,unknown,unavailable,no-target}、owner-rule-greeting-{read,local,offset,quiet-start,quiet-end,review,cancel,confirm,disable,state,conflict}；类型 DropdownButton、FilledButton、TextField、Text；'当前选择尚未保存。''已保存：详细 · 不指定''简短''要点''未授权规则问候''已授权规则问候''不保证发送''延至静默结束''UTC+08:00' 原样；上游原文和 URL 的断言（'secret upstream payload' 等）原样保留。
- owner_rule_greeting_settings_panel_test（5）：设置里的全局面板（open-owner-rule-greeting-global、owner-rule-greeting-global-*，归 settings）和写入台的 owner-rule-greeting-{read,offset} 同测；类型 SwitchListTile、TextField、FilledButton。
- ai_config_panel_test（7）：ai-config-select、ai-config-unknown、ValueKey('ai-config-entry-<标题>')；'AI 运行配置体检' 精确 1；包含 '不等于模型可用''人格 · 已配置''chat → prov-1 · gpt-x''预算 · 未配置''掩码：****abcd（不是密钥）''不会自动重试''未知不代表未配置'；'secret-detail-xyz' 不出现；页内没有 TextField、Switch、FilledButton。
- android_ai_config_editor_test（11，宽 375/768/1280、高 700）：android-ai-config-{name,models,progress,aliveness,to-aliveness}、android-ai-config-read（FilledButton，打开即可点）、android-persona-{edit,save,reason,value-p0-bio,value-p1-tone,remove-p1-obsolete}（save 是 FilledButton，value-* 内含 TextField）、ai-config-session-invalid；aliveness 子树内 owner-{reply-preferences,rule-greeting,model-proactive}-read 可点；owner-social-level-{read,L0,save}；ai-config-write-select 不出现；'琉璃鲸' 全页精确 1；'人格已保存。''已授权规则问候''已授权模型主动联系' 精确；'高级配置' 读取前和无权时不出现；save 内有 '正在保存并核对…' 和 CircularProgressIndicator，之后全页没有 CircularProgressIndicator；progress 内是 LinearProgressIndicator；跳锚点后 '活人感' 可点；模型名、URL 在 models 子树内；'private host detail''z9y8' 不出现。
- android_own_ai_settings_test（4，375×812）：`tester.widget<AiConfigEditor>` 取 androidDetails（aiLabel 'Jo'）；owner-social-level-L3、owner-social-level-{read,L2,save}、ChoiceChip(L3)；'读取配置' 精确 1；'已保存：L2 友好'；包含 '版本 4'。
- model_diagnostics_screen_test（19）、settings_model_diagnostics_test（4）：model-diagnostics-{session-invalid,unbound}、diagnostics-{catalog,usage,trend,budget}-{section,load,loading,loaded,not-requested,unknown,unconfigured,unavailable}（load 是 TextButton）、diagnostics-catalog-{needs-provider,provider,provider-input}、diagnostics-usage-{needs-profile,profile,profile-input,unknown-<能力>}、diagnostics-budget-{layer,capability}-<k>、diagnostics-trend-history-unknown；下拉保持 DropdownButton（测试点 Key 后点 `find.text(id).last`）；'模型能力与预算诊断' 精确 1；数字和日期文案原样（'已记录 15 tokens''2026-11-14 至 2026-11-20''时区偏移 480' 等）；'secret-detail-xyz''sk-''key_mask''api_key''****' 不出现。
- owner_auto_memory_ui_test（7，390×844，SingleChildScrollView 直接挂卡）、owner_memory_notes_ui_test（8，经夹具进入，含 375/768/1280）：auto-memory-*、memory-notes-*、owner-memory-notes-section 全部 Key；SwitchListTile(*-enabled)；类型 OwnerMemoryNotesSection；'尚未读取宿主状态。''还没有采集到记忆。''还没有便签。''未授权采集（默认关闭）。开启需单独确认当前接收条件。''未授权使用（默认关闭）。便签可先保存，授权需单独确认。' 精确；包含 '仅采集当前本人 AI 私聊''仅当前本人 AI 私聊''不是聊天历史''当前没有可用的本人私聊接收条件'；读取后 memory-notes-add、-enabled 在三种宽度可点；弹窗 Key 在 AlertDialog 上。
- owner_model_proactive_ui_test（5）：TextField(owner-model-proactive-interval)、FilledButton(-review)、SwitchListTile(-global-stop)；'未授权模型主动联系''已授权模型主动联系''停止全部模型主动联系？' 精确；包含 'UTC+08:00''2880'。
- owner_social_level_android_test（7 + 5 单元，375×725）：owner-social-level、-select、-read（TextButton）、-L0…L4（ChoiceChip）、-save（FilledButton）；保存中 LinearProgressIndicator 精确 1；Windows 不渲染；包含 '尚未读取''撤销''不会授予或恢复授权''不会开启 L4''未配置''保存结果未知''重新连接宿主''已保存：L?'。
- settings_chat_model_picker_test（经设置进入写入台）：TextField(binding-model)、OutlinedButton(binding-catalog-read)、ListTile(binding-catalog-model-<m>)、FilledButton(binding-save)；'current-choice' 精确 1；过期或锁定后的结果（'聊天绑定已保存''stale-a''stale-ai-catalog''late-locked-model'）不出现；也按状态文案断言，见第 8 节第 1 条。
- settings_persona_history_route_test：OutlinedButton(persona-history-read)、persona-history-{next,notice,version-<v>}；'初始化''2026-02-05' 可多处，每个版本标签精确 1；清空时一次 pump 后版本条目和翻页键就不在；'synthetic-error-opaque' 不出现。
- evidence 下的截图测试（qa）：persona_import、persona_history、chat_model_picker、owner_memory_notes、owner_reply_preferences、owner_rule_greeting_settings 六个 capture，都从设置沿 Scrollable 向下找 Key（如 open-ai-config-write、help-persona、persona-import-paste、binding-model）；'未授权自动使用''未授权规则问候''已授权规则问候''喜欢桂花' 精确，其中 '未授权自动使用' 和含 'fixture-provider''fixture-chat-model' 的文字要可点（hitTestable）；'fixture-target-A''fixture-value''fixture-reason' 不出现（历史只显示摘要）；ChoiceChip(owner-reply-length-brief、-format-bullets)、TextField(owner-rule-greeting-offset、binding-model)、SwitchListTile(owner-rule-greeting-global-stop) 按类型取。

## 8. 风险

1. 写入状态就近后，ai_config_editor_test 有 5 处先 `_top` 回顶再断言状态（provider、无效人格、成功/拒绝/未知），要改成 `_to(Key('ai-config-write-status'))`；断言内容不变，提交说明写原因。settings_chat_model_picker_test 也按状态文案断言，实现时同样核对。
2. 桌面四组默认展开，测试不用先点开。滚到 help-provider 后页头说明必须已在视口外（'key_mask' 精确 1）：页头和 Provider 组之间隔着伙伴卡和人格组，Provider 后面还有绑定和预算，这个顺序和高度量级都别动。
3. `JyExpand` 收起即卸载：伙伴卡、记忆卡有读取结果，不放进可折叠组；表单 controller 在编辑器 State 里，收起不丢输入。
4. `JyBanner` 只收 message 字符串：带 Key 的通知和状态（Key 在 Text 上）不能直接换成它，要么请 foundation 加可选的 `messageKey`，要么用同样外观的行内提示（图标 + 原 Text）；'人格已保存。' 这类无 Key 的通知可以直接用，前提是 message 原样渲染成一个 Text（测试精确匹配）。
5. 诊断页读取中不加循环动画（测试可能在读取挂起时 pumpAndSettle）；其他进度线只保留原条件。
6. 安卓页全页都在树上：新增的摘要和胶囊不能再出现 '琉璃鲸''读取配置''已授权规则问候' 这类被精确计数的文案。
7. 有的测试用 helper 传字符串拼 Key，第一轮提取漏了 5 个测试和 5 个截图测试（已补进第 7 节）；实现前对 test/ 和 evidence/ 再按 Key 前缀全文搜一遍。

## 9. 范围外，要问 lead

1. task-9 写入范围只有 `lib/features/ai_config/**`：请加上第 7 节的测试文件 test/{ai_config_editor,ai_config_panel,android_ai_config_editor,android_own_ai_settings,model_diagnostics_screen,owner_auto_memory_ui,owner_memory_notes_ui,owner_model_proactive_ui,owner_reply_preferences_ui,owner_rule_greeting_ui,owner_social_level_android,persona_import_ui,settings_chat_model_picker,settings_model_diagnostics,settings_persona_history_route}_test.dart（settings_ 开头的三个从设置进入，测的是本范围的控件）。owner_rule_greeting_settings_panel_test 与 settings 共用，要改先和 settings 对齐。test/support/** 不改。
2. evidence 下 6 个相关截图测试归 qa，Key 和顺序不变，应照旧通过。设置里的入口（open-ai-config-write、open-ai-config、open-model-diagnostics、open-android-ai-directory）归 settings，我不改。
3. 第 8 节：`JyBanner` 能否加可选的 `messageKey`（挂在内部 Text 上；不加我就写同外观的行内提示）；`JyExpand` 能否加 `maintainState`（加了伙伴卡也能折叠）。
4. 桌面写入台要不要像安卓那样把 Provider、绑定、预算收进默认收起的「高级配置」？要的话测试 `_pump` 里点开一次即可。
