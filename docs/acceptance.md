# 验收矩阵：AC-01～AC-35 与 CR-01～CR-12（M13 hardening）

> 基线：origin/main `ef43bf8`（已合并 PR#68 语音 vendor 适配器、PR#69 avatar/Live2D 契约、
> PR#58/67 客户端外壳；更早的 PR#60 后端模块切片）；本票分支
> `agent/acceptance-matrix/takeover-pr-rebase-status-aab5824adc83`。环境：Windows x64，
> Dart SDK 3.14.0（`dart pub get --offline`），`apps/host` 默认宿主装配，临时数据目录。
> 记录日期：2026-11-17。

## 阅读须知（状态口径）

本文件区分三类证据，**不把矩阵完整当成产品验收通过**：

- **本票实测（fresh，§A3）**：本次对已合并切片运行的新增 host 验收回归 + 既有 PR#68/PR#69
  host 测试 + client_kit Live2D 包测试，命令与结果可复现。
- **历史记录（§A/§A2/§E）**：PR#60/M13 前序票据的回归与 init 记录，**本票未重跑**，保留作背景。
- **基线证据**：`docs/requirements-traceability.md` / `docs/implementation-status.md` 的历史结论。

状态取值：`通过（子集）`、`部分（基础切片）`、`部分（已实现，待实机）`、`部分（包校验+参考契约）`、
`部分（本票未重跑）`、`未覆盖`、`未实现`。凡是“未装配 / 无真实厂商 / 无真机 / 无 UI”的判据，
一律如实标缺口，不写通过。

> **来源边界**：host 侧 avatar/VRM/Live2D 契约是**宿主参考契约**（只登记 modelId/profileRev 引用，
> 不含模型字节/paramMap）。client_kit 的 `live2d_package/profile/store` 测试是**客户端包契约**证据，
> 独立运行；不混称“host 直接覆盖”。

测试夹具说明（透明性）：默认宿主的 PBKDF2(600k) 口令派生在受限离线机器上每次约 11 秒。
§A/§A2 的 M13 回归夹具**只跳过口令哈希**（经账号存储契约播种账号/设备行并生成合法 bearer），
其余鉴权/可见性/加密/审计仍走真实代码；§A3 的语音/avatar 回归使用**注入假 transport**，不建
socket、不连厂商。

---

## A. 前序 PR#60 回归套件记录（历史，保留背景；本票未重跑）

命令（在 `apps/host` 下）：`dart pub get --offline` → `dart analyze --fatal-infos test/regression`
→ `dart test test/regression -r expanded --concurrency=1`。

历史实测：analyze No issues；`dart test test/regression` `+23` 通过、`~11` 跳过、EXIT 0。

| 文件 | 通过 | 跳过 | 覆盖要点 |
|---|---|---|---|
| `cross_user_test.dart` | 8 | 3 | 正向对照 + A 看不到 B 的群/同步/搜索/收藏/文件/附件 + 每个 GET 读接口扫描不泄露 B 正文/收藏/附件/key + 非管理员访问管理端 403 |
| `admin_no_content_test.dart` | 4 | 1 | 每个 `Access.admin` 只读路由不含正文/收藏/附件正文/明文 key；A-8 旧版正文路由例外单独验证；审计流无正文 |
| `outbound_test.dart` | 4 | 1 | 结构不变式（出站 socket/HttpClient 只在 `guarded_http.dart`）+ `UrlGuard.isBlocked` + 出站组件依赖注入接缝 + `RecordingUrlGuard` 证明 provider base_url 保存前必经校验 |
| `audit_coverage_test.dart` | 7 | 6 | `message.edit`/`message.recall`/`provider.create`/`group.name.set`/`group.announcement.set`/`topic.create`/`topic.reference.associate` 均写审计 |

历史跳过项（未覆盖，非通过）：记忆/动态/日记/朋友圈域、客户端展示隔离、真实出站运行时、
管理端记忆正文、需 AI 档案/好友图/多成员的审计动作。

---

## A2. M08/M09/M10/M12 基础切片回归（历史 PR#60 记录，本票未重跑）

历史实测：`dart test`（quota/cleanup/export_import/departure/lifecycle/voice/creative/world 等
16 文件）**142 项通过，EXIT 0**。覆盖 M08 语音内存适配器、M09 报告/电台、M10 layout/寻路/
presence/avatars、M12 配额/清理/导出导入/离开。未覆盖：真实厂商适配器、路由/默认装配、
客户端/UI、真实磁盘/备份。

---

## A3. 已合并切片回归（fresh，本票重跑）

**命令（在 `apps/host` 下）：**

```powershell
dart pub get --offline
dart analyze --fatal-infos test/regression/merged_slices_acceptance_test.dart
dart test test/regression/merged_slices_acceptance_test.dart -r expanded
dart test test/voice_vendor_adapter_test.dart test/voice_routes_test.dart test/voice_test.dart `
  test/world_test.dart -r expanded --concurrency=1
```

**命令（在 `packages/jingyu_client_kit` 下；本沙箱需 `--compiler source`，见下注）：**

```powershell
dart pub get --offline
dart test test/live2d_package_test.dart test/live2d_profile_test.dart `
  test/live2d_store_test.dart -r expanded --concurrency=1 --compiler source
```

**实测结果：**

- 新增 host 验收回归 `test/regression/merged_slices_acceptance_test.dart`：**9/9 通过**，
  目标 `dart analyze --fatal-infos` **No issues found**（EXIT 0）。全部使用注入假 transport，
  不建 socket、不连任何厂商、不使用真实凭据。
- 既有 PR#68/PR#69 host 测试（`voice_vendor_adapter_test` + `voice_routes_test` +
  `voice_test` + `world_test`（含 AvatarRegistry 契约））：**75/75 通过**（EXIT 0）。
- 既有 PR#69 client_kit Live2D 包契约（`live2d_package_test` + `live2d_profile_test` +
  `live2d_store_test`）：**59/59 通过**（EXIT 0，`--compiler source`）。

覆盖要点：

- **AC-11/13 语音（host 适配器）**：TTS 走 `/v1/audio/speech`、ASR 走 `/v1/audio/transcriptions`，
  模型/音色/音频参数正确；`vendorKey` 恒为空（客户端不可见 key）；凭据只在 Authorization header、
  不进请求体/结果/错误文本；transport 失败 → TTS `modelUnavailable` / ASR `unavailable`；
  非法或带 query/fragment/userinfo 的 base_url → `forbidden` 且**零厂商请求**；vendor 500 时
  gateway 只降文字，`voiceId`/`provider` 保持不变（不换音色/厂商）。
- **AC-24/25 avatar（host 参考契约）**：VRM/Live2D 仅登记 `modelId/profileRev` 引用，`toJson`
  无 `paramMap/modelBytes`；按 `(owner, device)` 隔离；`active` 广播 `modelId+profileRev` 一致；
  跨设备 `enable`/`get` 返回 notFound；disable 前进 revision 并清 active。
- **AC-25 client_kit Live2D 包契约（独立来源）**：包校验（zip 安全、模型结构、纹理/MOC 魔数、
  资源预算、大小写重复）、profile 严格 DTO、store 快照无模型字节/绝对路径、paramMap round-trip。

**未覆盖（诚实标注，待实机验证）：**真实 TTS/ASR 厂商连通与真实凭据、真实音频播放、真机
Live2D 解包/渲染与热切换、托盘/自启/通知/Android 保活等端侧行为、日志落地。均未在本票执行，
不得把本子集当作真实厂商/真机已验收。

> 注：本沙箱默认 kernel 编译器在 `packages/jingyu_client_kit` 下会因测试编译器子进程路径解析失败
> 而无法加载用例；`--compiler source` 下 59/59 通过。该现象属本机运行环境问题，不是被测代码失败。

---

## B. AC-01～AC-35

| 编号 | 验收判据（摘要） | 本票实测 / 基线证据 | 结果 | 未覆盖 / 缺口 |
|---|---|---|---|---|
| AC-01 | 跨用户串数据回归全绿；管理端任何页面不返回他人正文、记忆正文、明文 key | §A 历史：`cross_user_test`（8 通过）+ `admin_no_content_test`（4 通过） | **通过（子集）** | 记忆/动态/日记/朋友圈域与客户端未装配；跨域串数据未覆盖 |
| AC-02 | 邀请并发兑换不双花；失败锁定；第 3 设备踢线且旧 token 失效 | 基线 M02 账号契约/HTTP/持久化与限流测试（REQ-004） | 部分（本票未重跑） | 并发双花、失败锁定、第 3 设备踢线专项未见本票通过证据 |
| AC-03 | 好友需同意；AI 无预授权不能加好友；拉黑后看不到朋友圈/不能私信 | 基线 friendship/private 后端（REQ-018） | 部分（本票未重跑） | AI 好友预授权、朋友圈不可见未实现；本票未重跑 |
| AC-04 | L0–L4 生效；改 L0 停主动；L4 受 max_turns/冷却/额度约束 | 基线 AI social-level 配置（REQ-054，仅配置） | 部分（内部能力） | L0 任务取消、实际回复、L4 开关与自动行为未接线 |
| AC-05 | 记忆分档/T1 不注入/T2 不外泄/冲突 supersede | 基线内部 MemoryStore（REQ-017） | 部分（内部能力） | 未生产装配，无端到端记忆注入口；跨用户/外部群授权未齐 |
| AC-06 | 档案编辑下轮生效；敏感字段不外泄；农历闰月；静默窗顺延 | 基线 persona 编辑/历史（REQ-020） | 未覆盖 | 农历闰月、静默窗顺延、档案注入链无证据；仅内部人格版本 |
| AC-07 | 无素材日记跳过；默认仅自己可见；分享标注；候选 pending | — | 未实现 | 日记模块未交付 |
| AC-08 | 候选事件默认 model_claim；确认才 confirmed；追问一次 | — | 未实现 | 候选事件/收件箱未交付 |
| AC-09 | 60s 规则心跳；额度用尽退规则；离线只记 gap | 基线内部 LifeEngine（REQ-022） | 部分（内部能力） | 无生产调度/主动行为/静默窗接线 |
| AC-10 | 6 类 provider 与绑定矩阵；key 无明文；私有 base_url 拒；重定向/DNS 复验 | 基线 REQ-010/012/013/053 + §A `outbound_test`（结构+接缝） | **部分（子集）** | 管理 UI、保存前连接测试、真实 provider 互通、6 类绑定全矩阵未覆盖 |
| AC-11 | 语音单 provider+voice_id；到期提醒/保活；故障降文字不换音色 | §A3：新增 `merged_slices_acceptance_test`（TTS/ASR 假 transport、key 不泄漏、降级不换音色）+ 既有 PR#68 `voice_vendor_adapter_test`/`voice_test`（75 项含 voice） | **部分（已实现，待实机）** | 真实厂商连通/真实凭据/真实音频/客户端 UI 未验证（不真连厂商）；不声明真实联通 |
| AC-12 | 生图工具按开关可见；to_friends 硬关；审批；标注生成；日上限 | — | 未实现 | 生图未交付 |
| AC-13 | 通话 Tailscale 路径；打断无回声；视觉脱敏；关闭视觉仍纯语音 | §A2 历史 CallService 状态机 + §A3 PR#68 vendor 适配器（TTS/ASR 仅音频，不含通话传输/视觉） | **部分（已实现，待实机）** | 真实 Tailscale 通话、回声消除、视觉理解/脱敏、真机端到端未实现 |
| AC-14 | 配额 80% 告警/100% 停大文件/磁盘<10% 全停；90 天清理留占位 | §A2 历史：`quota_*` + M12 `cleanup_test`/`cleanup_store_test` | **部分（基础切片）** | 真实 blob 删除/磁盘探测/存储适配器未接；内存实现 |
| AC-15 | 备份密文、30 天轮转、integrity_check、删除回执后快照不含其数据 | §A2 历史：M12 `export_import_test` + `departure_test` | **部分（基础切片）** | 密文备份 tar+age、30 天轮转、integrity_check 恢复演练未实现 |
| AC-16 | Windows 托盘/自启/通知；Android 保活/来电降级；分享面板 | PR#58/67 客户端外壳已合并（`apps/client_flutter`：shell/runtime/conversation mapping/world screen/settings/diagnostics） | **部分（已实现，待实机）** | 未在真机运行；托盘/自启/AUMID 通知/Android 前台保活/来电降级/系统分享未实测，无真机与日志 |
| AC-17 | 群 AI 默认仅 @；防刷屏；群记忆不串私聊；朋友圈可见性服务端判定；搜索不跨用户 | 基线群成员/群 AI 策略（REQ-007/023/024） | 部分（内部能力） | AI 自动发言 admission 未接实际发送事务；朋友圈/群记忆未做 |
| AC-18 | seq/ack/幂等/差集同步全绿；双端未读一致；断网补传不重复 | 基线设备 ack 子集（REQ-006）；§A cross_user 覆盖差集可见性 | 部分（子集） | WebSocket、双端未读、客户端 last_ack 持久化未接入 |
| AC-19 | 撤回/编辑留痕/引用/表情/置顶/提醒/定时/闪照/合并转发且留审计 | 基线服务端撤回/编辑/定时/表情/置顶（REQ-028~031/033）+ §A audit_coverage | 部分（子集） | 引用回复、闪照、合并转发、消息提醒、客户端入口未完成 |
| AC-20 | 收藏/浮窗/全局搜索按可见范围过滤；聊天文件夹双端同步 | 基线收藏/搜索/文件搜索（REQ-032/034/035/036/039/040）+ §A cross_user 隔离 | 部分（子集） | 浮窗、聊天文件夹双端同步、客户端 UI 未做 |
| AC-21 | 群语音房可进出、AI 旁听转候选、点名受约束、音频不录存 | — | 未实现 | 群语音房未交付 |
| AC-22 | 3D 街区寻路、位置权威在宿主、2–5Hz、门锁/超时日志 | §A2 历史：M10 `world_pathfinding_test`/`world_test` | **部分（基础切片）** | 3D 渲染、2–5Hz 同步/插值、客户端、门锁/超时日志未实现 |
| AC-23 | 拜访小院/室内邀请/访客上限 4/主人不在 AI 接待可关 | §A2 历史：M10 `world_test`/presence 契约基础 | **部分（基础切片）** | 完整拜访规则/室内邀请/访客上限/接待开关/客户端未实现 |
| AC-24 | 卡通化身可换装/肤色/发型并同步；不做真人相似 | §A3：新增 `merged_slices_acceptance_test`（host AvatarRegistry reference-only）+ 既有 PR#69 `world_test`（AvatarRegistry 契约） | **部分（已实现，待实机）** | 卡通化身换装/渲染/双端同步仅参考契约；真机渲染与客户端未验证 |
| AC-25 | 各端本地导入/param_map；模型与映射只存本设备、不跨端同步 | §A3：client_kit `live2d_package/profile/store` 59 项通过（包校验/profile DTO/store 无模型字节）+ host AvatarRegistry 按设备隔离 | **部分（包校验+参考契约）** | 真实解包渲染、设备持久化、完整安全导入与热切换未实现/未验真机 |
| AC-26 | 同账号手机与电脑各用不同模型互不影响；缺资源回退 VRM；不分发模型/Cubism 资产 | §A3：`world_test` 覆盖同 owner 手机/PC 独立启用与互不可读；client_kit store 快照不含模型字节 | **部分（契约已测，待实机）** | 真实 VRM 回退、真机渲染与资产分发未验证 |
| AC-27 | CR-01～CR-12 主路径全部通过、边界生效 | §A2 历史：CR-03/CR-07 基础切片，其余 CR 未实现 | **部分（基础切片）** | 仅 CR-03/CR-07 宿主逻辑基础；其余 CR 与所有客户端/UI/装配未交付 |
| AC-28 | AI 提议收件箱汇总待决；未批准不生效；过期失效留审计 | — | 未实现 | 提议收件箱未交付 |
| AC-29 | 隐私仪表盘；导出完整可导入；删除回执 | §A2 历史：M12 `export_import_test` + `departure_test` | **部分（基础切片）** | 隐私仪表盘未实现；导出/导入/回执为内存实现，未接真实存储/UI |
| AC-30 | 应用锁；锁屏通知正文可隐藏 | — | 未实现 | 端侧未交付 |
| AC-31 | 从零部署无旧依赖；一键初始化脚本可搭建宿主 | §E 历史：`tool/init_host.ps1` 端到端 EXIT 0 | **通过（子集）** | 仅本机 `127.0.0.1` 回退验证；真实 tailnet 探测未测 |
| AC-32 | 图片/文件给 AI 上下文提示；草稿持久化；群主可转让；通话字幕开关不落历史 | 基线群主转让后端（REQ-023） | 部分（内部能力） | 图片/文件上下文提示、通话字幕未实现；草稿仅客户端纯 Dart（未接外壳） |
| AC-33 | S1/S2 路由；S1 秒回不写记忆/事实；衬垫/拟人延迟可关；不确定升级 S2 | 基线 brain 规则/路由内部测试 | 部分（内部能力） | 无自动回复入口装配；衬垫/拟人延迟未做 |
| AC-34 | 梗库三层命中失效；新梗入收件箱；领域卡组 ≤500 字不落历史；领域外说不熟 | 基线 brain meme/domain 测试 | 部分（内部能力） | 未装配到回复链；收件箱未做 |
| AC-35 | token 五层降级；缓存复用；预算观面板；闲聊消耗较基线下降可量化 | 基线预算/用量内部账本（REQ-015/044/045/051） | 部分（内部能力） | 缓存复用、预算观面板、对比基线量化未做 |

---

## C. CR-01～CR-12

| 编号 | 功能 | 结果 | 缺口 |
|---|---|---|---|
| CR-01 | 灵魂画布（实时共创画布） | 未实现 | 产品未交付 |
| CR-02 | 时间胶囊 | 未实现 | 产品未交付 |
| CR-03 | 关系周报与年度报告 | **部分（基础切片）** | M09 `ReportsService`：按期生成/范围过滤/预算门/可选信；分享图/水印/UI/默认装配未接 |
| CR-04 | 情绪天气 | 未实现 | 产品未交付 |
| CR-05 | 双人小剧场（角色扮演） | 未实现 | 产品未交付 |
| CR-06 | 共同目标（习惯打卡） | 未实现 | 产品未交付 |
| CR-07 | 深夜电台 | **部分（基础切片）** | M09 `RadioService`：定时生成/离线缓存语义/预算/音色档案；真实 TTS/客户端/默认装配未接 |
| CR-08 | AI 群主持人 | 未实现 | 仅有群 AI 限流配置（REQ-024），不构成主持行为；主路径未交付 |
| CR-09 | 生成式礼物 | 未实现 | 产品未交付 |
| CR-10 | 记忆博物馆 | 未实现 | 产品未交付 |
| CR-11 | 语音信箱 | 未实现 | 产品未交付 |
| CR-12 | 便利贴（她的备忘） | 未实现 | 产品未交付 |

---

## D. 汇总

- **本票 fresh 新证据（§A3）**：新增 host 验收回归 9/9；既有 PR#68/PR#69 host 测试 75/75；
  既有 client_kit Live2D 包测试 59/59。据此 AC-11/13/24/25/26 记为“部分（已实现，待实机）/
  部分（包校验+参考契约）”，AC-16 记为“部分（外壳已实现，待实机）”。
- 历史 §A/§A2：AC-01（子集）、AC-14/15/22/23/27/29（基础切片）、AC-31（子集）。
- AC-10/17/18/19/20/32/33/34/35 等为“部分（内部能力/子集，多数未本票重跑）”；其余 未覆盖/未实现。
- CR-01～CR-12：仅 CR-03/CR-07 有宿主基础切片，其余 未实现。
- 本矩阵**不构成产品验收通过**；真实厂商连通、真机渲染/端侧行为均为**待实机验证**，不是通过。
- **M14 增量（见 §F）**：`GET /api/v1/friends`、`GET /api/v1/lifecycle/cleanup/preview` 已验证
  （host 单测/真 SQLite + 默认装配断言）；客户端联系人/创作/语音/附件查看/Settings 分组/清理预览
  为 widget/loopback 已验证、**待真机**；`GET /attachments`（列表）**待实现**。

---

## E. AC-31 一键初始化实测（历史 PR#60 记录）

脚本：`tool/init_host.ps1`。命令（空目录、本机回退地址；口令为合成测试值）：

```powershell
pwsh -File tool/init_host.ps1 -DataDir <全新空目录> -AdminName Root `
  -AdminPassword '<>=12位合成口令>' -BindAddress 127.0.0.1 -Port 8799
```

历史实测结果（Windows 10.0 / PowerShell 5.1，2026-11-16）：**EXIT 0，耗时约 40s**，输出：

- 管理员账号：`c6iG5aXoYvAzUVM1ZWHVRg`（新库生成）
- 首个邀请码：`bDLppufl3Cr8oqcGEcsFJQ`（管理员登录后经 `POST /api/v1/admin/invites` 生成）
- 监听地址：`127.0.0.1:8799`（写入 `host.env`）
- 数据目录产物：`host.sqlite`（约 516 KB，含全部迁移）、`host.sqlite.kek`、`host.env`、
  `init-server.out/err.log`。全新目录、无任何旧库/旧配置/旧路径。

结论：**AC-31 通过（子集）**——从零建库、唯一管理员、首个邀请码、监听配置写入均已实测。
限制：本次用 `127.0.0.1` 回退（沙箱无 tailscale），脚本的 tailnet 地址自动探测逻辑未实测；
管理端仍是 HTTP 后端，无 UI。

---

## F. M14 增量验收：新增路由与客户端页（2026-11-18）

> 基线：`origin/main 8dafa17`。本票只更新文档与测试（新增
> `apps/host/test/regression/m14_read_route_surfaces_test.dart`），**未改产品代码**。
> 状态口径：`已验证（单测/loopback）` = 有可复现自动化检查；`待确认` = 依赖尚未合并的
> 能力；`待真机` = 需真实设备/真实厂商/真实后端数据才能验收。

### F.1 Host 只读路由

| 项 | 实现位置 | 证据 | 状态 |
|---|---|---|---|
| `GET /api/v1/friends`（owner-scoped 好友列表） | `Routes.friends`；`FriendshipService.listContacts()`；`friendship_routes.dart`；默认宿主经 `SocialModule` 装配 | `apps/host/test/friends_list_route_test.dart`（真实 SQLite：空列表/owner 隔离/状态映射/schema 安全）；`m14_read_route_surfaces_test.dart` 断言默认装配已挂载且为 `[authenticated]` | **已验证（host 单测/真 SQLite）** |
| `GET /api/v1/lifecycle/cleanup/preview`（只读保留期清理预览） | `Routes.lifecycleCleanupPreview`；`lifecycle_module.dart::_cleanupPreview`（owner-scoped、拒绝 query/body、异常 safe 500、绝不执行清理） | `apps/host/test/lifecycle_cleanup_preview_route_test.dart`；`m14_read_route_surfaces_test.dart` 断言默认装配挂载且为 `[authenticated]` | **已验证（host 单测）**；真实清理未执行（只读预览） |
| `GET /api/v1/attachments`（附件**列表**） | 已由 m12 实现为 **PR#107**（commit `39723f0`：`AttachmentService.listOwn` + `router.get(Routes.attachments, _list)`，owner-scoped、不含 extractedText）；**尚未被外部自动合并进 main**（本基线 8dafa17 早于它） | `m14_read_route_surfaces_test.dart` 以 skip 记录（待 #107 合并后启用） | **已实现（PR#107 ready，待自动合并/合并后联调）** |

### F.2 客户端页面

| 项 | 实现位置 | 证据 | 状态 |
|---|---|---|---|
| 联系人（真实好友） | `features/contacts/contacts_screen.dart` + `net/friends_api.dart` | `contacts_screen_test.dart`、`friends_api_test.dart` | **已验证（widget/loopback）**；真机待 |
| 创作运行时 | `features/creative/creative_screen.dart` + `net/creative_api.dart` | `creative_screen_test.dart`、`creative_api_test.dart` | **已验证（widget/loopback）**；真实宿主数据/真机待 |
| 语音 polish/gap | `features/voice/voice_screen.dart` + `net/voice_api.dart` | `voice_screen_test.dart`、`voice_api_test.dart` | **已验证（widget/loopback）**；真实厂商音频/真机待 |
| 附件诚实查看 | `features/attachments/attachments_screen.dart` | `attachments_screen_test.dart` | **部分已验证（查看器 widget）**；真实**列表**依赖 `GET /attachments`（PR#107 已实现、待合并） → **待确认** |
| Settings 分组 | `features/settings/settings_screen.dart`（开发者区分组） | `settings_developer_groups_test.dart` | **已验证（widget）** |
| 清理预览（客户端） | `net/lifecycle_api.dart::readCleanupPreview` + `features/lifecycle/backup_quota_screen.dart` | `lifecycle_cleanup_preview_api_test.dart`、`backup_quota_actions_test.dart` | **已验证（API/loopback + widget）**；真实清理执行未做 |

### F.3 汇总与限制

- Host 路由：`friends`、`lifecycle/cleanup/preview` **已验证**（单测/真 SQLite + 默认装配断言）；
  `GET /attachments` 列表**待实现**。
- 客户端：以上页面均以 **widget/loopback** 证据判为已实现/已验证；**全部未在真机运行**，
  真实厂商、真实后端数据、通知/托盘/自启动等端侧行为仍属**待真机验证**。
- 附件“列表”页在 host `GET /attachments` 列表路由（PR#107）合并前不计完成（查看器单页可查看 URL 直取的单附件）。
