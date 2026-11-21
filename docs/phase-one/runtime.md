# 第一期 · 默认装配修复与自动回复运行时证据（runtime）

本文件记录用户问题「发消息不自动回复」的根因、修复、验证命令与真实证据。
写入面：`apps/host/lib/src/config.dart`、`apps/host/bin/server.dart`、
`apps/host/test/host_model_worker_defaults_test.dart`、本文档，以及
`docs/host-setup.md` 的一处启动说明。

## 1. 根因（已核实）

`HostConfig.fromEnvironment` 只读取两个显式环境变量
`JINGYU_MODEL_WORKER_EXECUTABLE` / `JINGYU_MODEL_WORKER_PATH`；
`defaultModules` 只有在两者同时存在时才装配 `ModelRuntime`。因此从仓库按
`docs/host-setup.md` 的日常启动命令 `dart run bin/server.dart` 启动时，
模型 runtime 为空：复杂私聊消息照常入库，但
`OwnerAiDirectReplyObserver` 走 S2 分支时 `chat == null`，回复尝试被终结为
`failed / model_unavailable`，客户端表现为「发消息不自动回复」。

基线 `38cd86c` 上独立验收（release 复现，见 §4）：
`WORKER_EXECUTABLE=unset WORKER_PATH=unset` →
`AUTO_REPLY status=failed failure=model_unavailable syncRows=1 fixtureCalls=0 recordedTokens=0`。

## 2. 修复（只附加、不改既有低层调用者）

`apps/host/lib/src/config.dart` 新增 `HostConfig.forServer` 工厂，仅由
`bin/server.dart`（文档化启动入口）调用：

- 显式环境变量成对出现时原样返回，优先级最高，不与默认值混合；
- 两者都缺省时，用 `Platform.script` 推导：启动脚本必须是
  `.../bin/server.dart`，worker 取同目录 `http_worker.dart` 的绝对路径，
  可执行文件取 `Platform.resolvedExecutable`（当前 Dart SDK）；
- 推导只看启动脚本位置，**与当前工作目录无关**：在 `apps/host` 执行
  `dart run bin/server.dart` 或在仓库根执行 `dart run apps/host/bin/server.dart`
  都会选中同一个 `apps/host/bin/http_worker.dart`；
- 不可用（worker 文件不存在、SDK 可执行文件不存在、非源码入口）时失败关闭：
  runtime 保持为空，`bin/server.dart` 向 stderr 打印
  `Model runtime disabled: <原因>`，账号/消息等非模型功能照常启动；
- 任何路径都不来自 HTTP 请求；HTTP 路由层未新增任何 worker/URL 相关字段。

`bin/server.dart` 启动成功后打印一行
`Model runtime registered (worker: <绝对路径>)`，便于用户与验收确认默认装配
已生效（此前无此行）。`buildHost` / `defaultModules` 的显式路径语义、以及
`init_accounts.dart` 等低层调用者均未改动。

安全边界不变：`apps/host/bin/http_worker.dart` 与
`lib/src/security/guarded_http.dart`、`url_guard.dart`、`process_http.dart`
相对基线零 diff（§3 最后一条命令），生产 worker 仍拒绝环回/私有地址出站；
没有新增任何生产出站豁免或 worker 启动参数。

## 3. 验证命令与真实结果（2026-11-21，Windows，本工作树）

```powershell
cd apps/host
dart analyze --fatal-infos
# 结果：No issues found!（exit 0）

dart test test/host_model_worker_defaults_test.dart -r expanded
# 结果：
# 00:06 +6: All tests passed!
# PACKAGED_WORKER runtime=registered launch=confirmed loopback=forbidden
```

该测试覆盖（第 3–6 条在本修复实现前均为失败，修复后通过；第 1–2 条固化
原有显式 env 语义）：

1. 显式成对 env 覆盖默认推导；
2. 只给一半 env 时不混用默认值，仍按旧语义在 `defaultModules` 报参数错误；
3. 默认路径来自 `Platform.script` 而非 cwd（临时目录中放 `bin/server.dart` +
   `bin/http_worker.dart`，cwd 不同仍解析到同一 worker）；
4. 仓库布局下默认路径等于
   `.../apps/host/bin/http_worker.dart`，`buildHost` 注册 `ModelRuntime`，
   并通过 `ModelsModule.providerDiscoveryRequest` 真实启动子进程 worker；
   对 `http://127.0.0.1/v1/models` 得到结构化 `forbidden`——证明生产 guard
   仍拦截环回且实际 worker 已启动（无任何网络 I/O）；
5. 默认 worker 文件缺失：打印含 `http_worker.dart` 的原因，runtime 不注册；
6. 默认 SDK 可执行文件缺失：打印原因，runtime 不注册。

真实宿主进程启动证据（**不设置两个 model worker 变量**，隔离临时数据目录）：

```powershell
# 在 apps/host 下
$env:JINGYU_DATA_DIR = '<temp>'; $env:JINGYU_BIND = '127.0.0.1'; $env:JINGYU_PORT = '18993'
dart run bin/server.dart
# stdout：
# Model runtime registered (worker: C:\...\wt-runtime\apps\host\bin\http_worker.dart)
# jingyu host 0.1.0 listening on 127.0.0.1:18993
# GET /api/v1/health -> status=ok

# 在仓库根下
dart run apps/host/bin/server.dart
# stdout：同样打印
# Model runtime registered (worker: ...\apps\host\bin\http_worker.dart)
# jingyu host 0.1.0 listening on 127.0.0.1:18993
# GET /api/v1/health -> status=ok
```

安全文件零 diff 校验：

```powershell
git diff --exit-code 38cd86c -- apps/host/bin/http_worker.dart `
  apps/host/lib/src/security/guarded_http.dart `
  apps/host/lib/src/security/url_guard.dart `
  apps/host/lib/src/security/process_http.dart
# 结果：exit 0（无输出）
```

## 4. 独立验收（release，基线 `38cd86c`，合成服务、无真实密钥）

以下证据由 release 验收方在**基线代码**上、从仓库根执行
`dart tool/phase_one_release/verify_autoreply.dart <mode>` 产生，
见 [缺少 worker 的基线日志](release/base-red.txt)及[显式合成 worker 的基线日志](release/base-explicit.txt)：

```text
# base-red.txt —— 不设置两个 worker 变量（用户实际启动方式）
MODE=base-red ISOLATED_DATA=true LAUNCH=dart run bin/server.dart
INITIALIZE exit=0
WORKER_EXECUTABLE=unset WORKER_PATH=unset
jingyu host 0.1.0 listening on 127.0.0.1:51699
PROVIDER_LOOPBACK http=403 error=forbidden fixtureCalls=0
HTTP_SETUP login=200 ai=200 profile=200 provider=200 binding=200 budget=200 persona=200 level=L0 consent=ownerTextOnly
AUTO_REPLY status=failed failure=model_unavailable syncRows=1 fixtureCalls=0 recordedTokens=0
BASE_RED_REPRODUCED
```

```text
# base-explicit.txt —— 显式设置两个 worker 变量（修复前的手工绕行方式）
MODE=base-explicit ISOLATED_DATA=true LAUNCH=dart run bin/server.dart
INITIALIZE exit=0
WORKER_EXECUTABLE=set WORKER_PATH=set
jingyu host 0.1.0 listening on 127.0.0.1:57562
PROVIDER_LOOPBACK http=403 error=forbidden fixtureCalls=0
HTTP_SETUP login=200 ai=200 profile=200 provider=200 binding=200 budget=200 persona=200 level=L0 consent=ownerTextOnly
AUTO_REPLY status=completed failure=- syncRows=2 fixtureCalls=1 recordedTokens=7
jingyu host 0.1.0 listening on 127.0.0.1:63253
BASE_EXPLICIT_GREEN canonical=true reopened=true fixtureCalls=1
```

解释与边界：

- `base-red` 复现用户症状：普通私聊已入库（`syncRows=1`），无 AI 回复，
  回复尝试终态 `failed / model_unavailable`，usage 结算为 0，合成 provider
  调用次数 0。
- `base-explicit` 证明「宿主 + 真实子进程 worker + 规范化持久化 + 重启后仍在」
  这条链路可用：`syncRows=2`、回复走 `s2`、用量结算 7 tokens、
  `canonical=true reopened=true`。它使用**显式 env** 指向 SDK + 确定性
  合成 fixture worker（该 fixture 自身访问 release 拥有的环回合成
  OpenAI 服务，生产 worker 的 URL 策略未改）。
- 综合结论（诚实口径）：`base-explicit` 本身不证明默认启动；默认启动的
  「自动选中同一组可信路径并注册 runtime」由 §3 的启动日志与单测证明。
  两半合起来覆盖用户路径：无需手工 env 的 `dart run bin/server.dart`
  现在会装配模型 runtime，指向打包的 `bin/http_worker.dart`。

## 5. 已知限制

- 未用真实外部模型服务验证（本环境无凭据、无公网直连要求）；真实 provider
  的 HTTPS/DNS 链路不在本票证据内。
- 生产 URL guard 按 NFR-05 拒绝环回/私有地址，因此「默认启动 + 环回合成
  provider」不能在一条真实宿主链路里同时完成；默认启动证明与合成回复证明
  分别由 §3 与 §4 给出，未新增任何测试专用出站豁免或生产 worker 参数。
- 本修复只覆盖文档化源码启动入口 `bin/server.dart`；`buildHost` /
  `init_accounts.dart` 等低层调用者仍按显式 env 装配（行为未变）。打包发布
  的 `start-host.ps1` 若显式设置 env，仍然优先生效。
- 未覆盖客户端 UI；客户端看到的效果依赖宿主返回的 `s2` 消息，已由 §4 的
  HTTP 读回证明。