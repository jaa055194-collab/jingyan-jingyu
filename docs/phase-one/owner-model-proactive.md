# 本人 AI 私聊 · 模型主动联系

这是 FR-42–45/48/58 的模型驱动切片：主人可**单独许可**当前自己的 AI 在既有本人私聊中、按固定排程调用模型（B3）发出简短主动问候，默认关闭。与规则问候不同，本功能会调用模型，但只使用一条短系统提示，不读取对话、记忆、人格或其他人的数据；预算耗尽、未知用量或模型失败一律静默，绝不冒充规则问候，也不伪造 token 结算。

## 主人设置

两个路由均为 `GET`（无查询参数/正文）和精确字段 `PUT`，当前人类账号及 bearer 在同一设置事务复核：

- `/api/v1/ai-profiles/{aiId}/owner-model-proactive` 的 GET/PUT 响应：`{revision:int, enabled:bool, localMinute:int, offsetMinutes:int|null, quietStartMinute:int, quietEndMinute:int, intervalMinutes:int, globalBlocked:bool, globalRevision:int, socialLevel:string|null, chatRevision:int|null, budgetReady:bool, lastSentAt:string|null}`。`aiId` 是 canonical profile ID。未配置的排程默认每日 09:00、静默 23:00–08:00、最短间隔 1440 分钟；没有 UTC 偏移或任何授权。`lastSentAt` 是实际送达时间的 UTC ISO 字符串；预算就绪不等于会送达。
- 该地址的 PUT：`{expectedRevision:int, enabled:bool, localMinute:int, offsetMinutes:int|null, quietStartMinute:int, quietEndMinute:int, intervalMinutes:int, expectedChatRevision:int|null, expectedGlobalRevision:int|null}`。分钟范围 `0..1439`，静默起止必须不同，起点含/终点不含，跨午夜支持；偏移 `-840..840` 分；`intervalMinutes` 60..10080（默认 1440）。不猜宿主时区、夏令时或旅行时区变化。开启至少需要固定偏移、L3/L4、当前有效且未拉黑的本人私聊、未全局关闭和 B3 预算许可，两项 reviewed revision 与当前值匹配。关闭时两项为 `null`，无需私聊或预算仍可关闭。
- `/api/v1/accounts/me/owner-model-proactive` 的 GET/PUT 响应 `{revision:int, blocked:bool}`，默认 `{revision:0, blocked:false}`；PUT `{expectedRevision:int, blocked:bool}`。开启全局停止会撤销该主人的所有现有主动联系许可。解除停止不给任何 AI 新许可；每个 AI 必须重新启用。全局版本同时阻断在关/开之前准备的 per-AI 请求，即使当时没有 per-AI 行。
- 成功 PUT 仅推进其设置 `revision` +1，不立即发送。读取默认无新行。`401` 凭证失效，`404` 非本人/非当前有效 AI，`400` 字段、类型或范围无效，`409` 状态过期或不满足开启门槛。

## 排程、模型调用和回放边界

[迁移 608](../../apps/host/lib/src/ai/life/owner_model_proactive_migration.dart) 只增加独立设置、全局停止和收件人+AI 送达水位，不回填任何许可。当前配对、owner 权限、原私聊授权版本和 L3+ 丢失会关闭原许可；provider 或 chat 绑定变化同样使许可失效。同一配对/权限还原不会复活。

失效由触发器在写入事务内完成，而非查询时推断：`owner_ai_direct_grants` 的 insert/update/delete、`direct_conversations` 的 pair 改写、`ai_social_levels` 的 L0–L2 insert/update 与 delete、`model_bindings`（capability=`chat`）的 insert/update/delete，以及 `providers` 的 base_url/encrypted_key/enabled/capabilities 变化与 insert，都会把对应行的 `chat_revision`/`conversation_id`/`nominal_at`/`due_at` 置空并 `revision+1`。触发器只撤销许可，不重建；重新开启必须再走一次 reviewed PUT。

[排程器](../../apps/host/lib/src/ai/life/owner_model_proactive.dart) 复用规则问候的 cursor/连续观察/静默顺延/持久化幂等闸门：每 10 秒观察，错过不补发，重启不重放；名义槽必须由当前轮跨过，即使是在跨午夜静默结束时。频率上限由 `intervalMinutes` 和送达水位共同约束：上次送达后间隔不足不发送。

每个到点槽先独立、持久推进 cursor，再在短事务复核许可版本/槽、canonical pair、L3+、全局停止、静默、用户日、B3 预算日与间隔水位；随后以 `BudgetLayer.b3Proactive` + `ProviderCapability.chat` 调用模型（短系统提示「给主人发一句简短主动问候，不要编造事实，不要提记忆或历史」），B3 降级恒视为静默。拿到短文本后，普通文字 append、送达水位和无正文审计必须在同一事务原子提交；`clientMsgId = 'mp_<owner>/<ai>/<day>'` 用 append 的重复判定做每日去重，与送达水位双重去重。写失败或重启都不重放已经消耗的槽，也不伪造规则问候文本或零 token 结算。

模型调用端口是 `ProactiveChatPort`，与 `StatelessChatPort` 同构（`ownerId`/`ai`/`turns`/`requestId`/`layer`/`context`/`maxTokens`/`expectedProviderId`/`expectedModel`）。生产装配直接传 `runtime.chat`；未配置模型 worker 的隔离宿主用工厂方法，两者都保证「到点即静默」而非伪造回复：

```dart
OwnerModelProactiveModule(
  runtime == null
      ? OwnerModelProactive.withoutModel(
          database: storage.database,
          messages: messages,
          clock: clock,
        )
      : OwnerModelProactive(
          database: storage.database,
          messages: messages,
          clock: clock,
          chat: runtime.chat,
        ),
)
```

`withoutModel` 保留设置与全局停止路由，但每个到点槽都以 `modelUnavailable` 静默结束：不调用模型、不 append、不写送达水位、不写 token 结算。文本另做 512 UTF-8 字节与代理对完整性校验，超限或畸形一律静默丢弃，不截断、不改写为规则问候。

## 隔离验证

宿主目录执行 `dart pub get --offline`、`dart analyze --fatal-infos`、`dart test --reporter expanded test/owner_model_proactive_test.dart test/model_gateway_test.dart`。[测试](../../apps/host/test/owner_model_proactive_test.dart)使用真实 SQLite/default host、合成账号、FakeClock 与合成模型 worker，验证默认关闭、非 owner/匿名、严格字段/查询串/GET 正文、CAS、L0/L1/L2 拒绝、L4 通过、静默顺延、重启不重放、间隔上限、预算耗尽/预算缺失/未知用量三种静默且不调模型不伪造结算、模型失败静默不发送、畸形或超长模型输出静默、模型文本不被当成规则问候、`clientMsgId` + 水位双重去重、加密落库与无正文审计、provider/binding/social-level/consent/direct-pair 变化撤销且还原不复活、全局停止撤销与解除不复活。未启用真实账号或出站模型请求，不是原生客户端或通用主动社交验收。

测试夹具自行用真实迁移对象播种数据库，因为默认宿主的迁移列表与模块装配属于 Lead 的接线范围；一旦 `jingyu_host.dart` 注册了 608，夹具的播种会自动跳过。

