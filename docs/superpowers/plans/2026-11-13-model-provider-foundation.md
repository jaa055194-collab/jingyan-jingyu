# M05 provider 与安全出站前置实现计划

**Goal:** 为后续模型调用提供按账号隔离的加密provider配置，以及不会在DNS检查后重新解析的实际HTTP传输；不把前置实现当作完整M05。

**来源:** docs/modules/M05-models.md，需求FR-57/58、NFR-05/06，decisions A-9/B-5。

## 当前交付范围

- [x] provider仓储：Migration500，owner参数由可信服务器scope限定，SQL过滤；API key AAD绑定owner/provider/列，view仅末4位掩码。
- [x] 配置接口：认证用户的创建/读取/更新/删除；URL检查；禁用不改绑定，尚未创建绑定接口。
- [x] HTTP原型：固定已校验IP、显式TLS原host验证、拒redirect/代理、总timeout/响应限额；停滞握手清理仍有Important，未生产接入。
- [x] 局部验证：provider7、HTTP6、identity11、transport13、adapter10、默认装配1项全部通过。
- [ ] 最终全仓验证后记录准确提交；TLS残留问题不因测试通过而消失。

## 不在此前置中擅自确定的规则

- AiId与AccountId已用Migration501显式映射，尚未接人格域，不隐式互换。
- 日总预算/结算时区无默认；未来配置显式输入，不能发明无限额或固定token数。
- gateway的B2“只回主人私聊”需要可信场景，不能统一硬拒或无条件放行。
- chat.fast未配置或故障不得调用S2；前置尚未实现任何chat调用。
- 生图、绑定、有序fallback、用量计量及模型发现/测试连接不在本片，不勾完整AC10/12。

## 技术与迁移记录

M05模块明确给500–599，与storage/migrations.dart注释400–499冲突。此次用具体模块规范的500，保持既有已发布迁移不变；未来M06分配必须避开该范围并明确记录。

安全传输复用UrlGuard.isBlocked现有范围；固定IP解决DNS检查/建连差异，不代表已完成所有保留地址分类或全部出站点验收。
