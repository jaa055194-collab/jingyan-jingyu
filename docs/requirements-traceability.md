# 需求追踪与验收

基线：需求v4.2及2026-11-13原始答复；代码主干`0626ae3`（M01 PR #6、M02 PR #9已合并）。本记录仅覆盖已调查要求，不宣称完整需求矩阵或全产品验收。

| ID | 来源/章节 | 要求摘要 | 审批 | 可观察验收 | 实现 | 检查/证据 | 状态与缺口 |
|---|---|---|---|---|---|---|---|
| REQ-001 | plugins/01-plugin-spec §3–4 | 插件私有存储隔离、激活期持续、停用释放 | 已授权 | 指令连续读写相同状态，插件间隔离，权限快照，失效上下文拒绝访问 | client_kit/plugin_host.dart | plugin_context_test；RED先观察丢状态/扩权/停用后仍可调用，再修复GREEN | 验证通过（内存生命周期），不声明重启持久化 |
| REQ-002 | FR-63 / decisions B-6 | 20GB默认可调；80%告警；满额拒>50MB文件；磁盘<10%全停 | 已授权 | 大小/比例精确边界、文字图片不计配额、语音可发 | lifecycle/quota.dart | quota_test：16个测试 | 纯策略通过；未接入实际计量/上传；技术单位GiB/MiB |
| REQ-003 | decisions B-6 | 8MB分片、每账号并发≤3 | 已授权 | 第4个许可拒绝，账号隔离、重复/跨gate释放不增名额 | UploadGate | quota_test | 纯策略通过；未执行真实上传 |
| REQ-004 | FR-04～07 / M02 | 持久账号、邀请、设备与鉴权 | 已授权 | 主干M02契约/HTTP/持久化验收 | 主干PR #9 | 沿用canonical主干tests，不维护第二套账号 | 已合并；本票最终全仓须重验 |
| REQ-005 | FR-09 / M11 | Android与Windows客户端 | 已授权 | 双端构建/设备行为/真实Before–After | 独立PR #8 | 本票未运行客户端验收 | 未完成，不声明草案可用 |
| REQ-006 | FR-14 / M03 | 单调seq、幂等、差集、持久ack | 已授权 | 并发重放不重复，重启保持，加密落盘不出现正文 | messages/sqlite_message_store.dart；Migration200 | sqlite_message_store_test：15项含原契约/并发/扫描/AAD/重启/失败回滚 | 局部通过；transport ack/WebSocket与跨端未读未接入 |
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

## 验证口径

2026-11-13在当前增量上，31项新持久消息/群权限/HTTP/迁移测试主代理及独立审查均通过；全仓 `tool/check.ps1` 输出 `ALL CHECKS PASSED`：core 20、protocol 9、host_kit 10、client_kit 18、host 144，所有分析无问题。其后仅新增默认host的joined群端到端回归；`host_test.dart` 19项全部通过，最终host分析无问题。该回归验证真实登录后创建群、管理员非成员404、owner添加成员、服务器只返回入群后消息、列表可见。总计当前覆盖的各包测试为202项（全仓201项 + 后加的host回归1项），不是202条产品需求验收。旧工作树结果不作为未来提交通过证据。

最新子进程与预算runtime工作树完整执行 `tool/check.ps1`：`ALL CHECKS PASSED`，core20/protocol9/host_kit10/client_kit18/host272（总329），各包分析无问题。随后仅新增trusted worker配置装配1项，assembly2项通过、最终host analyze无问题，共覆盖330项，不代表330条需求验收。独立review发现的层降级竞态和legacy model生成pending两Important均先RED回归后修复并复验关闭；config路由account/device与bearer匹配也已回归通过。

代码审查确认：canonical SqlAccountsStore使用差异行UPSERT而非父行REPLACE，不在账户正常认证时删除社交/消息数据。新增群history边界和加入写入同一BEGIN IMMEDIATE事务，服务器同步强制最低seq。

未实现要求不能因已有测试通过而计完成。完整M03–M13及AI产品主体功能见implementation-status.md的明确缺口。
