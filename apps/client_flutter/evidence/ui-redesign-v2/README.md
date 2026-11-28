# UI redesign v2: Before/After harness renders

These are harness renders for the v2 client redesign (ticket ui-redesign-v2-58efb3240b0f). They come from `flutter test` with a fake model. They are not native-window captures and do not show a live host.

- `ui_redesign_v2_capture_test.dart` is the capture test. A `CaptureModel` (extends `TestShellModel` from `test/ui_test.dart`, with a `noSuchMethod` fallback) drives the real `WhaleChatApp`. Each scenario renders at 412x915 or 1280x800 logical pixels (device pixel ratio 1), in light or dark, and is saved as `<scenario>-<size>-<theme>.png`. The test only runs when `CAPTURE_OUT` is set. A plain `flutter test` of the file reports one skipped test.
- `ui_redesign_v2_sample_data.dart`, next to the test, builds the pages of the `-data` scenarios with their sample data (see States with data below).
- Scenarios reach their page the way a user does: they tap a conversation row, a navigation destination, the settings button, an entry in settings or 下一步. A chat opens as its own page on the phone and in the right pane on the wide layout. Long lists are scrolled by setting the scroll offset. When a step fails, the test prints `CAPTURE_WARN`. The `-data` scenarios push their page directly instead.
- `before/` holds main `0300369`. Each batch was rendered in the clean detached baseline worktree from a byte-identical copy of the test (SHA-256 checked) and, for the `-data` scenarios, of `ui_redesign_v2_sample_data.dart`. Afterwards the copies, their directory and `build/` were removed, and the worktree was clean again.
- `start-11a30e0/` holds the eight renders that come out differently on `11a30e0`, where the redesign branches start. See the last section.
- `after/` will hold the integration branch once the pages are merged.

Fonts: icon fonts load from the app's `FontManifest.json` under their own family names. Microsoft YaHei (`%WINDIR%\Fonts\msyh.ttc`) stands in for every text family, so Chinese renders as it does on Windows. Each scenario advances a fixed 2 s (20 × 100 ms) before capture, without `pumpAndSettle`.

## Before (main 0300369)

Every scenario has four files: `<scenario>-412x915-light.png`, `-412x915-dark`, `-1280x800-light` and `-1280x800-dark`: 84 for the 21 scenarios in the first table and 32 for the eight `-data` scenarios further down, 116 in all. Every render run exited 0 with no framework exceptions and no `CAPTURE_WARN`, and every image was viewed.

| Scenario | State | What the render shows |
|---|---|---|
| `conversations` | Signed in and online; six conversations with previews and unread counts, none open. | Title 聊天 with 在线 and the settings button, 创建群聊, 刷新会话, six rows with badges 1/2/12. Phone: bottom navigation 聊天/联系人/动态/收件箱/世界. Wide: navigation rail, the list, and 选择一个会话，开始聊天 on the right. |
| `conversations-empty` | Signed in and online; no conversations. | 暂无会话 / 可以创建群聊，或等好友发来消息。 |
| `conversations-offline` | Signed in, offline; nothing loaded. | 离线 in the title bar, 创建群聊 disabled, 暂时离线 / 恢复连接后，会显示你的聊天。 |
| `conversations-error` | Signed in and online; reading the conversations failed. | Error banner 会话读取失败，请稍后重试 with a close button, 没有可显示的会话, 重新读取. |
| `chat-empty` | The group 读书会, just created, opened from the list. | 读书会 / 已连接, 还没有消息 / 发一条消息，开始这段对话。, 提及 AI 并发送, the composer. Phone: a back button in the chat header. Wide: 读书会 selected in the list. |
| `chat` | The friend chat with 林雾: text both ways, an image, an edited and a recalled message, one message waiting to be sent and one that failed. | Bubbles with 已发送, 已编辑, 消息已撤回, 等待补传 and 发送失败, and 灯光展海报.jpg with 查看图片. Wide: the oldest message is above the visible area, because the list is anchored at the newest message. |
| `chat-companion` | The direct chat with the user's own AI companion 小鲸. | Looks like any direct chat: Before has nothing specific to the companion. |
| `chat-busy` | The `chat` conversation while the app is busy, with an unsent draft. | Progress bar under the app bar. 查看图片 is disabled, and on wide so are 创建群聊 and 刷新会话. The composer is disabled, with the draft 我可能会晚十分钟到。 greyed out. On 11a30e0 the composer stays enabled (see the last section). |
| `settings` | Settings, opened with the settings button in the title bar. | 鲸言鲸语 and 在线 in the title bar, a back button and 设置, then 隐私与安全 (应用锁, 隐藏通知正文 switched on, 允许 AI 读取附件 disabled, 设备会话) and 通用 (开机自启动, 外观 跟随系统/浅色/深色, 字体大小 · 100% with its slider). Phone: no bottom navigation, and the list reaches the start of 开发者. Wide: the navigation rail stays. |
| `settings-own-ai` | Settings scrolled to the end of its list. | 我的 AI with 刷新我的 AI and 创建 AI 账户, and the own AI: 小鲸 · 未停用, ai-xiaojing, 私聊授权：已开启, then 刷新授权状态, 撤销私聊授权 and 打开私聊. Above it are AI 运行配置编辑 and the read-only entries 模型能力与预算诊断, 配额与生命周期状态 and 消息搜索 (wide: also AI 运行配置体检). |
| `contacts` | The 联系人 tab. | 联系人 with its read-only note and 当前未连接宿主，无法读取联系人。 |
| `creative` | The 动态 tab. | A read-only note with a greyed-out 刷新, and 创作内容需要接入宿主连接后显示；宿主读取接口已就绪。 |
| `inbox` | The 收件箱 tab. | 当前未连接宿主，无法读取收件箱。 / 连接后可查看待处理的好友邀请。 |
| `world` | The 世界 tab. | 世界与形象 (形象与房间已设置。), 形象模型（各端本地）, the 3D 渲染 notice 三维街区/房间渲染尚未接入, and 打开模块测试与性能探针. |
| `voice` | 语音音色, opened from settings. | A read-only note, the AI 档案 id field and 读取 disabled (当前入口未接线宿主连接，读取不可用), and the 语音文件 panel, 当前不可用. |
| `voice-calls` | 语音通话列表, opened from settings. | Two lines; the second is 当前入口未接线宿主连接：通话列表不可用（需装配 VoiceCallApi）。 The rest of the page is empty. |
| `ai-config-check` | AI 运行配置体检, opened from settings. | A read-only note and 状态未知：未连接宿主或读取失败；不会自动重试。 The rest of the page is empty. |
| `ai-config-edit` | AI 运行配置 (the editor), opened from settings. | 没有可配置的自有 AI, 尚未解析到 AI 档案 and 未连接宿主；无法编辑配置。, then the 人格 and Provider cards with their buttons disabled. |
| `onboarding-host` | Signed out: onboarding step 1/3. | 连接你的宿主 with 宿主地址, 新建账户 / 已有账户, 邀请码, 显示名称, 设备名称, 账户密码 and 连接宿主. Wide: the same column, centred. |
| `onboarding-character` | Signed in as account-a, world setup not done: step 2/3. | 选择你的形象 with 账号 ID：account-a, the choices 小鲸 (selected), 小狐 and 小猫, then 下一步 and 稍后设置，先进入聊天. |
| `onboarding-room` | Step 3/3, after tapping 下一步. | 创建你的房间 with the presets 安静书房 (selected), 创作空间 and 花园小屋, 生成预览, 尚未生成预览。, 确认并进入 disabled, and 稍后设置，先进入聊天. |

Pages that read from the host: on 0300369 the shell and settings wire their host readers only when the model is a `ClientRuntime` with a live connection. `CaptureModel` is not one, so `contacts`, `creative`, `inbox`, `voice`, `voice-calls`, `ai-config-check` and `ai-config-edit` show their state without a host connection. The `-data` scenarios below show the same pages with data.

Render log (time +08:00, test SHA-256 prefix):

- 2026-11-25 01:14: `conversations-412x915-light`, test `BEA36212D828`.
- 2026-11-25 01:46: all four `conversations*` scenarios, test `6618766F5463`. `conversations-412x915-light` came out byte-identical to the 01:14 render.
- 2026-11-25 02:16: all eight scenarios, test `409629982FFF`. The 16 `conversations*` images came out byte-identical to the 01:46 renders.
- 2026-11-25 03:39: all 21 scenarios, test `04FBB86F2204`. The 32 images committed before came out byte-identical.
- 2026-11-26 07:48: all 29 scenarios, test `79C0BBFC94B0`, sample data `A89D5BE1107C`. The 84 images committed before came out byte-identical, and so did the 32 `-data` images of a first run at 06:54, when the two files differed only in comments.

### States with data

`ui_redesign_v2_sample_data.dart` builds eight pages with their public constructors, using only arguments that the widget tests in `test/` already pass. Fake loaders return its sample rows at once. Accept and deny do nothing and the AI config writer throws, so nothing reaches a host. Each `-data` scenario starts from the signed-in conversation list and pushes its page on the root navigator, so the page fills the window at both sizes. The tab pages (联系人, 动态, 收件箱) show without the navigation bar or rail and without a back button. The other pages show their app bar with a back button. Compare After `-data` renders with these, not with the tab scenarios. The names come from the capture test's sample conversations: the user is account-a, and 小鲸 is the own AI, account ai-xiaojing with AI profile profile-xiaojing. None of it is real personal data. When the redesign changes one of these constructors, only this file changes.

| Scenario | Data | What the render shows |
|---|---|---|
| `contacts-data` | 联系人: incoming friend requests from 阿哲 (azhe) and 阿青 (aqing), and the friends 林雾 (linwu) and 妈妈 (mom). | The header and read-only note, four rows with 对方请求添加你 or 好友, 接受 and 拒绝 on the two requests, then 按账号 ID 查询关系 and 查询关系. |
| `creative-data` | 动态: weekly reports 2026-11-22 (generated), 2026-11-15 (missed) and 2026-11-08 (deferred), the annual report 2025, and the radio episodes 2026-11-25 (cached for offline play) and 2026-11-24. | 关系周报 / 年报 with 已生成 · 共同话题：徒步、灯光展、读书会, 已错过, 待重试 and 已生成 · 共同话题：旅行、读书、电影 (the two generated reports can expand), then 深夜电台 with 可离线播放 or 在线播放 and each script. |
| `inbox-data` | 收件箱: pending friend requests from azhe and aqing, a weekly report notice from ai-xiaojing (unread), a group invite to 周末徒步小队 and a friend request from linwu (both accepted). On 0300369 the host only sends friendRequest notifications; the other two kinds are made up for the sample. | 刷新收件箱, five rows with 来自, the sender id and the time: 接受 and 拒绝 on the two pending requests, the status on the others, and the note under the list. Phone: the timestamps wrap. |
| `world-data` | 世界状态, the page that settings opens (the 世界 tab is a different page), for space home: the layout is read, presence is not found, avatars are denied. | The read-only note, home in the space field, 刷新/加载, then 世界布局 · 已读取 (version 5, 温馨木屋, #6FA8DC, three rooms), 在场 · 未找到 and 形象 · 无权限. |
| `voice-data` | 语音音色 after entering profile-xiaojing and tapping 读取: revision 3 (vendor-a, tts-model-2, voice-xiaojing) with revision 4 pending. | 已读取音色档案（只读）, the profile card (provider, model, voiceId, revision 3, consentRef, activatedAt, 待生效 revision：4, 待生效参数键：speed, 参数键：speed、pitch) and the 语音文件 panel, 当前不可用. |
| `voice-calls-data` | 语音通话列表: three calls with ai-xiaojing, on 2026-11-25 (ended), 2026-11-24 (missed) and 2026-11-23 (ended). | 状态过滤 全部, 刷新, and three cards, 已结束, 未接来电 and 已结束, each with the call id, AI profile, peer account and start time. |
| `ai-config-check-data` | AI 运行配置体检: persona, bindings and provider configured, budget not. | 人格 · 已配置 (profile-xiaojing, version 3, the p0–p2 fields), 绑定 · 已配置 (chat and tts on provider-main), 预算 · 未配置, and Provider · 已配置 (vendor-a, its base URL, the mask sk-…7f2c, 已启用, 能力：chat、tts). |
| `ai-config-edit-data` | AI 运行配置 (the editor) for the own AI ai-xiaojing, whose profile resolves to profile-xiaojing. | ai-xiaojing selected, 档案：profile-xiaojing, and the 人格 card with its fields and 初始化人格 and 保存人格修改 enabled. 导入人格文件 and 读取人格历史 stay disabled (no file picker or history reader is passed). The Provider card starts at the bottom edge. |

Between `0300369` and `11a30e0` only `chat_pane.dart` and `settings_screen.dart` change in `lib/` (see the next section). None of these pages uses them, and the pushed page covers the shell. So the `-data` scenarios were not rendered on `11a30e0` and have no `start-11a30e0/` counterpart.

## 0300369 and the redesign start 11a30e0

`0300369` is an ancestor of `11a30e0`, where the redesign branches start. `11a30e0` itself only adds `design-system/`. Four commits in between change `lib/` or `test/`:

| Commit | Change | Effect on the scenarios |
|---|---|---|
| `f61a2cc` | Keep image preview proportions and allow pinch zoom (`chat_pane.dart`) | None: no scenario opens the image preview. |
| `218de50` | Keep the composer focused while the model is busy (`chat_pane.dart`) | `chat-busy` |
| `e11cb49` | Let the scroll settle before tapping in the settings entry test | None: it only changes a test. |
| `2036f56` | Preview the font size while dragging and save it once, on release (`settings_screen.dart`) | `settings` |

On 2026-11-25 at 03:45 the same test (`04FBB86F2204`) ran on team/qa `5e033d8`, whose `lib/`, `test/` and pubspec files match `11a30e0`. 76 of the 84 renders came out byte-identical to `before/`. The other eight are in `start-11a30e0/`:

- `chat-busy`: only the composer differs (rows 851–906 at 412x915, 736–791 at 1280x800). It stays enabled while the app is busy, and the draft 我可能会晚十分钟到。 is no longer greyed out.
- `settings`: a box under the font size slider, 预览：消息和输入框中的文字会显示成这样。, pushes the rest of the list down (from row 752).

The light renders were viewed; the dark ones differ in the same rows. These two changes come from the commits above, not from the redesign, so compare After `chat-busy` and `settings` with `start-11a30e0/` as well as with `before/`.
