# 2026-11-14 附件上传/内容提取、收藏盲索引、客户端本地索引

**目标：** 补齐 PR #15 遗留的三项搜索/附件能力——收藏专用盲索引、附件上传与正文抽取、客户端本地索引（A）。

**依据：** FR-16/17/62/63、AC-20；需求方 2026-11-14 追加要求。

**性质：** 纯增量。正文/抽取文本仍 AES-GCM 加密落库；可见性由成员策略判定；不改变既有调用方语义（新增参数均为可选）。

## 1. 收藏专用盲索引（服务端）
- Migration 212 `favorite_search_tokens(favorite_id, owner_account_id, token_hmac)` + 索引；密钥独立行 `favorite-index` 存于既有 `search_index_key`（列加密，AAD `favorite:index-key`）。
- `FavoriteBlindIndexService`：分词与消息索引一致（中文 bigram / 英文词≥2）；只存 HMAC；`indexFavorite` / `removeFavorite` / `candidates`。
- `FavoritesService` 可选注入盲索引：新增/删除时维护 token；搜索先取候选解密校验，再以有界扫描兜底，保证任意子串召回与既有行为一致（与消息搜索 blind-then-scan 同构）。消息引用类收藏只索引标题，正文以实时来源为准。
- 边界：token 等值/频率泄露；非明文 FTS；不替代附件/动态搜索。

## 2. 附件上传与内容提取（服务端 M03）
- Migration 213 `attachments`（索引 + 加密抽取正文）、`attachment_uploads`、`attachment_upload_chunks`。
- `AttachmentService`：分片（额度取自 M12 `QuotaPolicy`/`UploadGate` 策略）、断点续传（顺序 next_chunk，重发幂等）、complete 校验声明大小与 sha256 后落 blob 到 `{mediaDir}/{owner}/{id}`、抽取正文加密存 `extracted_text`、按 owner 或会话成员可见读取、owner 删除。
- `AttachmentTextExtractor`：text/plain、markdown、csv、html（去标签/实体）、json、xml 抽取；二进制/PDF/DOCX/图片/音视频标记 `unsupported`（不臆造解析）；正文上限 1 MiB。
- `AttachmentsModule`：POST/PUT/POST/GET/DELETE 五条认证路由。
- 边界：参考 HTTP 适配层 JSON 上限 1 MiB，真实 8 MiB 分片/二进制流需生产适配器；二进制正文抽取未实现。

## 3. 客户端本地索引（packages/jingyu_client_kit）
- `LocalSearchIndex`：纯 Dart、UI 无关、按账号隔离的正向表 + 倒排索引；`applyMessage` / `removeMessage` / `search`（AND 缩候选 + contains 复核 + seq 升序 + 会话过滤 + limit）/ `clearAccount` / `exportAccount` / `importAccount`。
- 分词：CJK 单字+bigram，Latin 整词≥2；本地库落盘与平台密钥加密由外壳负责，本包只做内存结构与可序列化快照。
- 边界：尚未接入 M11 Flutter 外壳（PR #8 仍未合并），本包能力单独可测。

## 验证
各包 `dart analyze --fatal-infos` 与 `dart test`；最终全仓 `tool/check.ps1` 证据记录于 PR 与 requirements-traceability。
