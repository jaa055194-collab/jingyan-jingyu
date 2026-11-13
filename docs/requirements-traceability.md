# 需求追踪与验收

读取日期：2026-11-13。需求基线为仓库 v4.2 及 docs/architecture/02-decisions.md 中有原始需求答复支持的条目。此记录不代表全产品已验收；本次工作属于同一次完整交付中的实现过程。

| ID | 来源/版本/章节 | 原始要求摘要 | 审批状态 | 验收条件 | 实现位置/PR | 测试或检查 | 证据与版本 | 状态/缺口 |
|---|---|---|---|---|---|---|---|---|
| REQ-001 | plugins/01-plugin-spec.md §3–4；2026-11-13 插件化答复 | 插件私有存储按 id 隔离，激活期持续可用，停用释放 | 已授权 | 激活写入后连续指令能读写相同状态；不同插件同名键隔离；卸载和激活失败后上下文不可用 | packages/jingyu_client_kit/lib/src/plugin_host.dart | plugin_context_test.dart：激活/连续调用/隔离/重载/失败重试/能力快照/停用/未授权拒绝 | main 3c81587 后工作树；Windows Dart 3.14；2026-11-13 局部7测及全包18测通过 | 验证通过；仅内存，不声明跨重启持久化 |
| REQ-002 | v4.2 FR-63；decisions B-6 | 20GB默认可调配额，80%告警，满额只停大文件；磁盘<10%全停新上传 | 已授权 | 80%与100%阈值，50MiB边界及磁盘10%边界符合原要求；文字/图片不计用量，语音仍可发送 | apps/host/lib/src/lifecycle/quota.dart | quota_test.dart：16个策略/名额行为测试 | main 3c81587 后工作树；Windows Dart 3.14；2026-11-13 test与analyze通过 | 已实现未验证（集成）；纯策略测试通过，尚未接入实际上传/磁盘计量；单位按GiB/MiB |
| REQ-003 | decisions B-6 | 分片8MB，每账号并发上传≤3 | 已授权 | 策略返回8MiB分片，第四次申请拒绝，其他账号独立，重复/跨闸门释放不增加名额 | 同上 UploadGate | quota_test.dart：名额获取、释放、隔离和非法输入 | 同 REQ-002 | 已实现未验证（集成）；仅单isolate内名额，不代表上传端已执行 |
| REQ-004 | modules/M02-accounts.md；FR-04～07 | 账号、邀请、设备及权限 | 已授权 | 按M02验收逐项执行，含串数据和即时撤销 | apps/host/lib/src/accounts/ | accounts_test.dart；核心测试后仍须HTTP/SQLite验收 | 当前工作树；同步KDF缺陷已由独立评审检出，异步修复验证中 | 领域核心与 SQLite 实现已实现并通过上述测试；仍无 HTTP 路由、AccountsModule/迁移装配进 StorageModule、生产鉴权装配、IP/账号/邀请码多维限流，邀请码签发后无法经服务获得可撤销 id；不是完整 M02 验收 |
| REQ-005 | modules/M11-client-shell.md；FR-09 | Windows和Android客户端及插件接入 | 已授权 | 双端构建/设备行为/同场景Before–After证据齐备 | 尚无Flutter应用 | 未执行 | main 3c81587 无client_flutter | 受阻：设备信任契约未完成；readConversation/modelInvoke上下文未接入；不能用管理员身份冒充宿主设备 |

## 当前验证记录

在 main 3c81587 加 PR #6（a1ad4e7）存储变更及本分支账号、配额、插件改动的工作树上，`powershell -ExecutionPolicy Bypass -File tool/check.ps1` 于 2026-11-13 17:2x 全部通过（ALL CHECKS PASSED）：core 20、protocol 9、host_kit 9、client_kit 18、host 79；分析均为 `--fatal-infos` 且无问题。host 79 项含内存账号、真实 SQLite 账号（重启保持、隔离、并发核销、refresh 单赢家、回滚）及真实 60 万轮 PBKDF2 测试。本记录仅证明该工作树，后续代码变更需重跑。

独立评审发现并修复：上下文权限集合被原始可变Set修改、卸载后已捕获上下文仍能使用。两项分别观察到回归测试RED，再实现并GREEN；评审复核未发现本次修复的新阻断。

## 尚未交付的模块

M01存储存在并行工单在途实现；未经合并与重验不记入当前分支。M03–M10、M12其余功能及M13全量验收均未在此分支实现。现有测试通过不代表手机/桌面可用，不代表完整产品交付。
