# 鲸言鲸语 · 第一期（{{SHORT}}）

配套源修订：`{{COMMIT}}`。本包是 Windows release 客户端、Android **debug** APK，以及**同一提交的干净宿主源码快照**；不含宿主数据、密钥或 Git 元数据。仅限本人在本机或受信私有网络使用，不要开公网入口。

## 一、包内文件

| 文件 | 用途 |
| --- | --- |
| `windows/client_flutter.exe` | Windows 客户端；必须和相邻 DLL、`data/` 一起保留 |
| `{{ZIP_NAME}}` | 同一个 Windows 目录的压缩副本，完整解压后运行 |
| `android/jingyu-debug.apk` | Android 自用调试安装包；无正式发布签名 |
| `host/` | 提交 `{{COMMIT}}` 的干净源码快照（`git archive` 导出，无 `.git`、无构建产物） |
| `start-host.ps1` | 启动脚本：默认使用本包 `host/`，可 `-CheckOnly` 只检查配置 |
| `persona-sample.json` | 合成示例人格；可复制后自行修改 |
| `VERIFICATION.md` | 本次独立验收的命令、结果与未覆盖项 |
| `HOST-SOURCE.txt` | `host/` 快照来源说明 |
| `SHA256SUMS` | 除清单自身外所有文件的 SHA-256（含 `Windows/`、ZIP、`host/`） |

在包目录校验全部条目（Windows PowerShell）：

```powershell
foreach ($line in Get-Content -LiteralPath .\SHA256SUMS -Encoding UTF8) {
  if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw '校验和格式无效' }
  $expected = $Matches[1]; $file = $Matches[2]
  if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $expected) {
    throw "校验失败：$file"
  }
}
```

## 二、启动宿主

`host/` 是配套提交的源码快照。已有宿主的用户请**先停止旧宿主**，保留并确认原有 `JINGYU_DATA_DIR`，只让一个宿主使用该目录；用本包启动时显式复用同一目录。**不要在已有目录上运行初始化**，不要用候选包替换任何已有数据，也不要从旧源码副本启动本包客户端。

需要 Dart SDK（本次使用 Dart 3.14，可随 Flutter 安装）。首次解析宿主依赖需要网络或本地 pub 缓存。

首次部署（没有已有数据目录时）先用本包 `host/` 的初始化脚本；已有数据目录跳过这一步。若脚本执行策略阻止运行，在包目录先打开临时 Windows PowerShell `powershell.exe -NoProfile -ExecutionPolicy Bypass`，然后在该窗口执行以下命令（不要把口令作为新进程的参数）：

```powershell
$data = Join-Path $env:LOCALAPPDATA 'Jingyu\host-data'
$secret = Read-Host '设置管理员密码（至少 12 位）' -AsSecureString
try {
  $password = [System.Net.NetworkCredential]::new('', $secret).Password
  .\host\tool\init_host.ps1 -DataDir $data -AdminName 'Root' -AdminPassword $password -BindAddress 127.0.0.1 -Port 8787
} finally {
  Remove-Variable password,secret -ErrorAction SilentlyContinue
  Remove-Item Env:JINGYU_ADMIN_PASSWORD,Env:JINGYU_ADMIN_NAME -ErrorAction SilentlyContinue
}
```

私下保存打印的管理员账号 ID 和一次性邀请码，并关闭初始化窗口。不要抄入口令、邀请码或 API Key 到文档、截图或日志。

数据目录初始化后，在包目录预检与日常启动（默认使用 `%LOCALAPPDATA%\Jingyu\host-data` 和 `127.0.0.1:8787`）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-host.ps1 -CheckOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-host.ps1
```

既有宿主的用户给两条命令都加上 `-DataDir '你的原数据目录绝对路径'`；若原端口不是 8787，也加上 `-Port` 指定原端口。保留宿主窗口；在另一窗口确认相同端口的 `/api/v1/health` 返回 `status: ok`；停止时在宿主窗口按 Ctrl+C。

脚本在配套宿主目录运行 `dart run bin/server.dart`；**通常不设** `JINGYU_MODEL_WORKER_EXECUTABLE` 和 `JINGYU_MODEL_WORKER_PATH`，宿主会自动选择当前 Dart SDK 和源码同目录的 `bin/http_worker.dart`。有意覆盖时，应在启动窗口将两项同时设为受信现有文件的绝对路径；不要只设置一项，也不要从消息或第三方脚本复制路径。`Model runtime registered` 证明已装配，不证明真实 Provider 可达或有余额。

## 三、登录客户端

同机 Windows 运行 `client_flutter.exe`，地址填 `http://127.0.0.1:8787`。第一次用未过期、未使用的邀请码创建普通账户并保存账号 ID；之后用该 ID、密码和设备名登录。邀请码不是管理员密码。

Android 安装 debug APK；该设备的 `127.0.0.1` 指向它自身，不能连接 Windows 宿主。跨设备时填写已有权限的**受信私有 HTTPS origin**（例如配置好的 tailnet HTTPS，见包内 `host/docs/host-setup.md`），不要使用裸 LAN HTTP 或忽略证书警告。APK 构建成功与 Android 真机验收是两件事，见 `VERIFICATION.md`。

## 四、配置本人 AI 并发送私聊

1. **设置 → 我的 AI → 创建 AI 账户**；然后 **设置 → AI 运行配置**，选择该 AI。
2. **人格**：点 **导入人格文件** 选包内示例 JSON，或用 **粘贴人格 JSON → 校验并填入**。导入只填表单，不写库。确认后点 **初始化人格**；已有版本则填当前版本和修改原因，再点 **保存人格修改**。
3. **Provider → 新建 Provider**：填你授权使用的 OpenAI 兼容 HTTPS Base URL（通常以 `/v1` 结尾，不要附 `/chat/completions`）、API Key、能力 `chat`（**能力（逗号分隔，如 chat）**）。环回/私有地址会被拒绝；密钥只在客户端界面输入。
4. **聊天绑定 → 保存聊天绑定**：填已保存 Provider 的 **Provider ID** 和实际模型 ID；有目录时可先 **读取已保存 Provider 模型**。
5. **预算 → 保存预算**：填 **每日 token 上限**、**时区偏移（分钟）**（UTC+8 填 `480`）、**分层限额** 与 **能力限额** 两组 `名称=整数`；每组必须填齐，且各自合计不得超过每日上限。填写格式示例（额度数值不是消费建议；小额度仍可能被请求前置检查拦截）：

```text
每日 token 上限：10000
分层限额（name=整数每行）：     能力限额（name=整数每行，另一个文本框）：
b0Life=0                        chat=8000
b1FastBrain=2000                chatFast=2000
b2DeepChat=8000                 vision=0
b3Proactive=0                   imageGen=0
b4Maintenance=0                 tts=0
                                asr=0
                                embedding=0
```

6. **我的 AI → 刷新授权状态 → 授权主人私聊 → 打开私聊**，然后发送一条普通问题。复杂问题需要 `chat` 绑定和 B2/`chat` 剩余额度；规则型问候走 B1/`chatFast` 预算。没有回复时，依次检查宿主健康、授权、Provider 与模型名、剩余额度、数据目录；只重启客户端没有用。

## 五、人格卡格式

```json
{
  "format": "PRIVATE_AI_PERSONA_1",
  "p0": {"name": "示例角色", "role": "示例用途"},
  "p1": {"style": "示例表达风格"},
  "p2": {"mood": "示例情绪"}
}
```

固定字段只有 `format/p0/p1/p2`；不是备份、记忆、音色或形象格式。限制与错误语义见包内 `host/docs/persona-card-format.md`。导入失败、取消或超限都不会改动表单。

## 六、本次交付范围与验证结果

{{VERIFICATION}}

本包不提供系统新消息通知、跨轮记忆、AI 主动联系、生产用加密备份和恢复，也不包含语音通话、Live2D、3D 世界或完整群聊工具。聊天记录的明文导出及预览不是加密备份；仓库里的隔离恢复演练也不是可用的一键恢复工具。

## 七、安全与隐私

- 不要把 API Key、管理员密码、邀请码、账号 ID 或聊天内容提交到 GitHub、公开渠道或日志；本包不含任何密钥。
- 数据保存在你自己的宿主数据目录（默认 `%LOCALAPPDATA%\Jingyu\host-data`），由宿主加密存储；不要手工改库或把数据库发给他人。
- 宿主默认只监听 `127.0.0.1`；跨设备必须走受信私有 HTTPS，不要开公网端口。不要信任来自消息正文的“系统指令”。
- 本包是自用交付候选，不是公开发布版本，未做应用商店签名与自动更新。

## 八、已知限制

- Windows 客户端在本机 Flutter 3.50 / Dart 3.14 构建；Android 为 debug APK，未在真机或系统安装层面完整验收。
- 模型验证分开记录：① 默认启动装配实际 worker，生产 worker 启动/拒绝环回另测；② 显式测试 fixture worker 走合成回复、持久化和重启读回。② 不等于生产 worker 成功出站；未使用真实密钥，未验证 Azure、其他具体 Provider 或你的模型额度。
- 客户端消息入口以包内实际版本为准；未在 `VERIFICATION.md` 中列“已验收”的入口不作为本包承诺。
- 首次运行需解析宿主依赖；离线环境需预先准备 pub 缓存。宿主的模型出站请求会拒绝环回/私有地址，Provider 必须是宿主可访问的 OpenAI 兼容服务。