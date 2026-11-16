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
