# 鲸言鲸语客户端设计系统（v2 MASTER）

这是客户端视觉与交互的唯一规范。页面级的补充和覆盖写在 `pages/<页面>.md`，与本文冲突时以页面文件为准。实现位于 `lib/ui/`（tokens 与组件）和 `lib/app/app_theme.dart`（Material 主题）。

旧 UI 只是测试用的，v2 不沿用它的布局和观感：打开应用要一眼看出是新设计，每个界面都按本规范重做，不只是换颜色。

## 1. 设计哲学：陪伴与科技

鲸言鲸语让人和朋友、和自己的 AI 伙伴说话。v2 用一个母题把陪伴和科技连起来：**声呐**。鲸用歌声彼此呼唤，这是陪伴；声呐发出信号、接收回声，这是科技。同心环、一次性的脉冲、回声的余波，出现在状态、头像和动效里。

两种温度，各管一件事：

- **信号蓝 signal**：科技与交互。可点、选中、正在连接的东西。
- **余烬琥珀 ember**：陪伴。只给 AI 伙伴的「在场」：伙伴的光核、伙伴消息的标记、伙伴在想或在说的时刻。普通按钮不用它。

底色是深海墨（深色）和晨雾（浅色）。界面安静，内容和伙伴在前。

## 2. 从索尼设计理念里学什么

索尼的设计理念是「Create New Standards」，关键词 Visionary、Integrity、Empathy；索尼的 Purpose 是用创意和科技的力量让世界充满感动。我们理解它们背后的做法，再转成自己的语言，不复制任何索尼产品的外形、标志或配色。

| 索尼的做法 | 在鲸言鲸语里的转译 |
|---|---|
| One Slate：把产品凝缩成一块板，去掉多余元素，让人沉浸在内容里 | 每个区域是一整块「板」（`JySlab`）放在底色上；不用满屏分隔线和层层边框；聊天时界面退后，消息在前 |
| OmniBalance：从任何角度看都平衡，方向感淡去，极简 | 对称的留白和统一的圆角；组件在常态、按下、禁用、加载时都完整；底部 dock 居中悬浮 |
| 材料与精密加工 | 板的上沿一条细高光，像金属倒角的反光；1 像素发丝线；严格的 4/8 网格；时间和数字用等宽数字 |
| aibo 的「生命感」：有机曲线，用眼睛表达好奇和情绪 | AI 伙伴是一颗会回应的光核（`JyPresenceOrb`）：新消息时亮一下，等回复时轻轻呼吸，回复到达时放一圈声呐波；全部由事件触发 |
| Empathy：理解人的处境，触动感性 | 动效有情绪但不打扰：按下有回弹，展开有层次，出现有先后；尊重「减少动效」和大字号 |

不照抄：不用索尼的标志、字体、产品轮廓、配色或任何可识别的商标元素。

资料：[Sony Design Philosophy](https://www.sony.com/ja/SonyInfo/design/about/philosophy/)、[Purpose & Values](https://wwwp.sony.com.hk/aboutsony/html/en/purpose_values.jsp)、[aibo](https://www.sony.com/en/SonyInfo/design/gallery/aibo/)、[One Slate](https://www.sony.com/en-ye/electronics/one-slate-tv-design)、[OmniBalance](https://www.sony.jp/xperia/xperia/docomo/so-03f/design/design.html)。

## 3. ui-ux-pro-max 的检索结论

用 skill `ui-ux-pro-max`（nextlevelbuilder/ui-ux-pro-max-skill，提交 f2f7266）检索了 design-system（AI companion social chat app；calm technology premium，dials variance 5、motion 7、density 5）、style、color、typography、ux（动效时长与缓动、触摸反馈、减少动效、返回导航）、web（触控与安全区）和 flutter 栈（animations、theme、accessibility、performance）。

采用：

- 无障碍：正文对比 ≥4.5:1，可交互控件边界 ≥3:1；触控目标 ≥48dp，相邻 ≥8dp；按下必须有反馈；不只靠颜色表达状态；支持减少动效（skill 标为 High）。
- 动效：缓动按用途选（进场减速，离场加速，匀速只给进度）；共用 motion tokens，不给所有过渡同一个时长；无限循环只给加载；用变换和透明度做动画，少做布局动画；一屏一两个重点动效。
- Flutter：ThemeData、ColorScheme 和 darkTheme；用 `Theme.of(context)` 取值；优先隐式动画；动画子树包 `RepaintBoundary`；Hero 做共享元素转场；Semantics；用 `MediaQuery.textScalerOf` 支持大字号；列表项带 Key。
- 交付前按 skill 的 `references/pro-rules.md` Pre-Delivery Checklist 逐条检查。

不采用，以及理由：

- Liquid Glass（design-system 推荐的风格）：贴合苹果系统控件，大面积模糊开销高，文字对比有风险。我们用色阶和细高光表达层次。
- Cormorant + Montserrat：奢侈时装气质，没有中文字形，还要联网加载。
- Scroll-Triggered Storytelling：营销落地页的叙事结构，不适合聊天应用。
- AI 紫配粉、聊天蓝配绿（color 推荐）：同质化，表达不了陪伴。
- 字体：不打包字体，也不联网加载。中文用系统字体（Android 的 Noto Sans CJK、Windows 的微软雅黑 UI），靠字号、字重、行高和字距建立层级。

## 4. 颜色（`JyPalette`）

`JyPalette` 是 `ThemeExtension`，页面用 `JyPalette.of(context)` 取色，不写 `Color(0x…)`。

| token | 深色 | 浅色 | 用途 |
|---|---|---|---|
| canvas | #070B12 | #EEF2F7 | 页面底色 |
| slab | #0E1520 | #FFFFFF | 主板 |
| raised | #141D2B | #F5F7FA | 板上的次级面：输入框、对方气泡、按下底 |
| overlay | #1A2536 | #FFFFFF | 弹窗、底部面板、dock、浮动输入条 |
| text1 | #E9EEF5 | #0C1727 | 主文字 |
| text2 | #A9B4C2 | #48566A | 次要文字 |
| text3 | #8693A4 | #5E6C82 | 说明、时间 |
| signal | #5BC4FF | #0B6BD3 | 交互主色、己方气泡 |
| onSignal | #03131F | #FFFFFF | signal 上的文字 |
| signalSoft | #0F2A40 | #DCEBFC | 选中底、徽标底 |
| onSignalSoft | #BFE6FF | #06335F | signalSoft 上的文字 |
| ember | #FFB45E | #A65A0A | AI 伙伴的在场 |
| onEmber | #1F1206 | #FFFFFF | ember 上的文字 |
| emberSoft | #33220F | #FBEBD8 | 伙伴相关的底 |
| onEmberSoft | #FFDDB5 | #5A2F03 | emberSoft 上的文字 |
| success | #5FD3A2 | #127A55 | 成功 |
| warning | #F4C95D | #8A6100 | 警告 |
| danger | #FF7884 | #C42F40 | 错误、危险操作 |
| onDanger | #2A0509 | #FFFFFF | danger 上的文字 |
| dangerSoft | #3A161B | #FBE3E6 | 错误提示条底 |
| onDangerSoft | #FFD3D7 | #6E0F1B | dangerSoft 上的文字 |
| outline | #66768B | #76849A | 可交互控件的边界 |
| hairline | #1F2A3B | #DCE2EA | 装饰性分隔，不承载信息 |
| edgeHighlight | #FFFFFF，8% | #FFFFFF，100% | 板上沿高光；浅色只画在 raised 和 canvas 上 |
| scrim | #000000，60% | #0C1727，40% | 遮罩 |
| shadow | #000000，45% | #0C1727，12% | 悬浮物阴影 |

对比度逐对算过（WCAG 2.x）：所有文字色在 canvas、slab、raised、overlay 上都 ≥4.5:1（最低的是浅色 ember/canvas 4.57、signal/canvas 4.60、text3/canvas 4.74），outline ≥3:1。

ColorScheme 映射（`appColorScheme`）：primary=signal，onPrimary=onSignal，primaryContainer=signalSoft，onPrimaryContainer=onSignalSoft，secondary=ember，onSecondary=onEmber，secondaryContainer=emberSoft，onSecondaryContainer=onEmberSoft，tertiary=success，error=danger，onError=onDanger，errorContainer=dangerSoft，onErrorContainer=onDangerSoft，surface=slab，onSurface=text1，onSurfaceVariant=text2，surfaceDim 和 surfaceContainerLowest=canvas，surfaceContainerLow=slab，surfaceContainer=raised，surfaceContainerHigh=overlay，surfaceContainerHighest=深 #223047、浅 #E6EBF2，outline=outline，outlineVariant=hairline；scaffoldBackgroundColor=canvas。现有页面从 ColorScheme 取色的地方会自动换成新色，但每个页面仍要按第 9 节重做。

## 5. 文字

| 样式 | 字号/行高 | 字重 | 字距 | 用途 |
|---|---|---|---|---|
| displaySmall | 32/40 | 700 | -0.5 | 引导页大标题 |
| headlineSmall | 26/34 | 700 | -0.3 | 页面标题 |
| titleLarge | 20/28 | 600 | 0 | 区块标题、聊天头部名字 |
| titleMedium | 16/24 | 600 | 0 | 列表主标题 |
| titleSmall | 14/20 | 600 | 0.1 | 小标题 |
| bodyLarge | 16/24 | 400 | 0 | 消息正文 |
| bodyMedium | 15/22 | 400 | 0 | 常规正文 |
| bodySmall | 13/18 | 400 | 0.1 | 说明 |
| labelLarge | 15/20 | 600 | 0.1 | 按钮 |
| labelMedium | 13/16 | 600 | 0.2 | 标签 |
| labelSmall | 12/16 | 500 | 0.4 | 时间、徽标 |

正文不小于 12。时间、计数、百分比用 `FontFeature.tabularFigures()`。设置里的字体大小通过 MediaQuery 的 textScaler 作用于全部文字；最大档下布局不截断、不重叠。

## 6. 形状、间距、层次

- 间距 `JySpace`：4、8、12、16、20、24、32、40、48。页面左右边距窄屏 16、宽屏 24；板内边距 16；列表行高至少 64。
- 圆角 `JyRadius`：xs 6、sm 10、md 14、lg 20、xl 28、pill。板用 lg，按钮用 md 或 pill，弹窗和底部面板用 xl，气泡用 lg（同一人连续气泡的相邻角为 6）。
- 曲线：用连续曲率的超椭圆圆角（`RoundedSuperellipseBorder`、`ClipRSuperellipse`），在 `JyShapes` 里统一封装；某个平台渲染有问题时只在 `JyShapes` 里退回 `RoundedRectangleBorder`。
- 层次：靠色阶、发丝线和上沿高光，不用 Material 的 elevation 阴影。只有悬浮物（dock、底部面板、弹窗、浮动输入条、展开的堆叠卡）带一层柔和阴影：深色 y12、blur 32，浅色 y8、blur 24。
- 图标：Material Icons 的 outlined 或 rounded，全应用一套；选中态用实心变体。不用 emoji 当图标。文字旁的装饰图标对读屏隐藏；单独的图标按钮必须有 tooltip。

## 7. 动效（`JyMotion`）

| token | 时长 | 用途 |
|---|---|---|
| press | 90ms | 按下 |
| quick | 160ms | 小元素淡入淡出、颜色和选中变化 |
| standard | 240ms | 展开收起、元素进出、tab 切换 |
| emphasized | 360ms | 页面转场、底部面板、弹窗 |
| gentle | 520ms | 光核亮起、一圈声呐波、引导页 |

离场用进场时长的约 0.7 倍。曲线：进场 `Curves.easeOutCubic`，离场 `Curves.easeInCubic`，强调 `Cubic(0.2, 0, 0, 1)`；回弹用弹簧（mass 1、stiffness 520、damping 34：略有回弹，很快停住）；只有进度用线性。

用户点名的五类动效，统一这样做：

1. **触摸**：`JyPressable`。按下 90ms 缩到 0.97（行、卡片）或 0.92（图标按钮），松手弹簧回弹，同时叠一层 signal 8% 的高亮。只用变换，不改布局尺寸。长按触发时给一次轻触感反馈（平台支持时）。
2. **展开**：`JyExpand`。高度用 standard 展开，内容淡入并上移 8px；收起用离场曲线；配套的 `JyChevron` 旋转 180°。用于可折叠分区、错误提示条、更多选项、消息详情。
3. **缩放**：打开会话、图片、弹窗时从 0.94 放大到 1 并淡入（emphasized），关闭反向、更快。图片预览保留双指缩放。
4. **堆叠**：`JyStackDeck`。同类卡片收起成一摞：后两张缩到 0.95、0.90，下移 8、16，透明度递减；点按展开成列表，逐张错开 30ms，弹簧落位；再点收起。用于好友申请、收件箱同类通知。前台消息提醒一次只显示一条，不堆叠。群聊头像用两枚堆叠的小头像。列表第一次出现时前 8 项逐项错开 30ms 进场（`JyEntrance`），之后滚动不再动。
5. **过渡**：页面推入用 `JyPageTransitionsBuilder`（新页淡入、从右侧 24px 平移、从 0.98 到 1；返回反向）。dock 切换 tab 用 fade-through（旧内容 90ms 淡出，新内容 210ms 淡入并从 0.98 到 1）。窄屏的会话列表和聊天之间、主页和设置之间，用同样的共享轴过渡（`JySwitcher`）。

光核 `JyPresenceOrb` 的状态：idle（安静的光核加一圈淡环）、offline（灰色，不发光）、thinking（呼吸，只在等待 AI 回复、原本就显示进度的时段内循环）、speaking（回复到达时放一次声呐波）、attention（新消息时亮一下）。

减少动效：`MediaQuery.disableAnimationsOf(context)` 为真，或者用户在设置里打开「减少动效」（经 `JyMotionScope` 传下来）时，关掉位移、缩放、弹簧和声呐波，只留不超过 120ms 的淡入淡出；循环动画换成静态指示，状态仍有文字说明。

测试约束：客户端测试大量使用 `pumpAndSettle`，所以不能有无限循环的装饰动画。循环动画只能出现在原来就显示不确定进度的地方、同样的条件下；其余动效都必须在有限时间内结束。

性能：动画子树包 `RepaintBoundary`；长列表里不放循环动画；一屏一两个重点动效。

## 8. 组件 API（`lib/ui/`）

由 foundation 实现，`lib/ui/ui.dart` 统一导出。名字和签名是各页面共用的契约：要改先和 lead 确认，并同步更新本节。

```dart
// 颜色、尺度、形状
class JyPalette extends ThemeExtension<JyPalette> { /* 第 4 节全部 token，字段名同表 */
  static const JyPalette dark, light; static JyPalette of(BuildContext context); }
abstract final class JySpace { xs 4, sm 8, md 12, lg 16, xl 20, xxl 24, x3 32, x4 40, x5 48 }
abstract final class JyRadius { xs 6, sm 10, md 14, lg 20, xl 28, pill 999 }
abstract final class JyShapes { /* slab、button、dialog、bubble 等统一形状，内部决定超椭圆或退回 */ }

// 动效
abstract final class JyDurations { press, quick, standard, emphasized, gentle }
abstract final class JyCurves { enter, exit, emphasized; static SpringDescription spring; }
abstract final class JyMotion {
  static bool reducedOf(BuildContext context);          // 系统设置或应用内「减少动效」
  static Duration of(BuildContext context, Duration d);  // 减少动效时缩短或归零
}
class JyMotionScope extends InheritedWidget { const JyMotionScope({required bool reduce, required Widget child}); }

// 交互动效
class JyPressable extends StatefulWidget { child; onTap; onLongPress; pressedScale = 0.97; borderRadius; enabled = true; }
class JyExpand extends StatelessWidget { required bool expanded; required Widget child; bool maintainState = false; }  // 收起后移出树；maintainState 为 true 时留在树里（offstage）
class JyChevron extends StatelessWidget { required bool expanded; }
class JyStackDeck extends StatefulWidget { required List<Widget> children; required String summary;
  bool? expanded; ValueChanged<bool>? onExpandedChanged; int maxPeek = 2; }
class JyEntrance extends StatefulWidget { required int index; required Widget child; }  // 首次出现错开进场
enum JySwitcherStyle { fadeThrough, sharedAxisX }
class JySwitcher extends StatelessWidget { required Widget child; JySwitcherStyle style = fadeThrough; bool reverse = false; }  // child 带 Key；换 key 时旧子树当帧移除，只做新子树进场；reverse 从起始侧进入
class JyPageTransitionsBuilder extends PageTransitionsBuilder {}

// 表面与行
enum JyTone { slab, raised, overlay }
class JySlab extends StatelessWidget { required Widget child; padding = EdgeInsets.all(16); tone = JyTone.slab;
  radius = JyRadius.lg; floating = false; onTap; }
class JyGroup extends StatelessWidget { String? header; String? footer; required List<Widget> children; }  // 行间发丝线
class JySectionHeader extends StatelessWidget { required String title; Widget? trailing; }
class JyIconTile extends StatelessWidget { required IconData icon; Color? color; }  // 行首着色的超椭圆图标底
class JyBadge extends StatelessWidget { required int count; }  // 未读胶囊
enum JyBannerKind { error, info, success }
class JyBanner extends StatelessWidget { required String message; kind = JyBannerKind.error; VoidCallback? onClose;
  closeTooltip = '关闭提示'; }  // 文字放在 liveRegion 里

// 伙伴与状态
enum JyPresence { idle, offline, thinking, speaking, attention }
class JyPresenceOrb extends StatefulWidget { size = 40; state = JyPresence.idle; String? semanticsLabel; Widget? child; }
class JySonarPulse extends StatefulWidget { required Object trigger; required Widget child; Color? color; }  // trigger 变化时放一次
class JyStatusDot extends StatelessWidget { required bool online; }
enum JyAvatarKind { person, group, ai }
class JyAvatar extends StatelessWidget { required String label; size = 44; kind = JyAvatarKind.person; }  // ai 用光核

// 导航
class JyDockItem { IconData icon; IconData selectedIcon; String label; Key? key; }
class JyDock extends StatelessWidget { required List<JyDockItem> items; required int selectedIndex;
  required ValueChanged<int> onSelected; }  // 每项都显示文字且可点，选中项有 Semantics selected
```

现有的 `StatusPanel`（`lib/app/status_panel.dart`）保留类名和参数，按本规范重画。

## 9. 页面方向

各页面在 `pages/<页面>.md` 里补充细节，写明要保留的测试契约（Key、文案、tooltip）。

- **外壳，窄屏（<720dp）**：底部悬浮 dock（overlay 色、pill 圆角，离底 12 加安全区）；五个目的地都显示图标和文字，选中项背后一枚 signalSoft 胶囊用弹簧滑过去。页面头部：左边大标题（headlineSmall），右边连接状态（`JyStatusDot` 加「在线」或「离线」）和设置按钮。忙碌时头部下沿一条细的 signal 进度线。错误提示是内缩的圆角 `JyBanner`，展开出现，可关闭。系统返回键：在聊天或设置里先回到上一层，不直接退出应用。
- **外壳，宽屏（≥720dp）**：左侧导航是一块竖板，会话列表一块板（约 320 宽），聊天一块板；板之间留 12 的缝，露出底色。
- **会话列表**：AI 伙伴置顶成一张「伙伴卡」：大光核、名字、一句状态。行：44 头像、名字（titleMedium）、最后一条预览（bodyMedium、text2、单行）、时间（labelSmall、text3、等宽数字）、未读 `JyBadge`。群聊头像两枚堆叠。「创建群聊」「刷新会话」移到头部或一排紧凑操作里，文案不变。首次出现逐项进场。
- **聊天**：头部是对方头像或伙伴光核、名字、状态。己方气泡用 signal 实色；对方气泡用 raised 加发丝线；AI 伙伴气泡用 raised，左上角一枚 ember 小光点。同一人连续的消息收紧间距、相邻角变小。时间分隔是居中的小胶囊。新消息从 0.96 放大、上移 8、淡入；发送时发送键放一圈声呐波。输入条是浮动的 overlay 胶囊：附件键、多行输入、圆形发送键（可发送时 signal，不可发送时有清楚的禁用态）。长按消息弹出底部面板：一排表情加竖排操作，错开进场。
- **设置**：顶部一张账号与伙伴卡（光核、名字、在线状态）；下面是分组板（`JyGroup`），每行左边一枚 `JyIconTile`，右边箭头或开关；可折叠分区用 `JyExpand`。新增「减少动效」开关。字体大小保留实时预览、松手保存。
- **联系人**：顶部胶囊搜索框；好友申请收成一摞（`JyStackDeck`），点开逐张展开；分组列表用会话列表的行样式。
- **动态**：单列卡片流，每张是一块板，按下回弹，打开详情用缩放转场。
- **收件箱**：同类通知收成一摞，可展开；操作按钮清楚可点，不只靠滑动。
- **世界**：顶部一块带同心声呐环图形的状态板，下面用板和分组。
- **语音和通话**：居中的大光核（说话时随事件放声呐波），控制键 64dp 圆形，按下回弹。
- **搜索、收藏、附件、备份、诊断、AI 配置**：统一用板、分组和行样式；空、错误、离线用 `StatusPanel`。
- **引导和解锁**：底色上一组静态同心环（出现时放一次声呐波），大标题，步骤之间用共享轴过渡。
- **状态面板**（空、离线、失败）：图标放在同心环中心（出现时放一次声呐波），标题 titleMedium，说明 text2，下面是操作按钮。
- **弹窗和底部面板**：overlay 色、xl 圆角，从 0.94 放大到 1 并淡入；底部面板有拖动条；遮罩用 scrim。

## 10. 交付前检查

- skill 的 `references/pro-rules.md` Pre-Delivery Checklist 全部条目。
- 375dp 小屏、横屏、宽屏；最大字体档；减少动效开和关；浅色、深色分别看。
- 无障碍指南测试：`androidTapTargetGuideline`、`labeledTapTargetGuideline`、`textContrastGuideline`。
- Before/After：同一场景、视口、主题和状态；Before 用 main 0300369，After 用 PR 的头提交，都是真实应用渲染。
