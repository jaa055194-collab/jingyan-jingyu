# M03 搜索增强：加密盲索引（B）实施计划

**Goal:** 在保持正文 AES-GCM 加密落库的前提下，为消息搜索提供带密钥的盲索引，减少全量解密扫描；后续在 M11 客户端落地后叠加客户端本地 FTS（A）。

**Architecture:** 宿主新增 `BlindIndexService`：对规范化分词后的 token 计算 HMAC-SHA256（密钥由随机 32 字节生成，用现有 `ColumnCipher` 以 AAD `search:index-key` 加密存于 `search_index_key` 表）。只存 token HMAC 与 message_id 的映射；查询时对查询词同样分词/HMAC，取候选 message_id 后解密候选正文做 contains 校验（防误报），再按成员可见性与入群历史下界过滤。

**Spec:** FR-17 / AC-20；需求方 2026-11-14 选择 A+B，并要求搜索覆盖收藏、文件等类型。

## Global Constraints

- 不新增明文索引；token 只存 HMAC，密钥加密落库。
- 可见性仍由成员策略判定；绝不返回非成员或早于入群历史的正文。
- 中文按 bigram、英文按词（≥2 字符）分词；查询与写入使用同一规范化。
- 索引维护必须与消息生命周期一致：新增/编辑重建该消息 token；撤回/删除清除。
- 现有 `/search` 有界扫描保留为兜底；盲索引结果必须再解密校验。

## 分阶段实施

### 阶段 1：索引基础设施（独立可测）
1. Migration 210：
   - `message_search_tokens(message_id TEXT, conversation_id TEXT, token_hmac TEXT, PRIMARY KEY(message_id, token_hmac))` + 索引。
   - `search_index_key(id TEXT PRIMARY KEY, sealed TEXT)`。
2. `BlindIndexService`：
   - `ensureKey()`：读 `search_index_key`，无则随机 32 字节→ColumnCipher 加密→写库；内存缓存。
   - `tokensFor(text)`：NFKC 近似（小写、去标点）→ 中文 bigram / 英文词。
   - `indexMessage(id, conversationId, body)`、`removeMessage(id)`、`searchCandidates(query)`。
3. 单元测试：分词（中英混合/标点/空串）、密钥只加密落库、token 不含明文、重复索引幂等、删除清理。

### 阶段 2：接入消息生命周期
1. `MessagesModule._send` 成功追加后调用 `indexMessage`；`_edit` 用新正文重建；`_recall` 清除。
2. `ScheduledMessageService.deliverDue` 经注入索引服务（可选）索引投递正文。
3. 测试：发送后可搜到；编辑后旧词不可搜/新词可搜；撤回后不可搜；索引失败不阻断发送（记录告警）但需可重建。

### 阶段 3：查询接口
1. `/search` 优先走盲索引候选：分词→HMAC→候选 message_id→解密校验→可见性过滤；不足 limit 时按现有有界扫描补齐（或标记 `mode: blind|scan`）。
2. 参数与返回保持兼容；新增 `mode` 便于诊断。
3. 测试：跨会话隔离仍成立；盲索引命中与扫描结果一致；错误 token/密钥损坏时安全降级为扫描且不泄露。

### 阶段 4：A（客户端本地索引，依赖 M11）
1. 客户端本地 SQLite 增 FTS5 表；同步写入/编辑/删除维护；登出/换账号清空；本地 DB 用平台密钥加密。
2. 客户端搜索优先本地 FTS；服务端 `/search` 作为未缓存兜底。
3. 待 M11（PR #8）合并后实施；当前 #8 为 draft 且与 main 冲突。

### 阶段 5：收藏/文件/链接/动态搜索（依赖对应数据模型）
1. 收藏：需先实现收藏夹表与 API（FR-16）。
2. 文件/链接：需附件索引（M03 attachments）与消息类型扩展。
3. 动态/朋友圈：需 M04 朋友圈模型。
4. 统一 `/search` 增加 `type` 维度（message|favorite|file|link|moment）；每种来源沿用同一可见性判定与盲索引策略。

## 验证与交付

- 每个阶段独立 PR、独立全仓 `tool/check.ps1` 证据；不把未实现阶段计为完成。
- 隐私说明记录等值/频率泄露边界与密钥轮换重建流程。
