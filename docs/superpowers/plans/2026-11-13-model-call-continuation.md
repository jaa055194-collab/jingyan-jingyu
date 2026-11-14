# 模型调用接续：事务绑定、账本与可取消进程传输

基于M05前置及用户允许常规技术取舍，保持现有provider/adapter调用者不破坏，继续以下独立局部：

- 子进程HTTP保持相同request形状，可信executable/workerPath不来自请求。纯JSON stdin/out，不把key放argv；stdout/响应/并发有界，deadline kill并等待exit；必须用真实停滞TLS证明peer关闭，不以isolate退出冒充回收。
- Migration502绑定显式AiId与同owner provider/model/capability。chat.fast与chat独立，停用不改绑定，provider有引用时删除返回conflict。
- Migration503显式预算账本，无初始总额/时区默认，日key来自可信Clock+配置。begin持久pending，不把unknown usage当0；真实usage幂等结算，已记账硬停但不宣称预估/在途绝不超额。
- 认证现有AI档案注册/解析接口。新AI创建与profile注册不可用两个事务假装原子；暂只注册已存在AI。

验证顺序：各局部RED/GREEN → 真实进程deadline/秘密IPC安全 → 独立review → 父统一装配与全仓检查。无外部真实模型调用授权需求；本地fixture与无公网测试足够验证协议，不谎称真实provider可用。

完成前不调用生产gateway，也不把budget选择或固定日时区写成未授权默认。若进程模型仍无法证明资源收敛，如实保留限制，不能以有界队列掩盖回收失败。
