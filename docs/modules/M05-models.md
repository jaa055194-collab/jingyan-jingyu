# M05 · models：provider、绑定矩阵、用量、生图

> 依据：v4.2 FR-57/58/59、NFR-05/06、AC-10/12；口径 A-9、B-5、C-8。依赖：storage、accounts。

## 要写的文件

```text
apps/host/lib/src/models/
  models_module.dart       name 'models'
  provider_registry.dart   provider 增删改查、测试连接、模型发现
  binding_matrix.dart      AI × 能力 绑定，含 chat.fast（S1）子绑定
  usage_meter.dart         用量计量、FR-58 硬停、FR-48 分层预算
  model_gateway.dart       abstract class ModelGateway：统一调用入口
  adapters/openai_compatible.dart   第一个适配器（OpenAI 兼容协议）
  balance.dart             官方余额查询入口（口径 A-9），先留接口
  models_migrations.dart   迁移 500–599
apps/host/test/models_test.dart
```

## 接口

```dart
enum Capability { chat, chatFast, vision, imageGen, tts, asr, embedding }

abstract class ModelGateway {
  /// 统一调用。内部依次：查绑定 → 查预算层（LayerBudget.level）→ 查硬停 → UrlGuard → 调适配器 → 记用量。
  Future<Result<ChatResult>> chat(AiId ai, ChatRequest request, {required BudgetLayer layer});
  Stream<Result<ChatDelta>> chatStream(AiId ai, ChatRequest request, {required BudgetLayer layer});
  Future<Result<ImageResult>> generateImage(AiId ai, ImageRequest request);
}

abstract class BalanceProbe {
  /// 查询 provider 官方余额。不支持的 provider 返回 modelUnavailable。
  Future<Result<Balance>> balanceOf(String providerId);
}
```

## 规则

1. 保存或测试 base_url 前必须过 `UrlGuard.check`；`127.0.0.1`、私有地址被拒属预期（AC-10）。HTTP 客户端关闭自动重定向，每一跳手动重查。
2. API key 用 M01 的 `ColumnCipher` 加密存；任何响应、日志、审计、导出里不出现明文（NFR-06）。只返回掩码（末 4 位）。
3. 绑定：文本必填；文本可配有序 fallback 链；**语音不 fallback**；provider 停用后绑定它的 AI 显示"模型不可用"，不自动改绑（FR-58）。
4. 预算：每 AI 每日总额由用户编辑（口径 A-9），按 `splitDailyBudget` 切层，层比例可调。先按层降级（FR-48），再按能力硬停（FR-58）。80% 提示，100% 硬停。
5. `chat.fast` 的规则见 `02-decisions.md` B-5：未配置时调用方走规则引擎，网关不得拿 S2 顶替。
6. 生图：未绑定时工具不可见；各开关默认值按 v4.2 FR-59 表；`to_friends` 需逐好友授权，授权后可自由私聊发送（口径 C-8）。生成结果必须带"生成"标注。

## 验收

- [ ] AC-10 6 类能力的 provider 可增删改；绑定矩阵读写正确。
- [ ] AC-10 key 保存后，任何接口响应、日志、导出中搜不到明文。
- [ ] AC-10 base_url 为 `127.0.0.1`、`10.x`、`localhost` 时保存失败；重定向到私有地址时请求失败。
- [ ] FR-58 达 100% 后 chat 返回 `budgetExhausted`；入站消息仍保存。
- [ ] FR-48 B2 层耗尽时只回主人私聊。
- [ ] B-5 `chat.fast` 未配置时 `ModelGateway` 不调用 S2 模型。
- [ ] AC-12 未绑定生图时 `/画图` 不可见；`daily_cap` 生效；`to_friends` 未授权时拒绝。
- [ ] 语音 provider 故障时返回 `modelUnavailable`，不切换到其他语音 provider。
