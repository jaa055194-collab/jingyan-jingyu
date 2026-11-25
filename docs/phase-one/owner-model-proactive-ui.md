# 本人 AI 私聊 · 模型主动联系设置

客户端为 `OwnerModelProactiveCard`，复用 `Routes.aiOwnerModelProactive` 与 `Routes.ownerModelProactiveStop` 两个路由常量。宿主未提供接口、拒绝访问或返回无效响应时，不显示为已关闭或已保存。

## 单个 AI 入口

在 AI 运行配置中选择自己的 AI 并解析到档案后，先从宿主读取状态。默认关闭，与原有私聊许可、回复偏好、记忆授权和规则问候无关。填写：

- 24 小时制本地时刻、静默开始/结束和手动固定 UTC 偏移（`±HH:MM`，范围 `−14:00` 至 `+14:00`）。静默起止不能相同，可跨午夜；名义时刻落在静默窗内时延至结束再判断，不补发。偏移不随旅行或夏令时变动。
- 最短间隔 `intervalMinutes`（整数分钟，60..10080，默认 1440）。两次主动联系之间至少间隔该时长，与每日一次的去重水位叠加。

开启或修改已授权的设置，必须有有效的本人私聊、L3/L4、预算就绪、未全局停止和有效的固定偏移。客户端在显示确认前重新读取并比对授权、私聊及全局修订；确认展示具体 AI、范围、时间、静默窗和间隔。宿主仍在写入时检查 CAS 和实时条件。撤回只发送关闭和**已保存**的设置，不接受未确认表单，也不需要最新的开启门槛。

卡片同时显示上次发送时间、预算、社交等级和静默窗状态；并提供**账户级停止**开关，停止会撤回所有现有授权、保留设置，解除不复活任何 AI。所有写操作需要二次确认，拒绝、冲突、未知结果分别提示，没有认证重放或自动写重试。切换 AI、账号或会话代际会使旧视图确认失效。

「已授权」仅表示宿主报告的模型主动联系许可，**不保证发送**；预算不足或模型失败会跳过已授权的时段。设置不读取聊天历史或记忆，不开放其它收件人、任意内容或通知权限。客户端不调用模型、不发送消息、不安排后台计时器。

## 本地验证

- 使用合成账号和回环/替身宿主边界，无真实账户设置或外部请求。[API 用例](<../../apps/client_flutter/test/owner_model_proactive_api_test.dart>)校验响应字段（含 `intervalMinutes`）、CAS、开启门槛预检与各类失败分类；[UI 用例](<../../apps/client_flutter/test/owner_model_proactive_ui_test.dart>)覆盖读取、二次确认开启、关闭保留设置、非法偏移/间隔拦截、门槛抑制与账户级停止（含全局停止写入路由的断言）。
- 宿主端执行 `flutter analyze`、`flutter test test/owner_model_proactive_api_test.dart test/owner_model_proactive_ui_test.dart`。未运行 Android 真机、原生安装、线上宿主或真实发送；不是发布验收。
- 接线：卡片需要 `OwnerModelProactiveApi(connection)`、`profileId`（canonical profile ID）、`aiLabel`、`isCurrent`、`canContactHost` 五个构造参数；Lead 在 `ai_config_editor.dart`/`settings_screen.dart` 中按现有 `OwnerRuleGreetingCard` 的方式插入即可，卡片自身不发消息、不起定时器、不调用模型。

