# 需求追踪与验收

基线：需求v4.2及2026-11-13原始答复；代码主干`b4ab568`（M01 PR #6、M02 PR #9及后端增量PR #7已合并）。本记录仅覆盖已调查要求，不宣称完整需求矩阵或全产品验收。

| ID | 来源/章节 | 要求摘要 | 审批 | 可观察验收 | 实现 | 检查/证据 | 状态与缺口 |
|---|---|---|---|---|---|---|---|
| REQ-001 | plugins/01-plugin-spec §3–4 | 插件私有存储隔离、激活期持续、停用释放 | 已授权 | 指令连续读写相同状态，插件间隔离，权限快照，失效上下文拒绝访问 | client_kit/plugin_host.dart | plugin_context_test；RED先观察丢状态/扩权/停用后仍可调用，再修复GREEN | 验证通过（内存生命周期），不声明重启持久化 |
| REQ-002 | FR-63 / decisions B-6 | 20GB默认可调；80%告警；满额拒>50MB文件；磁盘<10%全停 | 已授权 | 大小/比例精确边界、文字图片不计配额、语音可发 | lifecycle/quota.dart | quota_test：16个测试 | 纯策略通过；未接入实际计量/上传；技术单位GiB/MiB |
| REQ-003 | decisions B-6 | 8MB分片、每账号并发≤3 | 已授权 | 第4个许可拒绝，账号隔离、重复/跨gate释放不增名额 | UploadGate | quota_test | 纯策略通过；未执行真实上传 |
| REQ-004 | FR-04～07 / M02 | 持久账号、邀请、设备与鉴权 | 已授权 | 主干M02契约/HTTP/持久化验收 | 主干PR #9 | 沿用canonical主干tests，不维护第二套账号 | 已合并；本票最终全仓须重验 |
| REQ-005 | FR-09 / M11 | Android与Windows客户端 | 已授权 | 双端构建/设备行为/真实Before–After | 独立PR #8 | 本票未运行客户端验收 | 未完成，不声明草案可用 |
| REQ-006 | FR-14 / M03 | 单调seq、幂等、差集、持久ack | 已授权 | 并发重放不重复，重启保持，加密落盘不出现正文 | messages/服务端认证ack路由`Routes.messageAck`、MessagesModule；sqlite_message_store.dart既有head clamp | sqlite_message_store_test15、host_test默认装配回归、message_ack_boundary_test真实撤销/轮转/身份错配/缺策略/无写入/持久化4项；host472项及全仓543项与各包analysis通过 | 服务端ack路由局部已验证；撤权在途遵C-5，WebSocket、客户端last_ack持久化和跨端未读UI未接入，AC-18未全验收 |
| REQ-007 | FR-22 / M04 | 群成员服务器权限 | 已授权 | 非成员不可列出/读取/发送；仅owner加成员；有效账号检查 | social/conversation_service.dart、social_routes.dart、Migration300 | conversation_membership_test 6项、social_routes_test 7项 | 局部通过；好友/私聊/拉黑/群角色/退出未完成 |
| REQ-008 | decisions C-1 | 房主可选择仅入群后历史 | 已授权 | 同Tx取head+1，服务器忽略越界afterSeq，分页不泄露旧内容 | HistoryMembershipCheck、MessagesModule._sync | message_membership_boundary_test 2项；默认host端到端补充验证 | 局部通过；不把客户端过滤当权限 |
| REQ-009 | M01/M03/M04工程约束 | 统一迁移装配 | 已授权 | 默认单库顺序1/100/200/300、旧M01默认不变 | StorageModule optional migrations、defaultModules | storage_extra_migrations_test 1项，先缺参数RED后GREEN | 局部通过，最终全仓重验 |
| REQ-010 | FR-57 / NFR-06 / M05 | owner隔离provider配置与密钥不回读 | 已授权 | A/B CRUD隔离、仅掩码响应、安全审计、加密AAD绑定 | models/provider_registry.dart、models_module.dart、Migration500 | provider8+HTTP6测试，独立review无新严重发现 | 局部通过，已挂配置路由；无发现/连接测试 |
| REQ-011 | M05/M06身份接口 | AiId与AccountId显式映射 | 工程前置 | 有效AI+当前operator才可注册/解析，跨owner404，独立随机档案ID | ai_identity.dart、Migration501 | 11项identity+6项注册HTTP测试 | 局部通过；尚无人格业务/新AI创建HTTP |
| REQ-012 | NFR-05 / M05 | DNS校验与真实连接一致、TLS原域验证 | 已授权 | pinned IP、拒私网答案、HTTPS不明文、证书/hostname拒绝、3xx不跟 | security/guarded_http.dart + process_http.dart | guarded13/process6真实本地HTTP/TLS测试；独立review复验 | 单独guarded仅原型，生产经子进程回收；不宣称所有保留地址全覆盖 |
| REQ-013 | FR-57 / M05 | 单次OpenAI-compatible规范响应 | 已授权 | 保留base path、严格usage/roles、安全错误，无retry/fallback | openai_chat_adapter.dart | 10项测试含int溢出与错误脱敏 | 局部通过；接内部budget/binding/runtime，无真实公网或自动AI回复链 |
| REQ-014 | FR-58 / B-5 / M05 | 独立绑定与停用保留 | 已授权 | chatFast不读chat，跨owner404，model空白拒绝，有引用provider不可删除 | binding_matrix/config_routes、502 | binding12/config7/provider8、真实SQLite | 验证通过的局部；无有序fallback |
| REQ-015 | FR-48/58 | 显式预算与真实用量硬停 | 已授权 | 无默认总额/时区、未知用量阻断、begin同Tx层策略、幂等结算 | usage_meter/budget_configuration/model_gateway、503/504 | usage13/budget10/gateway19/runtime5，独立review关闭竞态 | 内部调用链通过，非自动回复产品验收；在途可超额但照实入账 |
| REQ-016 | NFR-05 / 网络生命周期 | 超时可靠回收出站TLS | 工程前置 | kill并wait退出，peer断开，名额恢复，秘密仅stdin | process_http/http_worker | process6+原guarded13，真实Windows停滞TLS重复3次 | 验证通过；生产组合用process，不单独使用guarded原型 |
| REQ-017 | FR-49/50 / M06 / A-7 | 加密记忆与采集闸门 | 已授权局部 | opt-out零写入、空分类T1、pending不注入、T2 model用途排除、模型不能自确认 | ai/memory/memory_store、可选Migration600 | memory7项真实SQLite/AES，空分类先RED后修；父独立复跑7项及host analyze通过 | 内部仓储验证通过，未生产装配；fixture授权不能算跨用户/外部群传播权限 |
| REQ-018 | FR-08/22 / M04 | 好友同意、拉黑与私聊只读 | 已授权 | target接受才好友；拉黑双向和人类AI继承；解除需重新申请；既有私聊只读 | friendship_service/routes 301、private_conversations/routes 302、CombinedMembership | friend9/HTTP5/private7/HTTP5、重排装配1，独立review | 后端链路通过；AI预授权/双端UI未完成 |
| REQ-019 | FR-48 / 2026-11-13长期上下文要求 | 显式窗口预算与少量相关召回 | 已授权 | 固定人格不裁剪、完整近期轮次、来源与scope/topK阈值、省略ID可见 | ai/context/context_assembler | 21项含万轮历史、Unicode、计数overhead、恶意召回角色隔离，独立review | 内部装箱通过；精确tokenizer、持久重要事实召回及端到端延迟未验，不承诺零遗忘 |
| REQ-020 | FR-41 / decisions A1 / 长期人格隔离要求 | 人格分层版本、锁定和撤回 | 已授权 | P0/P1锁生效、P2自主；canonical AI才能迭代；证据/CAS/不可替换历史/加密隔离 | ai/persona/persona_service、可选601 | 21项SQLite/AES，SQL REPLACE回归先RED后修，独立review | 内部服务通过；未装配人格UI/提示词/调度，不能算端到端抗污染已完成 |
| REQ-021 | FR-48 / 长期上下文要求 | 人格与窗口到模型调用一致 | 已授权局部 | 当前卡固定提示、输出预留max_tokens一致、profile/provider/model精确匹配、换绑不误用tokenizer | ContextualChat、runtime/gateway expected pair | contextual10/gateway-runtime35，父合跑58与review关闭profile错绑Important | 内部组合通过；无自动回复入口/真实tokenizer/记忆ACL默认 |
| REQ-022 | FR-42/45 / M06 | 60秒规则心跳与恢复gap | 已授权局部 | 不调模型，每60秒至多一条；重启只记一次gap不造活动；当前owner权限 | LifeEngine、可选602 | life13项Clock/SQLite/回滚/枚举SQL/错误脱敏，独立review | 内部规则能力通过；未生产调度/主动行为/静默窗 |
| REQ-023 | FR-22 / AC-32 | 群主转让、成员退出及AI移除 | 已授权 | 有效成员间转让；群主不能孤儿退出；退出立即撤权；operator仅撤回自己的AI | conversation_service、group_management_routes | service17/HTTP5+装配回归，独立review | 后端通过；群管理员角色与UI未完成 |
| REQ-024 | FR-23 / A3/A4 | 群AI发言限额与配置 | 已授权局部 | 群主控cap/主持/静音，AI owner控间隔，跨午夜轮次限额，自主插话间隔 | group_ai_policy/routes、303 | policy14/HTTP19，review发现跨日/间隔/整数溢出先RED后修，父合跑58 | 策略与配置已验证；admission尚未与实际AI发言事务接线 |
| REQ-025 | FR-25 / C1 | 话题引用元数据与父群历史权限 | 已授权局部 | root不可见即404、逐source历史边界、关联仅sender/owner、scope使用profile ID、认证元数据HTTP | TopicService/topic_routes、304默认装配 | service17/HTTP8、父33集成测试与host分析通过；scope混用先RED后修，独立review | 元数据子集通过；话题回复、AI上下文、撤权未完成 |
| REQ-026 | FR-04 / M02 | 人类管理自己的独立AI账户 | 已授权局部 | 非管理员可创建自身AI、管理员无跨owner覆盖；列表当前归属、allowlist字段；创建无凭据/好友/私聊副作用 | AccountsModule ownAiAccounts / live AccountSession.ownAiMetadata | 9项真实SQLite+重启/撤销/越权测试，父17项集成回归，独立静态review | 账号接口已验证；profile/persona/好友与完整创建向导仍单独处理 |

| REQ-027 | FR-38/39/60 / plugin lifecycle contract | 并发安全的插件隔离与卸载 | 已授权 | pending ID唯一、贡献按实例原子发布、失败隔离、卸载立即撤销并清理取消激活、清理重入无死锁 | PluginHost / PluginRegistrar / PluginContext | 14个Completer/Stream订阅回归先RED后GREEN，最新clientkit32、全仓检查及独立复审通过 | 激活永不settle时资源清理不能强制完成；不构成恶意原生Dart插件沙箱 |

| REQ-029 | FR-15 / M03 / AC-19(编辑留痕) | 消息编辑与旧版本留痕 | 已授权局部 | 仅发送者编辑未撤回消息；旧正文加密入message_edits；当前正文更新；审计只记edit_id；旧版仅管理员路由可读，普通成员403 | messages/edit、迁移206、MessagesModule._edit(admin _editHistory)、Routes.messageEdit(s) | 契约(内存+SQLite)编辑历史一致性与message_edit_test真实SQLite/Audit 3项，先RED后GREEN；复审修复会话作用域与插入顺序后host490/全仓561通过 | 服务端编辑子能力；无客户端标记"已编辑"UI，无重新生成 |
| REQ-030 | FR-20 / M03 / AC-19(定时) / B-4 | 定时消息入库、到点投递、取消 | 已授权局部 | deliverAt必须未来；仅成员可建；仅发送者可取消；到点追加一次；>24h未投标记expired不补发 | messages/scheduled.dart、迁移207、MessagesModule 调度路由+30s timer | message_scheduled_test真实SQLite/FakeClock 5项（投递一次/取消/拒绝/过期/亚秒不提前），先RED后GREEN；全仓566项与各包analysis通过 | 服务端定时能力；无客户端入口、无“未发出”通知通道 |
| REQ-031 | FR-15 / M03 / AC-19(表情回应) | 消息表情回应（tapback） | 已授权局部 | 成员对可见消息切换同一emoji添加/取消；非成员/未知消息404、匿名401、空/超长/非字符串emoji 400；按消息列出回应 | messages/reactions.dart、迁移208、MessagesModule 路由 | message_reactions_test真实SQLite 2项，先RED后GREEN；全仓568项与各包analysis通过 | 服务端回应子能力；回应未嵌入同步载荷、无客户端交互 |
| REQ-034 | FR-17 / AC-20 / 需求方A+B选择 | 搜索加密盲索引（B） | 已授权 | 只存token HMAC与message id；密钥列加密；发送/编辑重建、撤回清除；查询候选解密校验+可见性过滤；无明文索引 | messages/blind_index.dart、迁移210、MessagesModule钩子、MessageSearchService | blind_index_test真实SQLite 3项+message_search集成mode=blind，先RED后GREEN；全仓576项与analysis通过 | B已落地消息；A客户端FTS待M11；收藏/文件/链接/动态待对应数据模型 |
| REQ-033 | FR-15 / M03 / AC-19(置顶) | 会话内消息置顶 | 已授权局部 | 成员可置顶/取消可见消息；单会话≤50；重复置顶幂等；非成员/未知消息404、匿名401 | messages/pins.dart、迁移209、MessagesModule 路由 | message_pins_test真实SQLite 2项，先RED后GREEN；全仓573项与各包analysis通过 | 服务端置顶子能力；无客户端置顶面板、无上限提示UI |
| REQ-032 | FR-17 / M03 / AC-20 | 全局消息搜索按可见范围过滤 | 已授权局部 | 仅返回调用者可读会话且不早于入群历史的命中；支持senderId/kind/from/to/limit；匿名401、缺q/坏limit/kind/from 400 | messages/search.dart、MessagesModule._search、Routes.search | message_search_test真实SQLite 3项（跨会话隔离/joined历史/参数拒绝），先RED后GREEN；全仓571项与各包analysis通过 | 服务端有界扫描；非FTS5性能实现，无收藏/文件/动态搜索与客户端 |
| REQ-028 | FR-15 / M03 / AC-19(撤回) | 消息撤回：24h、留审计、无正文 | 已授权局部 | 仅发送者24h内可撤回；成功后同步只回占位、seq不变；审计无正文；他人/非成员/未知/超时/重复拒绝且数据不变 | messages/message_store.recall、sqlite迁移205、MessagesModule._recall、Routes.messageRecall | 契约(内存+SQLite，含正文为撤回占位的两实现一致性)与message_recall_test真实SQLite/Audit/FakeClock 7项 | 服务端撤回子能力；闪照/搜索/附件与客户端入口未完成 |

| REQ-035 | FR-16/17 / AC-20 / 收藏与文件等搜索授权 | 本人收藏基础与收藏搜索 | 已授权局部 | 收藏仅本人可列/搜/删；消息引用按当前成员/历史/撤回状态决定可见性；无正文快照；标题内容加密；type=favorite独立分流；坏输入400/密文损坏500 | FavoritesService、Migration211、MessagesModule收藏与搜索路由 | favorites_test 9项真实SQLite回归；search/assembly合跑14项；最终全仓585项（host514）与所有包analysis通过，独立复审无剩余Important | 自填文本/链接/文件元数据及消息引用子集；未实现真实附件内容、A客户端FTS、收藏盲索引与十分钟物理清理 |

| REQ-036 | FR-16/17 / AC-20 / 收藏专用盲索引授权 | 收藏专用加密盲索引 | 已授权局部 | 只存 token HMAC 与收藏 id；密钥独立行 `favorite-index` 列加密；新增/删除维护 token；搜索候选解密校验 + 全量扫描兜底（任意子串召回与无索引扫描一致）；消息引用只索引标题、正文以实时来源为准 | messages/favorite_blind_index.dart、Migration212、FavoritesService(可选blind) | favorite_blind_index_test 真实SQLite 9项（HMAC不含明文/密钥加密/盲命中与候选范围/盲与扫描结果一致/消息来源编辑与撤回/owner隔离/损坏失败关闭/候选满额跳过扫描） | 服务端收藏搜索候选加速（命中满额时提速；常见小结果集仍会扫描）；token 等值/频率泄露，非明文FTS；不替代附件/动态搜索 |
| REQ-037 | FR-62/63 / M03 附件与配额 | 附件上传与内容提取 | 已授权局部 | 分片顺序上传与断点续传幂等；声明大小与 sha256 校验后落 blob；文本类正文抽取（html去标签/实体、json/xml、utf8容忍非法字节、1MiB上限）加密存；owner或会话成员可见、owner删除；配额/磁盘<10% 闸门 | messages/attachments.dart、attachment_extraction.dart、attachments_module.dart、Migration213、Routes 附件路由、默认宿主装配 AttachmentsModule | attachments_test 真实SQLite/AES/临时mediaDir 17项（抽取各类型/分片往返复原/续传/大小-sha拒绝/可见性/删除/配额/磁盘<10%/HTTP 401与400/往返/恶意id拒绝/会话成员校验） | 服务端能力；对外分片 512KiB 以适配 1MiB JSON 传输；单附件≤128MiB、正文抽取仅≤4MiB；M12 真实配额/磁盘探测未接线（默认按充足，仅限 pending 上传数=3）；PDF/DOCX/图片/音视频正文未抽取（如实标 unsupported） |
| REQ-038 | FR-17 / M11 客户端搜索 | 客户端本地索引（A） | 已授权局部 | 按账号隔离正向+倒排；增/改/删；AND缩候选+contains复核；会话过滤/limit/seq升序；单CJK字与Latin子串可命中；清除账号；JSON快照导入导出 | jingyu_client_kit/local_search_index.dart | local_search_index_test 15项 + client_kit整包47项，analyze无问题 | 纯 Dart 能力；未接入 M11 Flutter 外壳（PR#8 未合并），落盘加密由外壳负责 |
| REQ-039 | FR-17/FR-62 / M03 附件消息与文件搜索 | 附件消息引用与附件正文搜索 | 已授权局部 | 消息可引用发送者本人且上传即绑定该会话的附件；他人附件/跨会话/未知/非法引用拒绝；`GET /search?type=file` 仅在本人自有附件内按已抽取正文包含匹配并返回片段，隔离他人 | messages/attachments.dart(assertSendable/searchOwn)、messages_module._send/_search、Routes.search type=file、默认宿主装配 | attachment_message_test 真实SQLite/AES 6项（引用成功/他人404/跨会话400/未知404/非字符串400/文本发送不受影响/file搜索自有一致与他人隔离）；attachments_test 17项仍通过 | 服务端能力；文件搜索仅本人私有、基于已抽取正文（≤4MiB），非跨用户/动态搜索；二进制正文未抽取 |
| REQ-040 | FR-16 / AC-20 收藏标签与备注 | 收藏标签与备注及按标签过滤 | 已授权局部 | 收藏可带≤20个标签（每个≤50字符）与备注（≤2000字符），标签/备注加密存储；列表返回 tags/note；`GET /favorites?tag=` 大小写不敏感按标签过滤；搜索匹配标签与备注文本；`PATCH /favorites/{id}` 整体替换标签/备注（null 清空）并重索引；旧收藏 tags/note 为空 | messages/favorites.dart、Migration214、MessagesModule._addFavorite/_listFavorites/_updateFavorite | favorite_tags_test 真实SQLite 8项（加密落库/返回/搜索标签备注/非法拒绝/无标签为空/标签过滤/更新替换与重索引/仅本人可改）；favorites_test 9项仍通过 | 服务端局部；AI“她的收藏”与客户端UI未做 |
| REQ-041 | FR-22 / M04 群公告 | 群公告设置与读取 | 已授权局部 | 仅群主可设置/清空（≤2000字符），公告加密落库（AAD 绑定会话 id）；成员可读、非成员404、匿名401；空串清空；非群主设置404 | social/conversation_service.dart(setAnnouncement/getAnnouncement)、Migration305、group_management_routes PUT/GET、Routes.groupAnnouncement、默认宿主装配 | group_announcement_test 真实SQLite/AES 2项（设置/成员读/非成员拒绝/非群主拒绝/加密落库/清空/超长与坏字段400） | 服务端能力；群公告为纯文本；群管理员角色与客户端UI未做 |

## 验证口径
2026-11-13在当前增量上，31项新持久消息/群权限/HTTP/迁移测试主代理及独立审查均通过；全仓 `tool/check.ps1` 输出 `ALL CHECKS PASSED`：core 20、protocol 9、host_kit 10、client_kit 18、host 144，所有分析无问题。其后仅新增默认host的joined群端到端回归；`host_test.dart` 19项全部通过，最终host分析无问题。该回归验证真实登录后创建群、管理员非成员404、owner添加成员、服务器只返回入群后消息、列表可见。总计当前覆盖的各包测试为202项（全仓201项 + 后加的host回归1项），不是202条产品需求验收。旧工作树结果不作为未来提交通过证据。

最新子进程与预算runtime工作树完整执行 `tool/check.ps1`：`ALL CHECKS PASSED`，core20/protocol9/host_kit10/client_kit18/host272（总329），各包分析无问题。随后仅新增trusted worker配置装配1项，assembly2项通过、最终host analyze无问题，共覆盖330项，不代表330条需求验收。独立review发现的层降级竞态和legacy model生成pending两Important均先RED回归后修复并复验关闭；config路由account/device与bearer匹配也已回归通过。

最新好友/私聊、上下文与人格并行增量已完整执行 `tool/check.ps1`：ALL CHECKS PASSED，core20/protocol9/host_kit10/client_kit18/host349，总406项，各包分析无问题。随后仅加强模块重排测试的私聊路由断言，该目标再次通过。Social缺accounts依赖的404回归已RED→GREEN；persona SQL REPLACE不可变历史回归已RED→GREEN。上下文与人格内部能力仍不计全产品长期可靠性验收。

2026-11-14 ContextualChat与规则心跳增量全仓 `tool/check.ps1` 再次ALL CHECKS PASSED：core20/protocol9/host_kit10/client_kit18/host383，总440项，所有分析无问题。之后只校正迁移号说明注释及本文档，不改可执行逻辑。profile换绑回归验证错误profile在pending前拒绝、preflight中换绑仍固定原已匹配dispatch。此为内部组合验证，不等于真实公网或长期产品使用验收。

2026-11-14群管理及AI设置增量修后 `tool/check.ps1` 完整执行 ALL CHECKS PASSED：core20/protocol9/host_kit10/client_kit18/host432，共489项，各包分析无问题。独立review复验跨午夜轮次、自主插话间隔和Duration溢出回归；AI admission未接实际消息发送事务，不能算自动群聊验收。

2026-11-14话题引用元数据与认证HTTP增量完整执行 `tool/check.ps1`：ALL CHECKS PASSED，core20/protocol9/host_kit10/client_kit18/host457，总514项，各包分析无问题；父33项装配/私聊回归与独立review通过。这不包含话题回复或AI上下文跟随验收。

2026-11-14自身AI账户HTTP增量完整执行 `tool/check.ps1`：ALL CHECKS PASSED，core20/protocol9/host_kit10/client_kit18/host466，总523项，各包分析无问题。父17项profile/账号装配回归与独立静态review通过；producer另跑31项现有账户兼容回归通过。新增账号接口不隐式产生好友、私聊、profile或persona。

2026-11-14插件生命周期并发修复后完整执行 `tool/check.ps1`：ALL CHECKS PASSED，core20/protocol9/host_kit10/client_kit32/host466，总537项，各包分析无问题。插件14项新增回归与clientkit全测32项通过；独立review确认同ID串用、跨插件回滚、pending取消清理及卸载重入路径已修复。新增群history边界和加入写入同一BEGIN IMMEDIATE事务，服务器同步强制最低seq。

2026-11-14设备ACK认证路由最终callback版本完整执行 `tool/check.ps1`：ALL CHECKS PASSED，core20/protocol9/host_kit10/client_kit32/host472，共543项，各包分析无问题。默认宿主与依赖重排24项通过，新增SQLite边界4项验证真实轮转/撤销、principal错配、拒绝无写入、缺策略及重开持久化；独立review未确认剩余Important。此为服务端游标传输子集，不是双端未读UI或完整AC-18验收。

2026-11-14消息撤回切片最终版完整执行 `tool/check.ps1`：ALL CHECKS PASSED，core20/protocol9/host_kit10/client_kit32/host483，共554项，各包分析无问题。撤回契约覆盖内存/SQLite（含正文恰为撤回占位的两实现一致性）；HTTP真实SQLite覆盖他人403、非成员/未知404、匿名401、恰好24h成功、24h+1s失败、内存Clock边界、审计失败不返回500。独立review确认的Important（内存按正文判定撤回状态）先RED后修。撤回与审计为两次写入，审计失败不回滚，是已知限制；编辑/定时/闪照/搜索/附件及客户端入口未完成。

2026-11-14消息编辑留痕切片完整执行 `tool/check.ps1`：ALL CHECKS PASSED，core20/protocol9/host_kit10/client_kit32/host488，共559项，各包分析无问题。覆盖仅发送者编辑、撤回后拒绝、越权403/非成员未知404/匿名401/畸形400、旧正文AAD加密不含明文、审计仅editId、管理员读旧版与成员403。无客户端"已编辑"UI与重新生成。

2026-11-14编辑历史复审修复后完整执行 `tool/check.ps1`：ALL CHECKS PASSED，core20/protocol9/host_kit10/client_kit32/host490，共561项，各包分析无问题。修复点：内存`editHistory`按会话过滤、SQLite按`rowid`插入顺序返回；契约新增多次编辑顺序与错误会话空结果用例。

2026-11-14定时消息切片及投递时间比较修复后完整执行 `tool/check.ps1`：ALL CHECKS PASSED，core20/protocol9/host_kit10/client_kit32/host495，共566项，各包分析无问题。覆盖未来时间校验、成员/发送者权限、到点投递一次、取消、>24h过期不投递、亚秒deliverAt不提前（按DateTime解析比较，不依赖ISO文本）。前一次全仓出现guarded_http真实TLS时序flake，单独复跑13/13通过、重跑全仓通过。无客户端入口与“未发出”通知。

2026-11-14消息表情回应切片完整执行 `tool/check.ps1`：ALL CHECKS PASSED，core20/protocol9/host_kit10/client_kit32/host497，共568项，各包分析无问题。覆盖添加/取消/列出、非成员/未知404、匿名401、空/超长/非字符串emoji 400。

2026-11-14消息搜索切片完整执行 `tool/check.ps1`：ALL CHECKS PASSED，core20/protocol9/host_kit10/client_kit32/host500，共571项，各包分析无问题。覆盖跨会话可见性隔离、joined历史不下发、发送者/类型过滤、匿名与畸形参数拒绝；实现为加密正文的有界扫描，不是FTS5。

2026-11-14消息置顶与搜索加密盲索引切片完整执行 `tool/check.ps1`：ALL CHECKS PASSED，core20/protocol9/host_kit10/client_kit32/host505，共576项，各包分析无问题。盲索引Token仅HMAC、密钥列加密；搜索命中mode=blind并可退化为scan；置顶上限50且幂等。

收藏与收藏搜索最终工作树完整执行 `tool/check.ps1`：ALL CHECKS PASSED，core20/protocol9/host_kit10/client_kit32/host514，共585项，所有包分析无问题。9项收藏SQLite回归验证搜索分流、owner隔离、当前来源权限/历史边界、来源编辑/撤回/退群、标题与内容加密、缺策略零解密、坏输入零写入、损坏密文安全错误与空标题误命中；独立只读复审无剩余Important。本证据仅覆盖收藏基础及type=favorite搜索，不计文件内容提取、本地FTS或完整AC-20验收。

2026-11-14 附件上传/内容提取、收藏专用盲索引、客户端本地索引增量（PR #16）：各包 `dart analyze --fatal-infos` 无问题；`jingyu_core` 20、`jingyu_protocol` 9、`jingyu_host_kit` 10、`jingyu_client_kit` 47（含 local_search_index_test 15）通过；新增 `favorite_blind_index_test` 9 与 `attachments_test` 17 通过；`apps/host` 定向 93 项（新能力 + 收藏/搜索/盲索引/配额/迁移/社交装配/撤回/默认宿主装配与HTTP/真实端口冒烟）通过，`guarded_http_test`+`process_http_test` 真实网络/TLS 19 项单独跑通过。因新增 attachments 模块与迁移 212/213，同步更新了默认宿主模块列表与迁移版本列表两处既有装配测试期望。全仓 `tool/check.ps1` 由 CI（windows-latest）执行。

2026-11-15 附件消息与文件搜索增量（PR #16 续）：新增 `AttachmentService.assertSendable` 与 `GET /search?type=file`（仅本人自有附件、按已抽取正文包含匹配并返回片段）。`attachment_message_test` 6 项真实 SQLite/AES 通过；`attachments_test` 17、`favorites_test` 9、`message_search_test` 3、`host_models_assembly_test` 2 合跑 37 项通过；`apps/host` analyze 无问题；全仓 `tool/check.ps1` 由 CI 执行。

未实现要求不能因已有测试通过而计完成。完整M03–M13及AI产品主体功能见implementation-status.md的明确缺口。
