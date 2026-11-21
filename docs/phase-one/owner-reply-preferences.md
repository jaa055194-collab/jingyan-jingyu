# 本人 AI 私聊：独立的回复偏好授权（宿主切片）

[客户端设置](owner-reply-preferences-ui.md)只允许主人显式保存两类非敏感偏好，并独立授权同一本人私聊将这些偏好交给当前配置的模型。它不是通用记忆或主动联系。现有 [`ownerTextOnly`](../owner-ai-direct-consent.md) 的语义和六字段 HTTP 响应保持不变；没有额外授权时，普通 B2 的两个消息段、S1 规则路径和其他会话都不变。开启授权本身不打开私聊、不发消息、不启动推理；只有主人之后主动发送、且命中现有 B2 路径的单条文本才可能使用偏好。

## 独立协议

`GET /api/v1/ai-profiles/{aiId}/owner-reply-preferences`：无查询参数或请求体。由当前认证的账号和设备确定主人；`aiId` 是 canonical profile ID，不是 AI 账号 ID。当前人类主人以外无读取权限，admin 不构成委托。未保存时读取不创建偏好行：

```json
{"revision":0,"enabled":false,"length":null,"format":null,"target":null}
```

已有有效的本人私聊与启用的 `chat` 绑定时，`target` 为 `{ "providerId": "…", "model": "…", "origin": "https://…", "token": "…" }`，即使偏好开关关闭也可显示。`origin` 仅为供确认的 scheme/host/port；不回传 provider 路径、访问密钥或密钥摘要。`token` 是不透明的配置代标记，不是访问凭证；有可审核目标不代表实际模型运行时、提供商或预算就绪。

`PUT` 同一地址，严格使用以下五个字段（均必传）：

```json
{"expectedRevision":0,"enabled":true,"length":"brief","format":"bullets","expectedTargetToken":"…"}
```

- `length`：`null`、`brief`、`detailed`；`format`：`null`、`paragraphs`、`bullets`。不接受自由文本或附加字段。
- 开启时至少有一项偏好，并要提交刚刚向主人展示的目标 token；成功返回 GET 形状且目标与所审查的一致。关闭时 token 必须为 `null`，可保留偏好；两项均为 `null` 且关闭即清空保存的选项，当前无目标也可以关闭或清空。
- 每个成功 PUT 将独立 revision 加一。`400` 参数无效，`401` 凭证无效，`404` 不拥有当前有效 AI，`409` 配置版本或目标变化/缺少当前目标。冲突或响应未知时刷新状态，不自动重复提交。真实已认证 bearer 的摘要、设备、账号及有效期与读取/CAS 写入在同一个 SQLite 事务复核。

## 采集、撤销及调用边界

- [迁移 604](../../apps/host/lib/src/ai/memory/owner_reply_preferences_migration.dart) 没有回填授权，也无需迁移旧客户端字段。每个 owner/profile 仅保存一份固定选项，AES-GCM 加密并绑定用途、主人和 profile；审计只存动作、操作者、目标、状态及版本，不存选项、token、提供商 URL/凭据或聊天正文。配置与审计同事务提交。清除移除当前活动选项，不承诺抹去历史备份、已发送的内容或旧副本。
- 配对/身份、基础私聊许可和实际模型绑定均须有效。涉及完整 base URL（包括不披露的路径）、模型、凭据、启用与能力的变更会轮换绑定代标记并撤销现有偏好授权；基础私聊撤销/重新打开、身份调整或失效、拉黑沿原有基础许可的持久撤销触点一同失效。还原原配置不自动重新启用。token 的输入是独立随机代标记及配对/基础授权版本，不含原始密钥、密文或掩码。
- 只在既有 owner 单条文本接受事务中记录偏好版本和目标标记（元数据，无偏好正文）。无标记的旧消息、重放或旧选择版本不会获得新许可；不补签也不重新尝试。偏好如有使用，只有单个有界且带明确标签的 user-role 数据段，当前单条文本仍单列。不搜索聊天、群聊、附件、第三人或 T2 数据，不改变人格。提示仍由模型解释，不保证模型严格遵循格式。
- 既有 B2 预算 admission、出站安全校验、不自动重试及真实 usage 结算不变；增加的输入可能计入现有调用的 token 开销。授权线性化点是[网关](../../apps/host/lib/src/models/model_gateway.dart)在 guard/预算 await 完成后，在短 SQLite 事务中最后复查 source、基础/独立许可及全目标，并在同一个事务中**启动**已钉住的 adapter（不在事务中 await 供应商）。如果未交接，清除仅属于本次新建的、全 token 字段未结算的 pending usage 行（指定 owner、AI、request、layer、capability、day/offset），不是记录虚假的零用量。运行时不会重读其他传输目标或自动跟随重定向。
- 交接包括交给 worker 启动，不能承诺撤回已交接或已传输的请求。若之后状态改变，[观察者](../../apps/host/lib/src/brain/owner_ai_direct_reply_observer.dart)会在发布回复的同一写事务中再次复查并丢弃过期结果；按既有规则处理真实/未知用量。本切片不声称改变 DNS/TLS/供应商留存，也不承诺在途模型用量绝不超过上限。

## 可复跑的宿主证据

在隔离 Windows worktree 的宿主目录执行 `dart pub get --offline`、`dart analyze --fatal-infos`，随后 `dart test --reporter expanded`（不设置外部 provider 或恢复演练的 opt-in 环境变量）。本宿主实现分析无问题，全量测试 1588 项通过、16 项跳过（退出码 0；该次全量在最后三项纯测试补充之前）。最终 `dart test --reporter expanded test/owner_reply_preferences_host_test.dart test/host_models_assembly_test.dart` 为 26 项通过（退出码 0）。

[宿主偏好测试](../../apps/host/test/owner_reply_preferences_host_test.dart) 使用合成凭据、SQLite、真实宿主装配及不联网的合成子进程；它覆盖身份隔离、失效凭证的同事务拒绝、严格 CAS、密文与无正文审计、重启、收到确认前已接收的消息、B2 用户角色、S1 未动、guard/预算期间变更、未知用量阻断和发布前撤销。只是宿主与合成边界验收；未使用实际用户设置、真实外部模型、原生客户端或设备。完整 FR-49/50 的聊天记忆/召回和 FR-42–48 的主动消息仍不在此切片。
