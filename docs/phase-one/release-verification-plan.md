# 第一期 · release 独立验收计划与基线复现

本文件由 release（独立验收/构建）维护，记录**基线提交**上的缺陷复现、工具链/构建演练，以及最终集成验收要执行的命令与判定口径。所有命令都在 release 自己的工作树执行，不改业务代码；不读写用户真实数据目录（`%LOCALAPPDATA%\Jingyu`），不使用真实 Provider 密钥。

- 基线：`38cd86c8f3a5c5e8b29a6d997bd02a2790400e96`（远端 main 合并树 `3478ae317ae296f252ac44e7aade2aa0ca96fc93`；worktree 分支 `agent/release/phase-one-e06b2209e759`）
- 环境：Windows 11 25H2（10.0.26200）、Flutter 3.50.0 / Dart 3.14.0、VS2022 BuildTools 17.14.39 + Windows SDK 10.0.26100.0、Android SDK 36 / JDK 21
- 工具：`tool/phase_one_release/`（独立复现脚本、包契约测试）、`tool/build_phase_one_package.ps1`（候选装配）
- 说明：本机 `powershell.exe` 是 Windows PowerShell 5.1，`pwsh` 不在 PATH；所有 `.ps1` 以 UTF-8 BOM + ASCII/中文混合保存（PS 5.1 读取无 BOM 的 UTF-8 会在中文处截断脚本，已实测踩到）。

## A. 用户报告缺陷的基线复现（RED/GREEN）

### A.1 方法与命令

`tool/phase_one_release/verify_autoreply.dart` 用**真实宿主进程**（`apps/host/bin/server.dart`，普通 `dart run` 启动）+ 真实 HTTP 完成整条链路，全部数据落在 `%TEMP%\jingyu-release-drill-*` 隔离目录：

1. 随机管理员口令 + `dart run bin/init_accounts.dart` 初始化临时库；
2. 启动宿主（只传 `JINGYU_DATA_DIR`/`JINGYU_BIND`/`JINGYU_PORT` 和必要系统环境）；
3. HTTP 登录 → 创建 AI → 注册档案 → 保存 Provider（`https://192.0.2.1/v1`）→ chat 绑定 → 完整预算（B2/chat 各 10000，其余 0）→ 初始化人格 → L0 → 打开主人私聊授权；
4. 发送一条复杂文本 `为什么这样？请解释原因。`（走 S2 模型路径）；
5. 轮询 `/owner-reply` 直到终态，读取 `/sync` 与 `/usage`；
6. GREEN 模式另在宿主重启后再次读回同一回复；最后 taskkill 整棵宿主进程树并删除临时目录。

复现命令（仓库根目录）：

```powershell
dart tool/phase_one_release/verify_autoreply.dart base-red      # 不设两个 worker 环境变量
dart tool/phase_one_release/verify_autoreply.dart base-explicit # 显式设置 JINGYU_MODEL_WORKER_EXECUTABLE + JINGYU_MODEL_WORKER_PATH
```

原始输出：[base-red.txt](release/base-red.txt)、[base-explicit.txt](release/base-explicit.txt)。

### A.2 RED：缺 worker 默认装配（真实宿主，未设置 worker 变量）

```text
MODE=base-red ISOLATED_DATA=true LAUNCH=dart run bin/server.dart
INITIALIZE exit=0
WORKER_EXECUTABLE=unset WORKER_PATH=unset
jingyu host 0.1.0 listening on 127.0.0.1:51699
PROVIDER_LOOPBACK http=403 error=forbidden fixtureCalls=0
HTTP_SETUP login=200 ai=200 profile=200 provider=200 binding=200 budget=200 persona=200 level=L0 consent=ownerTextOnly
AUTO_REPLY status=failed failure=model_unavailable syncRows=1 fixtureCalls=0 recordedTokens=0
BASE_RED_REPRODUCED
RED_DRILL_EXIT=0 SECONDS=76.8
```

判定：普通复杂私聊**已落库但不产生 AI 回复**；`owner-reply` 终态 `failed / model_unavailable`；同步只有 1 条本人消息；用量 0。与用户“发消息不自动回复”现象一致。

### A.3 GREEN：显式指定 worker（同一提交、同一脚本）

```text
MODE=base-explicit ISOLATED_DATA=true LAUNCH=dart run bin/server.dart
INITIALIZE exit=0
WORKER_EXECUTABLE=set WORKER_PATH=set
jingyu host 0.1.0 listening on 127.0.0.1:57562
PROVIDER_LOOPBACK http=403 error=forbidden fixtureCalls=0
HTTP_SETUP login=200 ai=200 profile=200 provider=200 binding=200 budget=200 persona=200 level=L0 consent=ownerTextOnly
AUTO_REPLY status=completed failure=- syncRows=2 fixtureCalls=1 recordedTokens=7
jingyu host 0.1.0 listening on 127.0.0.1:63253
BASE_EXPLICIT_GREEN canonical=true reopened=true fixtureCalls=1
GREEN_DRILL_EXIT=0 SECONDS=101.1
```

判定：同一条复杂私聊在配置两个 worker 变量后**收到 AI 回复并落库**（`syncRows=2`、`body.source=s2`、用量 7 tokens 记入账本）；宿主重启后仍读到同一消息。基线根因与“默认装配缺 worker”一致。

### A.4 复现边界（必须如实保留）

- 生产 `UrlGuard`（NFR-05）在设计上拒绝环回和私有地址：两次真实宿主都**拒绝保存** `http://127.0.0.1:<port>/v1` 的 Provider（HTTP 403 `forbidden`）。因此不能把本地 OpenAI 兼容服务直接填给真实宿主。
- 为在**不修改生产防护**的前提下拿到“真实宿主 + 真实 worker 子进程 + 合成服务”的链路证据，GREEN 用例使用 release 测试专用 fixture worker：它只把固定的 `https://192.0.2.1/v1/chat/completions` 请求转发到本机合成服务，并只接受 `Bearer fixture-*` 合成密钥。它**不是**打包产物、不能被生产装配选中，也不改变出厂 worker 的 URL 策略。
- 同时脚本在真实宿主中验证了 `127.0.0.1` Provider 被 403 拒绝、且合成服务 0 次被调用——即防护未被绕过。
- 本基线复现**没有**使用任何真实外部 Provider；真实模型调用仍需用户自己的 Provider 与额度（最终验收同样不跑真实密钥）。

## B. 工具链与构建演练（基线提交）

### B.1 依赖解析

| 包 | 命令 | 结果 | 耗时 |
| --- | --- | --- | --- |
| packages/jingyu_core | `dart pub get` | 退出 0（在线成功，未用 offline 回退） | 11.1s |
| packages/jingyu_protocol | `dart pub get` | 退出 0 | 8.4s |
| packages/jingyu_host_kit | `dart pub get` | 退出 0 | 9.2s |
| packages/jingyu_client_kit | `dart pub get` | 退出 0 | 13.2s |
| apps/host | `dart pub get` | 退出 0 | 11.8s |
| apps/client_flutter | `flutter pub get` | 退出 0 | 16.6s |

### B.2 Android debug APK

```text
COMMAND=flutter build apk --debug
√ Built build\app\outputs\flutter-apk\app-debug.apk
APK_BUILD_EXIT=0 SECONDS=515.9
APK=...\apps\client_flutter\build\app\outputs\flutter-apk\app-debug.apk BYTES=159418256 SHA256=6F1F420B052007BAD73683355047EDA2335FD0FD5EF8A5C35505475EF4438537
```

首次运行包含 Gradle 依赖下载（约 8.6 分钟），成功；APK 为 debug、未签名发布。

### B.3 Windows release（长路径问题与修复）

- 第一次（`wt-release` 原始长路径）：`flutter build windows --release` 退出 1（31.6s），`CMake Error at CMakeLists.txt:3: No CMAKE_CXX_COMPILER could be found`。证据 `build/windows/x64/CMakeFiles/CMakeConfigureLog.yaml`：cl 已编译，link 前 MSBuild 报 `MSB6003`/`DirectoryNotFoundException`，完整 `CompilerIdCXX.tlog` 路径超过 260 字符（VS2022 BuildTools、MSVC、CMake 均已安装；`flutter doctor -v` 的 Visual Studio 项为 ✓）。
- 在 `R:` 短盘符重试时，因为 `build/windows` 里残留上一次失败配置的 `CMakeCache.txt`，`cmake_install.cmake` 仍硬编码安装前缀 `C:/Program Files/client_flutter`，install 阶段 MSB3073 失败（编译本身成功）。
- 修复动作：通过 `R:` 映射用 `rd /s /q` 删除整个 `build/`（长路径本身会让 `Remove-Item` 失败），再在同一短路径下重跑：

```text
BUILD_REMOVED=True
Building Windows application... 359.6s
√ Built build\windows\x64\runner\Release\client_flutter.exe
WINDOWS_BUILD_SHORT2_EXIT=0 SECONDS=369.2
WINDOWS_EXE_BYTES=190464 SHA256=F6E661D3E40912419D438F32D033F29B29A733728122DF4C34CBBECAF94A52FF
```

产物：`client_flutter.exe`、`flutter_windows.dll`、`data/app.so`、`data/icudtl.dat`、`data/flutter_assets/*`。完整命令日志：[windows-build-short.txt](release/windows-build-short.txt)。

- 结论/约束：最终候选包**必须从干净的真实短路径工作树构建**（如 `C:\jyr2`），不要复用带长路径/旧 cache 的 `build/windows`；`R:` 映射只是本次演练手段。
- `flutter doctor -v`：Visual Studio（VS2022 BuildTools 17.14.39 + Windows SDK 10.0.26100.0）✓、Android toolchain ✓、Windows 桌面设备 ✓；Chrome 缺失与本票无关；`maven.google.com` 探测超时属于网络抖动（APK 构建仍成功）。

### B.4 基线全量 Dart 检查

`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool/check.ps1` 对 5 个 Dart 包执行 analyze/test。最终验收以候选树的完整命令结果为准，不使用运行中的基线日志作为通过证据。

## C. 候选包装配契约（工具已就绪，集成后装配）

### C.1 `tool/build_phase_one_package.ps1`

只装配**已构建产物**，不构建、不启动宿主、不接触任何用户数据或旧交付目录；输出目录必须是现有 staging 父目录下的新 `jingyu-phase-one-<shortsha>`，已存在则拒绝覆盖。输入全部显式：

- `-SourceRoot`/`-Commit`：必须与 `git rev-parse HEAD` 完全一致（40 位）；
- `-WindowsBundleDir`：含 `client_flutter.exe`、`flutter_windows.dll`、`data/app.so`、`data/icudtl.dat`、`data/flutter_assets/AssetManifest.bin`；遇到链接/敏感文件名（如 `.env`、`*.sqlite`、`*.key`）拒绝；
- `-HostSourceDir`：**干净宿主源码快照**（由 `git archive` 解包）：必须含 host 入口/根 `tool/init_host.ps1`/docs/各 package pubspec；拒绝 `.git`、`.dart_tool`、`build`、`dist`、`node_modules` 及敏感文件；
- `-LauncherPath`：候选包启动脚本（默认使用包内 `start-host.ps1`）；
- `-VerificationNotePath`：最终 `VERIFICATION.md`（同时嵌入 README）；
- staging 前校验输出路径不在用户数据目录、不经过 reparse point；先写临时目录、生成 `SHA256SUMS`（覆盖除清单自身外所有文件，含 Windows 树、ZIP 与 `host/`）后再原子 `Move` 为正式目录。

### C.2 `tool/phase_one_release/start-host.ps1`（包内启动脚本）

最小、可测试的包装脚本（沿用上一交付包已验证的启动逻辑，改为**包内相对绑定**）：

- `-RepoRoot` 缺省 = `$PSScriptRoot\host`（包内快照），显式参数可覆盖；不写死 `C:\jy8rc-e18`。
- 数据目录缺省沿用 `%LOCALAPPDATA%\Jingyu\host-data`（`-DataDir` 或 `JINGYU_DATA_DIR` 可覆盖）；要求目录已初始化（`host.sqlite` 存在），不建库、不覆盖。
- 监听缺省 `127.0.0.1:8787`（`-BindAddress`/`-Port` 或环境变量可覆盖）。
- 默认不设置 worker 环境变量，由源码入口选取当前 Dart SDK 和配套的 `bin/http_worker.dart`。如明确覆盖，`JINGYU_MODEL_WORKER_EXECUTABLE` 与 `JINGYU_MODEL_WORKER_PATH` 必须成对指向现有文件的绝对路径；不会混用默认值。首次运行优先使用缓存，必要时联网解析依赖。
- `-CheckOnly`：只解析/校验路径与配置并打印 `CHECK_OK ...`，不启动宿主（用于契约测试和用户预检）。

### C.3 `tool/phase_one_release/verify_package.ps1`（只读包校验）

用 `SHA256SUMS` 覆盖性校验（清单外文件也报错）+ 流式打开 Windows ZIP 逐条与 `windows/` 文件比对 SHA-256（不落地解压），并检查必需布局项；用于交付前/交付后独立校验。

### C.4 `tool/phase_one_release/README.template.md`

从用户视角写实际动作与边界：包内文件、校验命令、**用包内 `host/` 首次初始化或沿用既有数据目录启动**（不修改/不依赖旧 `C:\jy8rc-e18`）、Windows/Android 登录、人格导入的**实际按钮名**（导入人格文件/粘贴人格 JSON/初始化人格/保存人格修改）、Provider/聊天绑定/预算的**实际字段与约束**（分层与能力两组都必须填齐，各自合计不得超过每日上限；示例 10000 日额度、B1=2000/B2=8000/chatFast=2000/chat=8000）、授权私聊步骤、安全隐私禁止项、已知限制；功能范围与实测结果由最终 `VERIFICATION.md` 嵌入（未列为“已验收”的能力一律不作为本包承诺）。

### C.5 `tool/phase_one_release/test_package_contract.ps1`（装配契约测试）

全隔离（临时目录 + 合成产物 + fixture git 仓库）验证：布局/清单覆盖、README 占位符与验证内容、ZIP 内容与目录一致、`start-host.ps1 -CheckOnly` 的绑定/数据目录/错误路径、拒绝覆盖、HEAD 不一致、含 `.git` 或 `.dart_tool` 的快照、缺执行文件等。运行命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool/phase_one_release/test_package_contract.ps1
```

（结果见 [package-contract.txt](release/package-contract.txt)：**PACKAGE_CONTRACT_PASSED（日志记录 34 项检查通过）**；最终状态在 `docs/phase-one/final-verification.md` 汇总。）

## D. 集成后最终验收步骤（Phase 2，待 Lead 提供集成 commit/工作树）

1. 在干净的真实短路径工作树（如 `C:\jyr2`，detached 到集成 commit）重新 `dart pub get`/`flutter pub get`；
2. 从该树运行 `tool/check.ps1` 至 `ALL CHECKS PASSED`，记录 5 包 analyze/test 输出；
3. `flutter analyze` + 全量 `flutter test`（记录通过/跳过数）；
4. 从干净树构建 Windows release 与 Android debug APK（记录命令、耗时、产物大小/SHA-256）；
5. 用同一 `verify_autoreply.dart` 在集成树重跑：默认装配（无 worker 环境变量）的启动事实证据 + 显式 worker 的合成回环 E2E（SYNTHETIC fixture；不含真实外部调用），并记录 `owner-reply`/sync/usage/重启读回；
6. 用 `git archive <integration-sha>` 生成 `host/` 快照，`tool/build_phase_one_package.ps1` 装配候选包 → `verify_package.ps1`；SHA256SUMS 全量核验；
7. 按其他 area 的 `docs/phase-one/*.md` 可行性复跑记忆/主动/备份恢复演练（不可运行项如实记“未验证/受限”）；
8. 对最终集成 diff 做安全/隐私/回归审查（密钥、路径穿越、鉴权绕过、用户数据泄露、越权路由、依赖变化）；
9. 写 `docs/phase-one/final-verification.md`（命令、原始输出摘要、失败/跳过项、诚实限制），并报告 Lead。

## E. 风险与已知限制

- 生产 `UrlGuard` 拒绝环回/私有 Provider，本地合成 OpenAI 服务只能经测试专用 fixture worker 参与验收；真实外部 Provider 调用**不在**本票自动化验收范围，需用户自备。
- 首轮 Android Gradle 下载耗时约 8.6 分钟；离线环境需预置 Gradle/pub 缓存。
- Windows 构建对所在路径长度敏感（VS BuildTools 的 `MSBuild`/`cmake` 中间文件）；最终必须短路径干净构建。
- 邀请收件箱和聊天导出保留现有能力；系统新消息通知、记忆、主动联系和生产加密备份恢复未实现。