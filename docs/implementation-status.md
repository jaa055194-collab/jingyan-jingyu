# 实现状态与接续边界

当前主干基线：`b4ab568`，包含 M01（PR #6）、M02（PR #9）与后端基础增量（PR #7）。本分支按用户授权继续实现；这是完整交付中的增量，不能当作全产品已完成。本轮技术审核范围与重点见review-handoff.md；完整产品验收仍未完成。

## 已合并前置

M01 提供 SQLite、事务迁移、Windows 密钥保护、加密列及持久审计。M02 提供持久账号/邀请/设备、生产鉴权、HTTP、初始化与限流。沿用主干实现，不保留第二套账号 schema 或鉴权；早期本票账号原型已移出工作树，避免与主干冲突。

## 本分支增量

- 插件激活期复用受限上下文，保持私有内存状态；能力不可变快照，失败激活/停用后上下文失效。并发激活按实例隔离贡献并预留ID；停用立即撤销上下文，未结束的激活完成后清理资源并防止复活。若激活永不结束，宿主无法强制执行其清理。公开签名不变，不承诺跨重启保存。
- M12 配额与并发许可纯策略，边界测试覆盖；未接入真实上传、清理或备份。
- Migration 200 与 `SqliteMessageStore`：正文 AES-GCM（AAD含消息id）、事务 seq/幂等、分页、设备ack、重启持久化。MessageStore仍是内部可信仓储，权限由服务器成员策略执行。
- 默认宿主提供认证设备ACK接口，重新核对bearer账号与设备、检查当前会话可见性，再调用已有持久存储推进该设备游标；倒序不回退、超出head裁剪。成员检查与写入分开，撤权在途遵C-5；WebSocket、客户端读位点与跨端未读仍未完成。
- 默认宿主提供消息撤回接口：仅发送者本人、发送后 24 小时内、未撤回时成功；成功后正文重加密为 `{"recalled": true}` 占位、`recalled_at` 落库、seq 不变，审计只记消息 id 与会话 id 不含正文。他人消息/非成员/未知消息/超时/重复撤回按 403/404/400 拒绝且不改数据。撤回与审计分属两次数据库写入：若审计插入失败，撤回已生效但请求不报 500（不静默回滚），这是本切片的已知限制。
- 默认宿主提供消息编辑接口：仅发送者可编辑自己的未撤回消息；旧正文以 `message_edits` 加密保存（AAD 绑定 edit_id），当前消息正文更新，差集同步返回新正文；审计只记 edit_id。管理员专用路由可读取旧版本明文（按 decisions A-8），普通成员请求该路由返回 403。
- 默认宿主提供定时消息：POST `.../scheduled-messages` 校验未来时间与成员权限后加密入库（迁移207）；DELETE `.../{scheduledId}` 仅发送者可取消；宿主每30秒投递到点消息，复用消息追加的 `scheduled:<id>` 幂等键保证只写一次；超过24小时未投递的按 B-4 标记 expired 不补发。本项目尚无通知通道，故“未发出”通知未实现。
- 默认宿主提供消息表情回应：`POST .../messages/{messageId}/reactions` 按当前成员权限对可见消息添加/取消同一 emoji（重复切换即取消），`GET` 按同权限列出回应；迁移208按(消息,账号,emoji)唯一存储。回应状态不嵌入差集同步载荷，客户端需另行查询。
- 默认宿主提供全局消息搜索 `GET /api/v1/search?q=...`：按当前账号逐会话校验可见性（含入群历史下界）后解密扫描正文，支持 senderId/kind/from/to 过滤与 limit(1–100)；不返回非成员或入群前正文。因正文加密无法建立明文FTS索引，当前为有界扫描（每会话最多20页×200条），不是高性能FTS实现。
- 默认宿主提供消息置顶：`POST/DELETE .../messages/{messageId}/pin` 按成员权限置顶/取消，`GET .../pins` 列出；迁移209按(会话,消息)唯一存储，单会话最多50条；重复置顶幂等。
- 搜索增加加密盲索引（B）：迁移210存 `message_search_tokens`（仅 HMAC token 与消息 id）与 `search_index_key`（随机密钥经列加密保存）；发送/编辑重建该消息 token、撤回清除。`/search` 先取盲索引候选并解密校验，再以有界扫描补齐；结果带 `mode: blind|scan`。已知边界：token 等值/频率泄露；不替代 FTS，不支持任意子串。
- 收藏基础与搜索：迁移211提供本人私有的文本、链接及文件元数据收藏；标题和自填内容使用绑定owner/id的AAD加密。消息收藏只保存来源引用，创建/列表/`GET /search?type=favorite`均核验当前成员与入群历史，读取实时正文；来源编辑即时反映，撤回或失去成员权限后整项（含标题）不再返回。收藏搜索不依赖消息搜索服务装配。尚未实现收藏本地FTS/盲索引、真实文件内容检索、标签/备注编辑、客户端UI与C-2十分钟物理清理；不宣称完整FR-16或AC-20完成。
- Migration 300 与群成员权限：创建群、列出本人群、owner添加已存在且有效账号；默认历史all，可创建joined历史群。同一事务记录成员及当时消息head+1；服务器同步强制历史下界。
- 默认宿主装配上述持久消息/成员服务，缺少成员策略时拒绝消息读取和发送，不再默认放行。提供认证群创建、列表及成员添加路由；身份只取principal。
- `StorageModule`增加可选迁移列表参数，默认保持M01原样；默认宿主统一应用1/100/200/300，M02自身启动检测已存在迁移不重复执行。
- 收藏专用盲索引：Migration212 `favorite_search_tokens`（只存 token HMAC 与收藏 id，密钥独立行 `favorite-index` 经列加密），`FavoriteBlindIndexService` 与 `FavoritesService` 可选注入；新增/删除维护 token，搜索先取候选解密校验再以全量扫描兜底，保证任意子串召回与既有行为一致（候选满额时可跳过扫描）；消息引用类只索引标题、正文以实时来源为准。
- 附件上传与内容提取：Migration213 `attachments`/`attachment_uploads`/`attachment_upload_chunks`；`AttachmentService` 分片顺序上传与断点续传、声明大小与 sha256（流式校验）后落 blob 到媒体目录、正文抽取加密存 `extracted_text`、owner 或会话成员可见读取、owner 删除；`AttachmentTextExtractor` 支持文本类（html 去标签/实体、json/xml、1MiB 上限），二进制/PDF/DOCX 等如实标 unsupported；`AttachmentsModule` 提供五条认证路由并加入默认宿主。限制：对外分片 512KiB 适配 1MiB JSON；单附件≤128MiB、正文抽取仅≤4MiB；M12 真实配额/磁盘探测未接线（默认按充足，仅限制每账号 pending 上传数=3）；媒体 blob 按 FR-62 明文落盘，仅抽取文本加密。
- 客户端本地索引：`jingyu_client_kit` 新增纯 Dart `LocalSearchIndex`（账号隔离正向+倒排、增改删、AND 候选+contains 复核、会话过滤/limit/seq 排序、单 CJK 字与 Latin 子串、清除账号、JSON 快照导入导出）；未接入 M11 Flutter 外壳（PR #8 未合并），落盘加密由外壳负责。
- 附件消息与文件搜索：`AttachmentService.assertSendable` 校验消息引用的附件属于发送者本人且上传时绑定同一会话（他人附件/跨会话/未知/非法引用拒绝，成员与历史由发送处策略判定）；`GET /search?type=file` 仅在本人自有附件内按已抽取正文做包含匹配并返回片段（他人不可见）。
- 收藏标签与备注：Migration214 为 `favorites` 增加加密的 `tags`（JSON 数组）与 `note` 列；`FavoritesService` 创建时校验（≤20 标签、每个≤50、备注≤2000字符）并加密落库，列表返回 tags/note，搜索匹配标签/备注；`GET /favorites?tag=` 大小写不敏感按标签过滤；`PATCH /favorites/{id}` 仅本人可整体替换标签/备注（null 清空）并尽力重索引。
- 群公告：Migration305 为 `social_conversations` 增加加密 `announcement` 列；`ConversationService.setAnnouncement/getAnnouncement` 仅群主可设置/清空（≤2000字符）、成员可读、非成员拒绝；认证 `PUT/GET /conversations/{id}/announcement` 已挂默认宿主。
- 群成员列表：认证 `GET /conversations/{id}/members` 供当前成员列出成员（accountId、是否群主、加入时间）；非成员 404、匿名 401；身份只取 principal。
- 客户端本地消息缓存：`jingyu_client_kit` 新增纯 Dart `LocalMessageCache`（按账号/会话/seq 有序、同身份编辑覆盖、冲突身份拒绝、深不可变正文、撤回终态、分页、账号隔离、版本化快照原子导入导出）；旧页和旧快照不复活已知撤回正文，损坏快照不清空现有数据。不落盘，加密持久化与服务端授权由外壳负责。

## 验证

局部31项持久消息/成员/路由/历史/迁移测试已通过。独立审查未发现本增量的严重问题，确认同Tx历史边界、服务器过滤及M02差异行持久化不会覆盖消息/社交数据。默认宿主端到端和最终全仓证据在PR描述及需求追踪中更新；旧版本的测试结果不代表后续提交通过。

## M05 模型配置与内部调用链

`GET /api/v1/ai-profiles/{aiId}/usage` 为当前operator返回AI今日已记录token按层/能力汇总。拥有关系、显式offset与账本同Tx读取，计数用BigInt并以十进制字符串输出；旧日期未结算usage单独按能力标未知。即使额度耗尽或有pending仍可读，不作为模型放行凭据；不含周趋势、UI、费用、余额或provider历史归因，无新网络调用/账本写入。未配置/legacy空offset要求配置，不推断UTC。

按认证账号隔离的provider CRUD与加密key存储（Migration500）仅返回掩码视图；501显式映射AiId档案与AI账号。502保存独立chat/chatFast绑定，禁用不改配置，有绑定provider删除返回conflict。503持久预算/usage账本，504原子配置显式时区；旧null时区要求配置，不默认UTC。认证注册已有AI、绑定、预算路由已挂默认宿主。

内部ModelRuntime经持久化时区调用gateway：解析绑定→预算/降级→取凭证→事务登记pending→单次调用→真实usage结算。B1不替用S2；B2层耗尽只有可信主人私聊允许，日/能力硬停仍优先。unknown usage保留pending并阻止同能力后续调用，需可信对账；重复请求不重发，没有结果缓存。

旧Guarded HTTP原型的停滞TLS握手不能单独强制回收，生产组合改用每请求独立Dart子进程。凭据仅stdin、有界IPC、deadline杀进程并等待退出；真实本地TLS测试验证3次停滞调用后peer断开且进程退出。worker使用真实DNS与固定IP/TLS原域验证，无私网测试绕过。部署显式设置JINGYU_MODEL_WORKER_EXECUTABLE与JINGYU_MODEL_WORKER_PATH两个绝对路径后注册runtime服务；缺省仅提供配置接口，不偷偷调用本机SDK。无真实公网模型调用或自动回复触发链。

独立review检出的层降级inspect→begin竞态已由同Tx策略重检修复；模型空白/legacy脏值在pending前拒绝；binding配置bearer必须匹配principal账户与device。定向证据与最终全仓结果记录于需求追踪和PR。

认证GET/POST `/api/v1/accounts/me/ai`现可列出/创建当前人类operator自己的AI账户，POST仅接受displayName，GET只返回ID/名称/disabled并实时查询当前归属；管理员也不能替别人创建。创建不产生AI登录凭据、profile、persona、好友或私聊；随后仍须显式注册profile/配置模型。这不是完整AI创建向导或自动AI回复链。尚无有序fallback、流式、模型发现/连接测试、生图和自动对账，不宣称整个M05/AC10已完成。

## M06 内部记忆仓储（未生产装配）

可选Migration600与内部MemoryStore复用MemoryPolicy：opt-out先于验证/事务零写入；空分类T1 pending；正文AAD绑定owner/AI/scope/条目；SQL过滤owner/AI/active/非T2后逐条同Tx授权与解密，损坏密文返回安全internal；模型不能自行确认，状态变更及审计同事务。7项真实SQLite/AES测试已父/独立review通过。

必须显式提供MemoryAuthorization，没有生产默认放行。测试群fixture核验AI principal成员、历史下界和真实来源，只证明内部授权port可用，不是生产跨用户许可。私聊/话题/来源撤权/群外传播授权未齐，未挂宿主、未接模型上下文，也未声明T2脱敏或完整记忆管理器。

2026-11-14只读核查确认：候选的opt-out布尔不等于持久授权，真实source ID不能证明摘要无第三人内容；MemoryContext只有talkingWith账号，缺实际目标会话/scope/用途。来源撤回状态、同意与十分钟清除/反悔流程也未建立，因此即使owner-only私聊也没有可安全默认放行的生产子集。不能以fixture、operator身份或缺少禁止记录代替同意。

## 好友同意与私聊

Migration301记录双向好友同意与拉黑；人类拉黑关系按canonical operator映射影响其AI，单独拉黑AI不影响主人或同胞。解除拉黑不会恢复好友，必须重新申请同意。认证状态/申请/接受/拒绝/拉黑接口逐次匹配bearer账户和device。AI预授权尚未实现，operator不能代AI同意。

Migration302独立私聊固定成员与canonical唯一账户对；好友同意后可打开私聊、发送及同步。拉黑后双方仍可读历史但不能发送，解除后重新同意才恢复。群与私聊策略按持久实体类型选择，共享ID歧义时全部拒绝，防消息仓储串读。真实HTTP/SQLite回归覆盖上述链路；Social启用好友时显式依赖accounts，注册重排不丢路由。

## 群管理与AI发言设置

群主可将所有权转给现有有效人类成员；非群主成员可退出，群主须先转让；群主可移除成员，operator可退出其当前持有的AI。成员身份撤销立即阻止群消息读写，joined历史群重新加入从新边界开始。认证群管理路由校验当前bearer账号与设备，非成员不获管理员越权。

Migration303及认证配置路由保存群AI策略：群主设置群共享每日上限、轮次数、主持/自主插话及静音；AI operator单独配置该AI间隔，不被群主共享配置覆盖。默认需被提及，自主插话间隔只统计自主发言、每轮限制跨午夜不重置；日限额使用可信调用方提供的时区日。内部原子admission可以防并发超限，但**尚未接入AI触发与实际发消息事务**，不宣称群AI已自动发言或绝不会超发。HTTP秒数在构造Duration前验证可表示范围，避免整数回绕。

## 话题引用元数据

默认Migration304和TopicService只为已有群消息建立话题及引用，不复制正文、不发送回复；根消息和每条关联都在同一事务内重新核验当前成员和入群历史边界，根不可见则话题不可见。仅原发送者或群主可关联消息，群与私聊ID冲突拒绝。AI话题scope通过501映射得到真实profile ID，而不是AI账户ID；scope本身不授权记忆采集或外传。17项SQLite测试覆盖来源消失、退群、历史边界和不同身份映射。已挂默认宿主的认证元数据/引用HTTP，逐次校验bearer账户/设备并拒绝正文或actor字段；8项HTTP回归覆盖隐藏根、第三人关联、旧凭据、退群及损坏密文仍只返元数据。尚未实现话题回复、上下文跟随与来源撤权，不能当完整FR25。

## 有界上下文与版本化人格（内部能力）

ContextAssembler要求真实模型的完整输入token计数器及显式窗口/输出/安全预留，不默认估算；固定系统/人格和当前用户输入装不下则报错，不截断人格；只选近期完整轮次、授权同scope摘要及过阈值topK记忆。召回文本为带来源的user-role数据，不能提升为system。21项测试与独立review通过，包括万轮历史。调用方仍须分页检索、消化省略ID并保全重要事实；精确tokenizer、摘要生成和自动回复装配未完成，不宣称不会遗忘或提示注入不可能。

Migration601人格服务提供明确P0/P1/P2初始化、加密当前卡与只追加历史、版本CAS、operator锁定/编辑/撤回及AI自迭代理由/证据。现已在默认宿主注册既有601（不启用memory600），PersonaModule提供当前operator的显式初始化、当前卡读取、带reason/expectedVersion的手动PATCH与lock/unlock HTTP；不默认初始化，不允许JSON伪造actor/owner，非owner/admin无越权。遵A1锁定P0/P1而P2自主，owner手动编辑不受自主锁限制；旧M06笼统锁定验收冲突保留。历史仍加密且只追加；当前operator另可通过GET `/ai-profiles/{aiId}/persona/history`按版本升序分页（afterVersion≥0、limit 1–100，默认50），返回diff/原因/证据引用及前后快照；每页重新核验当前归属，SQL最多取limit+1条且只解密返回条目。POST `.../persona/revert`严格接收changeId/expectedVersion/reason，复用同事务CAS，将所选变更的before完整快照作为新版本恢复，因此也撤销之后的内容修改，但保留当前锁定状态；初始化和锁记录不可作为恢复目标。内部无界history保持兼容，不对HTTP开放。分页只限制行数、不承诺响应字节上限；现有HTTP适配器将重复query键归一为单值，不宣称重复键拒绝。无公开selfIterate或自动迭代/模型/记忆触发器，未接人格UI或生产记忆授权，不宣称端到端人格污染防护验收完成。

ContextualChat内部组合已将当前加密人格卡→固定system上下文→装箱→有预算runtime连通。显式profile绑定provider/model/tokenizer/窗口，runtime/gateway一次解析后精确匹配并固定同一dispatch；过期profile在pending前拒绝，输出预留贯通为实际max_tokens。可信scopeKey与AI必须精确一致，输出包含省略ID。10项真实SQLite/加密/回调provider测试通过；没有HTTP/定时自动回复入口，生产记忆授权和真实tokenizer仍由可信调用方提供。

## 规则生活心跳（内部能力）

可选Migration602与LifeEngine要求显式gap阈值、注入规则selector与Clock，不新建timer、不调LLM、不发主动消息。每60秒至多一条实际活动，持久化cadence，恢复只记一条gap而不补造离线活动；结构化状态/枚举SQL检查，没有自由正文。当前operator/active AI每次同Tx核验，记录ID可供后续S1证据引用。13项定向测试通过；未挂生产调度、L0/静默窗与主动行为未实现。

## 明确未完成

M03/M04仍缺群管理员角色、AI好友预授权/群自动发言接线、朋友圈/话题/共享相册、闪照、实时WebSocket、客户端读位点同步/跨端未读；消息撤回/编辑/定时仅完成服务端能力，无客户端入口与定时“未发出”通知。本轮已补：收藏专用盲索引、附件上传与文本类内容提取（服务端）、客户端本地索引纯 Dart 能力。仍未完成：真实二进制正文抽取（PDF/DOCX）、附件与消息发送/UI 接线、8MiB 流式上传适配、客户端本地索引接入 M11 外壳。

M05剩余模型调用链、M06人格记忆、M07快慢脑、M08语音通话、M09创造性功能、M10世界、M12其余与M13全量验收尚未交付。M11由独立PR #8推进，不能把该草案视为已通过Android/Windows验收。当前不具备完整AI聊天产品的使用条件。
