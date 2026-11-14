# 后端增量审核交接

## 本轮范围

本轮包括话题引用元数据接口和自身AI账号创建/发现接口。已有独立代码审查；跨模型审核未执行。本记录描述技术审核范围，不代表完整产品验收。

## 审核基线与重点

- main基线b4ab568，PR #7已合并。后续工作位于PR #10：话题引用元数据、认证HTTP和默认304迁移；自身AI账号接口在其后追加。
- 核对账号、AI principal AccountId与profile AiId的区别；话题scope先前混用已用失败回归修复。
- 核对当前bearer的account/device、active human operator、成员历史边界、退群、跨群来源及归属变化。
- 账号创建不得隐含profile/persona/好友/私聊或AI凭据。FR-08的AI同意/预授权未被人格自主性规则替代。
- 生产MemoryAuthorization尚无安全放行子集：缺持久opt-out/撤权、传播同意、可信内容分类绑定及目标会话/scope/purpose；不能用operator权力或真实source ID代替第三人同意。
- 话题当前只有已有消息的引用聚合，不是话题回复发送或AI上下文跟随。群AI限流admission也未接实际消息发送事务。

## 明确未完成

完整自动AI回复、精确provider tokenizer和持久记忆召回授权、来源撤权十分钟清理/反悔机制、语音/3D及双端完整体验均未验收。M11 PR #8仍是独立未完成工作，不把后端测试通过当作客户端可用。

实际验证结果与当前修订以PR描述及requirements-traceability.md为准；被票结束中断的早期整仓check不计最终通过证据。审核应给出分级问题、影响接口与可重复的验证证据。
