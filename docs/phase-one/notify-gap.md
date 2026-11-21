# 第一期通知能力现状与缺口（只读审计）

审计日期：2026-11-21。审计只读，不改产品代码、不改共享 shell、不改 native 平台代码、不写新用例。
本文记录原交付的基线审计。后续增加的是[Windows 前台的通用应用内提示](../../apps/client_flutter/evidence/foreground-message-notice.md)，不改变通知设置。**新消息通知中心、Windows/Android 系统消息通知及锁屏通知正文隐藏仍未实现。**

## 1. 基线

| 项 | 值 |
|---|---|
| 仓库 / 路线 | `jingyan-jingyu`；审计时本地分支 `agent/notify/phase-one-e06b2209e759`（隔离 worktree `wt-notify`，未合并、未推送） |
| 审计 commit | `38cd86c8f3a5c5e8b29a6d997bd02a2790400e96`（`HEAD^{tree}` = `3478ae317ae296f252ac44e7aade2aa0ca96fc93`，与集成基线 tree 相同） |
| 工具链 | Flutter 3.50.0 / Dart 3.14.0（Windows）；Android SDK 已装，`minSdk 26` |
| 数据 | 全部使用隔离临时目录、合成邀请/合成消息与既有 fixture；未读取任何真实用户数据，未连个人设备 |

## 2. 结论

- **已存在**：宿主 `GET /api/v1/notifications` 的「待处理好友邀请」只读元数据；客户端「收件箱」页已接线（含空/未绑定/拒绝/失败/手动刷新/接受拒绝确认）；会话列表有**拉取式**未读 Badge；设置页「隐藏通知正文」可保存/迁移，`AppLockController.notificationBody()` 有正文遮蔽纯函数；Windows 原生有 WinRT toast/tray/pet 入口；Android 原生有保活前台服务与来电/未接来电通知。
- **不存在**：任何真实的「新消息系统通知」链路——Dart 侧没有调用 Windows `notify`、没有 Windows/Android 失焦/最小化判定、没有消息级隐私消费、没有通知点击打开会话；Android 没有消息通知渠道；站内收件箱没有「新消息」条目；WebSocket 客户端代码（`HostConnection.connectStream`）未被使用。**本期交付的口径应为：通知未完成，二期实现。**

## 3. 能力与证据

| 能力 | 证据（文件/路由/测试） | 用户可见现状 | 距真实消息通知的缺口 |
|---|---|---|---|
| 宿主好友邀请通知 | `apps/host/lib/src/social/friendship_routes.dart:68`、`friendship_service.dart:317-352`；`GET /api/v1/notifications?limit=`；`apps/host/test/notifications_routes_test.dart` 3/3 | 当前账号只读、仅 `friendRequest`「好友邀请」元数据（`kind/title/status/createdAt/refId`）；已处理即消失；限 1–100、未认证 401 | 只有邀请，没有新消息事件；无推送，只有客户端主动拉取 |
| 客户端收件箱 | `apps/client_flutter/lib/features/inbox/inbox_screen.dart`、`lib/net/notification_api.dart`、`lib/app/shell_app.dart:335-354`（`inbox()`）；`test/inbox_screen_test.dart`、`test/inbox_invite_actions_test.dart`、`test/shell_inbox_invite_actions_test.dart`、`test/notification_api_test.dart` | 「收件箱」导航页：未连接时诚实提示；加载/空/拒绝/失败态；手动刷新；待确认邀请可接受/拒绝（需二次确认，结果以宿主为准，其它通知只读） | 页面只读邀请，没有新消息通知流；打开页时拉取一次 + 手动刷新，无实时更新 |
| 应用内「新消息」通知中心 | 无实现；`friendship_service.dart:317-321` 注释明确「System notices / consent prompts are intentionally absent」 | 无新消息提醒、无未读消息列表、无消除/定位 | 触发、去重、隐私、已读、点击定位全部缺失 |
| 会话未读 Badge | `lib/app/runtime.dart:347-373`（`_unreadFor`）、`lib/features/chat/chat_pane.dart:97-98`；`test/runtime_unread_test.dart` | 会话行显示未读数；自己消息不计数；打开/重选会话推进已读并发 ack；脱机/重启从快照恢复 | 拉取式：只有刷新/重新打开页面后更新；无应用级总未读、无托盘/系统角标联动（Windows 原生 `unreadCount` 入口未被 Dart 调用） |
| 隐藏通知正文（设置） | 设置开关：`lib/features/settings/settings_screen.dart:181-186`；持久化/迁移：`lib/app/runtime.dart:768-769, 907-917, 2414-2418`；遮蔽函数：`packages/jingyu_client_kit/lib/src/app_lock.dart:79`；单测：`packages/jingyu_client_kit/test/settings_onboarding_test.dart:87`；widget：`test/ui_test.dart:943-945` | 开关可保存、可跨重启迁移；应用锁启用且锁定后 `notificationBody()` 返回「新消息」 | **没有消费者**：全仓无消息通知调用该函数；Windows toast 只在 `locked/session_locked` 时硬编码 `"New message"`，不读设置；开关本身不会隐藏任何真实消息通知 |
| Windows 系统通知/tray | 原生：`windows/runner/platform_integration.cpp:292-303`（WinRT toast，AUMID `com.jingyu.client`）、`403`（`notify` 方法）、`404-416`（tray/pet/未读数）、`PLATFORM_API.md:19`；`NATIVE_PLAN.md` 记录已编译 | 托盘图标/宠物气泡未读数、toast 原生能力存在；窗口关闭进托盘 | Dart 无 `notify` 调用方；无失焦/最小化检测；点击 toast 不路由（`PLATFORM_API.md:27` 明示「Notification activation routing is not implemented」）；通知文案与设置脱节 |
| Android 通知 | `android/.../KeepAliveService.kt:15-35`（`ShellNotifications`：连接保活、来电两个渠道）；`CallTimeoutReceiver.kt:35-85`（来电/未接，`hidePreview` 遮蔽）；`MainActivity.kt:57-65`（API 33+ 申请 `POST_NOTIFICATIONS`，Android 12 设备无需运行时权限）、`:433-438`（回传权限变化） | 仅保活通知与来电/未接来电通知；前台服务尽力保活（文案已注明「系统限制下可能漏接」） | 无消息通知渠道、无消息 `notify` 方法、无未读汇总；权限变化 Dart 未消费；点击只打开 Activity，不进会话 |
| 通知点击打开会话 | 无；Android `PendingIntent` 仅启动 `MainActivity`（`KeepAliveService.kt:32`）；Windows 无激活路由 | 只能打开应用（Android）/无反应（Windows toast） | 需要稳定 token→会话映射、锁/登出后的失效处理与权限边界 |
| 实时性/后台 | `lib/app/runtime.dart:879-881`（15 秒定时拉取）、`1309-1311`（Android 保活）；`HostConnection.connectStream`（`lib/net/host_connection.dart:368`）无调用方 | 应用在前台时靠轮询刷新；后台/最小化时没有用户可见提醒（Windows 收进托盘后静默同步；Android 保活服务只维持进程） | 无事件推送（host 侧也不推），无后台通知触发 |
| 锁屏隐私 | `docs/acceptance.md` AC-30「应用锁；锁屏通知正文可隐藏」= **未实现/端侧未交付**；来电通知用 `VISIBILITY_PRIVATE` + `hidePreview`；无消息通知 | 应用锁可锁界面；**消息通知锁屏正文隐藏未交付**（因为没有消息通知） | 需要有消息通知后，再统一做锁屏/悬浮预览的正文策略与持久设置 |

## 4. 已运行的验证（本次审计，基线 commit 同上）

| 命令（工作目录） | 结果 |
|---|---|
| `dart test test/notifications_routes_test.dart`（`apps/host`） | 3/3 passed： owner 隔离、处理后消失、limit/参数/未认证拒绝 |
| `flutter test --no-pub test/inbox_screen_test.dart test/inbox_invite_actions_test.dart test/shell_inbox_invite_actions_test.dart test/runtime_unread_test.dart test/notification_api_test.dart test/ui_test.dart`（`apps/client_flutter`） | 84/84 passed：收件箱空/未绑定/拒绝/失败/刷新、邀请确认写入、未读计数与 ack、设置开关 |
| `dart test test/settings_onboarding_test.dart`（`packages/jingyu_client_kit`） | 3/3 passed：含 `notificationBody('secret') == '新消息'` 与重启后恢复明文 |
| `flutter test --no-pub evidence/inbox_invite_actions_capture_test.dart`（既有 driver，基线重跑） | passed；重新生成「待处理邀请/确认框/已接受」3 张 1280×960 PNG（仅本地 `.dart_tool/notify-audit/`，未入库） |
| `flutter test --no-pub evidence/inbox_manual_refresh_capture_test.dart`（既有 driver，基线重跑） | passed；重新生成「读取失败/手动重试恢复」2 张 1280×960 PNG（仅本地 `.dart_tool/notify-audit/`，未入库） |
| 静态核对 | 全仓无 Dart 调用 Windows `notify`/`setPetState`，无 Android 消息通知方法；`notificationBody()` 无生产调用；`connectStream` 无调用方 |

既有已入库证据（可引用，非本次新增）：`apps/client_flutter/evidence/inbox-invite-actions.md`、`inbox-manual-refresh.md`、`inbox-recovery.md` 及其 PNG。

本次基线重跑 PNG（本地 `.dart_tool/notify-audit/`，未入库）SHA-256：

- `38cd86c-inbox-pending.png` = `98CB2CE6C1E1E78716B591960D08923D1B6C18BA3AB8544791D005AC48FB542A`
- `38cd86c-inbox-confirm.png` = `C123C105F9D9C7BAC74E2A02C8CAC1D244510DE339A91453BCCED0418416DF52`
- `38cd86c-inbox-accepted.png` = `442B177C4822DA1884C0C74DE8769D207D57EFEAD99AAA1D286B233186E50164`
- `38cd86c-inbox-failure.png` = `FB3BECA49360BB28C0C5404CBA4F5FCBFFA43A7676EE3B64EAE49545E7CA1131`
- `38cd86c-inbox-refresh.png` = `98CB2CE6C1E1E78716B591960D08923D1B6C18BA3AB8544791D005AC48FB542A`（恢复后与待处理行同帧，符合既有 driver 的同一数据状态）

前三张与既有入库证据 `inbox-invite-actions.md` 列出的 After PNG 哈希逐一相同，说明基线 `38cd86c` 的收件箱渲染与既有证据一致、无视觉漂移。

## 5. 未验证与限制

- 未在真实 Windows 桌面交互环境验证 toast 投递/托盘/宠物；未在 Android 真机（含 Android 12）验证通知权限、后台保活与通知点击。按任务要求，不做个人设备测试。
- 本次审计的截图是 Flutter widget harness 对生产 widget 树的渲染（合成数据、固定视口），不是 OS 通知截图；Windows/Android 系统通知没有可截图的现状，因为没有消息通知链路。
- 未跑 `flutter build windows` / `flutter build apk --debug`（发布构建由 release/Lead 统一执行）；未验证 toast 在用户关闭通知/专注助手时的表现。
- 未验证宿主在真实 WebSocket 推送下的事件（当前客户端未接 `connectStream`；host 侧也不推送）。
- 未读取 `%LOCALAPPDATA%\Jingyu` 等真实用户目录；未写入任何真实数据。

## 6. 文档口径建议（供 Lead 更新，不在本文件直接改）

- `docs/acceptance.md` AC-16 保持「部分（外壳已实现，待实机）」并把「消息系统通知」明确列为未交付；AC-30 保持「未实现」。
- `docs/requirements-traceability.md` 有两处需 Lead 决定：REQ-M15-03 保持「路由验证通过，不计系统推送或端到端收件箱」；REQ-M15-04 在基线 `38cd86c` 实际已包含客户端收件箱接线与绿测（本审计可证明），与「#116 OPEN、未入基线」的描述不一致，应更新为「已实现/已验证（邀请子集）」并把「新消息通知中心/系统通知」登记为二期需求。
- `README`/发布说明只能写：收件箱（待处理好友邀请）+ 会话未读 Badge + 设置里的隐藏正文开关；不得写「系统通知/锁屏通知正文隐藏已支持」。二期清单写明：新消息通知中心、失焦/最小化系统通知（Windows/Android）、点击打开会话、消息级隐私与锁屏策略。

## 7. 对照 FR-09 / FR-11 / AC-16 / AC-30（v4.2 原文）

来源：`鲸言鲸语-需求规格-v4.2.md` §§113–118（FR-09）、§§125–128（FR-11）、AC-16（第 702 行）、AC-30（第 716 行）；`docs/acceptance.md`、`docs/requirements-traceability.md`。

| 条款 | 原文要点 | 基线 `38cd86c` 现状 | 判定与本期口径 |
|---|---|---|---|
| FR-09 双端客户端 | 手机 Android / 电脑 Windows，建议 Flutter 单代码库；**同一账号双端在线，消息、未读、收藏、设置实时同步**；Windows 托盘常驻、开机自启、全局快捷键、**原生通知**，未打包 exe 也必须有显式 AUMID 开始菜单快捷方式；Android **前台服务 + WebSocket 保活**、系统分享、悬浮窗/来电界面；双端共用主题/背景/字号 | 双端客户端源码存在（REQ-005 未跑客户端验收）；Windows 托盘/宠物/自启/快捷键/AUMID 快捷方式与 `notify` toast 函数存在；Android 保活前台服务存在；会话未读 Badge 有（**拉取式**）；无 WebSocket 客户端消费（`connectStream` 无调用方），无「设置实时同步」；原生通知无 Dart 消息触发 | **未达 FR-09**：双端实时同步、原生消息通知、Android 长连接保活链路缺失；双端设备验收未执行。不得在交付说明中称 FR-09 完成 |
| FR-11 通知体系 | Android：前台服务 + **长连接为主**；可选 ntfy 自托管推送兜底；**通知栏快捷回复**；Windows：**原生通知（AUMID）**、**托盘未读气泡（不显示正文）**；**免打扰、静默窗（FR-44）联动所有端**；**锁屏通知正文可设隐藏** | Android 仅连接保活通知与来电/未接通知（来电有 `hidePreview`）；Windows 原生 toast 函数/托盘 tooltip/宠物未读气泡存在但 Dart 从未调用（`setPetState`/`notify` 无调用方）；无消息通知；免打扰/静默窗未实现；隐藏正文开关可保存/迁移但无任何消息通知消费者 | **未达 FR-11**：消息通知触发、长连接、快捷回复、免打扰/静默窗、锁屏正文隐藏全部缺失；`hideNotificationBody` 目前只是「存起来的偏好」 |
| AC-16（第 702 行） | Windows 托盘/自启/快捷键/原生通知（AUMID）/悬浮宠物**可用**；Android 前台服务保活、来电降级路径**可用**且标「可能漏接」；系统分享面板接入生效 | `docs/acceptance.md` 记「**部分（已实现，待实机）**」：托盘/自启/AUMID 通知/Android 前台保活/来电降级/系统分享**未实测，无真机与日志**；代码层入口存在，客户端没有消息通知触发链路；宠物为静态原生形状非形象渲染器 | **部分且未验证**：原生通知只有入口、没有消息链路；无真机。AC-16 不得判通过 |
| AC-30（第 716 行） | 应用锁生效；**锁屏后通知正文可设隐藏** | 应用锁已实现（PIN/生物识别/生命周期锁定，含测试）；**锁屏通知正文隐藏未实现**（无消息通知；`acceptance.md` AC-30 已记「未实现/端侧未交付」）；来电通知有 `VISIBILITY_PRIVATE`+`hidePreview`，但那是来电而非消息 | **未达 AC-30**：应用锁部分可用；锁屏消息正文隐藏属二期 |

[项目交付路线图](../superpowers/plans/2026-11-18-project-delivery.md)也将系统通知列为后续工作。本次复核不更改路线或验收状态。