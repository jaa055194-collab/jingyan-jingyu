# 真实模型联通与聊天验证

本文件说明如何用真实 OpenAI 兼容服务，对宿主的模型聊天链路做一次端到端联通验证。
真实密钥只在本机运行时通过环境变量注入，**绝不写进仓库**（NFR-06）；公开仓库中不得出现任何密钥。

## 验证覆盖的链路

`apps/host/test/live_model_chat_test.dart` 复用宿主真实装配，验证以下调用链：

```text
已保存人格 Persona
  -> ContextAssembler（有界上下文装箱）
  -> ModelRuntime（按 owner 预算/时区）
  -> ModelGateway（绑定解析、预算与用量）
  -> ProviderRegistry（解密取回 provider 凭据）
  -> UrlGuard（DNS 校验 + 固定地址）
  -> OpenAiCompatibleChatAdapter -> 真实 HTTPS provider
```

该测试默认被跳过：只有在设置了 `JINGYU_LIVE_BASE_URL` 和 `JINGYU_LIVE_API_KEY`
时才真正发起外部请求，因此离线 CI 仍是无密钥、无网络的。

## 本机运行

在 `apps/host` 目录下，只把密钥注入当前进程（示例，切勿提交）：

```powershell
$env:JINGYU_LIVE_BASE_URL = 'https://<your-openai-compatible-host>/v1'
$env:JINGYU_LIVE_API_KEY  = '<本机注入，禁止提交>'
$env:JINGYU_LIVE_MODEL    = 'auto'
dart test test/live_model_chat_test.dart -r expanded
```

- `JINGYU_LIVE_BASE_URL`：OpenAI 兼容基址；适配器会在其后拼接 `/chat/completions`。
  NewAPI 一类服务通常使用 `https://<host>/v1`。
- `JINGYU_LIVE_MODEL`：模型名，缺省 `auto`。
- 通过时输出形如：

  ```text
  LIVE_REPLY="1+1等于2。"
  LIVE_USAGE input=226 output=8 total=234
  00:09 +1: All tests passed!
  ```

测试只断言：调用返回 `Ok`、回复非空、`total = input + output`。它只打印归一化后的
回复与 token 用量，不打印密钥、请求头或上游原始报文。

说明：该测试对真实网络发起一次调用。宿主受控传输会把任何瞬时 DNS/连接/TLS 失败
归一化为 `modelUnavailable`，且要求 provider 返回整数 `usage` 并满足 `total = prompt + completion`；
因此个别 OpenAI 兼容实现或瞬时网络抖动可能判为不可用，重跑一次即可区分。

## 安全边界

- 密钥仅经环境变量注入，测试代码只在内存中使用，不落盘明文、不回显。
- `.gitignore` 已忽略 `.env`、`.env.*`、`secrets.local/`；不要把这些值写进任何跟踪文件、PR 描述或日志。
- 该验证只证明「单次真实对话经宿主链路可用」；它不代表已实现自动回复触发链、客户端 UI、
  流式、多轮记忆授权或完整 FR-57 验收。

## 默认宿主装配与真实本地 HTTP 监听

以下独立验收使用 `buildHost`、`serve` 和 `127.0.0.1` 的临时端口，不改宿主路由或 worker 安全策略。测试以临时 SQLite 播种合成账号、AI 与设备；后续配置、授权、单次消息发送、回复状态、历史和用量读取均走真实 HTTP 与 bearer 校验。读回使用新连接；关闭并重开同一数据库后再次核对。**不覆盖客户端 UI、口令登录或 `bin/server.dart` 入口。**

在 `apps/host` 目录运行离线验收（默认执行，不使用真实凭据、不会向公网发送请求）：

```powershell
Remove-Item Env:JINGYU_RUN_LIVE_LISTENER -ErrorAction SilentlyContinue
dart test --compiler source test/host_live_listener_test.dart -r expanded
```

离线用例走真实宿主和真实子进程 IPC，但子进程仅返回合成回复；它不验证打包 worker 成功出站。实时分支默认跳过。获授权之后，先安全地向本进程注入 `JINGYU_LIVE_BASE_URL`（HTTPS）和 `JINGYU_LIVE_API_KEY`（限本次运行，勿写脚本、历史或日志），然后仅跑一次实时用例：

```powershell
$env:JINGYU_RUN_LIVE_LISTENER = '1'
$env:JINGYU_LIVE_MODEL = 'auto'
try {
  dart test --compiler source test/host_live_listener_test.dart -r expanded --plain-name 'live: real host HTTP and packaged worker persist one auto reply'
} finally {
  Remove-Item Env:JINGYU_RUN_LIVE_LISTENER,Env:JINGYU_LIVE_MODEL,Env:JINGYU_LIVE_BASE_URL,Env:JINGYU_LIVE_API_KEY -ErrorAction SilentlyContinue
}
```

实时分支使用仓库的 `apps/host/bin/http_worker.dart`，提交一条合成消息，不自动重试。缺失或无效配置在显式启用后会失败，不会回退为合成成功。成功只打印回复长度、已结算 token 数和已重开标志。测试诊断不附带消息正文、HTTP 响应、凭据或上游报文。宿主按生产方式加密保存供应商凭据于临时 SQLite，测试结束后清理该临时目录。

**实测（2026-11-18，Windows，`32b5ad6` 加本节的监听器验收测试）**：一次真实 `auto` 调用通过；回复非空，HTTP 回复状态与历史指向同一条 `s2` 消息，已结算用量为 342 tokens。重开数据库并建立新连接后，再次通过 HTTP 读到相同回复和用量。该结果不代表口令登录、客户端 UI 或独立宿主进程的整个用户会话通过验收。
