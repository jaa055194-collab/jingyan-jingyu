# 本人 AI 私聊 · 规则问候

这是 FR-42–45/48 的一个窄切片：主人可**单独许可**当前自己的 AI 在既有本人私聊中定期送来固定文本 `【规则问候】你好，愿你今天顺利。`，默认关闭。没有模型调用或虚构日常活动，不读取对话、记忆、人格或其他人的数据；不收费、不写入模型用量。复用普通文字和同步，但不经旧发送/回复/定时队列，旧 `ownerTextOnly` 和记忆授权都不改变。

## 主人设置

两个路由均为 `GET`（无查询参数/正文）和精确字段 `PUT`，当前人类账号及 bearer 在同一设置事务复核：

- `/api/v1/ai-profiles/{aiId}/owner-rule-greeting` 的 GET/PUT 响应：`{revision:int, enabled:bool, localMinute:int, offsetMinutes:int|null, quietStartMinute:int, quietEndMinute:int, globalBlocked:bool, globalRevision:int, socialLevel:string|null, chatRevision:int|null, budgetReady:bool, lastSentAt:string|null}`。`aiId` 是 canonical profile ID。未配置的排程默认每日 09:00、静默 23:00–08:00；没有 UTC 偏移或任何授权。`lastSentAt` 是实际本地规则发出时间的 UTC ISO 字符串；预算就绪不等于会送达。
- 该地址的 PUT：`{expectedRevision:int, enabled:bool, localMinute:int, offsetMinutes:int|null, quietStartMinute:int, quietEndMinute:int, expectedChatRevision:int|null, expectedGlobalRevision:int|null}`。分钟范围 `0..1439`，静默起止必须不同，起点含/终点不含，跨午夜支持；偏移 `-840..840` 分。不猜宿主时区、夏令时或旅行时区变化；用户修改固定 UTC 偏移后需重新保存审核后的设置。开启至少需要固定偏移、L3/L4、当前有效且未拉黑的本人私聊、未全局关闭和 B3 预算许可，两项 reviewed revision 与当前值匹配。关闭时两项为 `null`，无需私聊或预算仍可关闭。
- `/api/v1/accounts/me/owner-rule-greetings` 的 GET/PUT 响应 `{revision:int, blocked:bool}`，默认 `{revision:0, blocked:false}`；PUT `{expectedRevision:int, blocked:bool}`。开启全局停止会撤销该主人的所有现有规则问候。解除停止不给任何 AI 新许可；每个 AI 必须重新启用。全局版本同时阻断在关/开之前准备的 per-AI 请求，即使当时没有 per-AI 行。
- 成功 PUT 仅推进其设置 `revision` +1，不立即发送。读取默认无新行。`401` 凭证失效，`404` 非本人/非当前有效 AI，`400` 字段、类型或范围无效，`409` 状态过期或不满足开启门槛。不得把 409 当作自动重试或自动升社交等级的理由。

## 排程、触达和回放边界

[迁移 605](../../apps/host/lib/src/ai/life/owner_rule_greeting_migration.dart) 只增加独立设置、全局停止和收件人+AI 发送水位，不回填任何许可。当前配对、owner 权限、原私聊授权版本和 L3+ 丢失会关闭原规则许可；同一配对/权限还原不会复活，Provider 变动不是规则问候的输入。B3 只读关卡在提交文本的事务中从现有计量读取：无有效预算、任何能力遗留未知用量或日/文本/B3 上限耗尽即静默；不创建请求、记账、重试或残留假的零用量。使用模型预算既有的日界偏移，不替换成问候排程偏移。

[排程器](../../apps/host/lib/src/ai/life/owner_rule_greeting.dart) 区分名义本地触发分钟和落在静默窗内时的顺延结果。只安排严格晚于保存时刻的首个**名义**槽。宿主启动、时钟倒退或相邻观察超过 30 秒重新建立连续观察；名义槽必须在该连续观察开始后，实际到点必须由当前轮跨过，即使是在跨午夜静默结束时。默认模块每 10 秒观察、每轮有界；关机、离线、错过、预算不够、写失败都不补发。解释的是本宿主实际观察到的时钟：不推断未观察的 DST、旅行、暂停或把时钟调整掩盖掉的外部变化。

每个到点槽先独立、持久推进 cursor，再在另一短 SQLite 事务最后复核相同许可版本/槽、canonical pair、L3+、全局停止、静默、用户日及预算日。实际发送为原子闸门：普通文字 append、按收件人和 canonical AI 账号的本地日水位（额外 ≥24 小时防调时重发）和无正文审计必须共同提交；写失败或重启都不重放已经消耗的槽。事务内检查最终消息时间，schedule/budget 日变更不跨日落库。

## 隔离验证

宿主目录执行 `dart pub get --offline`、`dart analyze --fatal-infos`、`dart test --reporter expanded test/owner_rule_greeting_host_test.dart test/host_models_assembly_test.dart test/usage_meter_test.dart`。[测试](../../apps/host/test/owner_rule_greeting_host_test.dart)使用真实 SQLite/default host、合成账号与 FakeClock，验证正常 sync、独立授权、全局撤销、静默/重启/时钟倒退、预算及发送事务回滚。未启用真实账号或模型，不是原生客户端或通用主动社交验收。
