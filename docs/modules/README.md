# 模块编写指令（给实现模型）

> 你是实现模型。你的任务是按本目录里**一个**模块文件把代码写完、测试写全、验收跑通。
> 架构、接口、规则已经定好，**不要改框架**（`packages/*` 与 `apps/host/lib/jingyu_host.dart` 的装配方式）。确实需要改时，停下来在 PR 描述里写明原因，由框架方决定。

## 1. 开工前必读（按顺序）

1. `docs/architecture/01-layering.md`：目录、依赖方向、硬性规则。
2. `docs/architecture/02-decisions.md`：需求方口径。与 v4.2 冲突时以它为准。
3. 你领到的模块文件 `Mxx-*.md`。
4. 模块文件里列出的 v4.2 条款原文（`鲸言鲸语-需求规格-v4.2.md`）。
5. 参考实现：`apps/host/lib/src/messages/`（模块、存储接口、内存实现）与 `apps/host/test/message_store_contract.dart`（契约测试）。

## 2. 每个模块都必须交付

| 交付物 | 要求 |
|---|---|
| 模块类 | 继承 `HostModule`，写 `name`、`dependsOn`、`configure`、`mount`。 |
| 服务接口 | `abstract class`，在 `configure` 里 `services.provide<接口>(实现, owner: name)`。 |
| 存储接口 + 内存实现 | 先写内存实现跑通测试；SQLite 实现在 M01 完成后补，并通过同一契约测试。 |
| 契约测试 | `test/<module>_store_contract.dart`，内存与 SQLite 都调用它。 |
| 模块测试 | 覆盖模块文件"验收"里的每一条，一条验收至少一个 `test(...)`，测试名写验收编号。 |
| 串数据测试 | 凡是有私有数据的模块，必须有"A 查不到 B"的测试（FR-67、AC-01）。 |
| 装配 | 在 `apps/host/lib/jingyu_host.dart` 的 `defaultModules` 追加一行。 |

## 3. 写代码的规则

- 先写会失败的测试，再写实现。
- 可预期失败返回 `Result`，不要抛异常出模块。
- 时间一律用注入的 `Clock`，测试用 `FakeClock`。
- 路由路径写进 `packages/jingyu_protocol/lib/src/routes.dart`，模块里引用常量。
- 跨模块调用只用 `HostServices` 里的接口，不 import 别的模块目录。
- 对外"不存在"和"无权看"都回 404。
- 审计用 `AuditLog.record`，meta 里不放正文、音频、key。
- 出站 HTTP 先 `UrlGuard.check`。
- 不新增第三方依赖，除非模块文件写了允许的包名。

## 4. 完成标准（自己先跑一遍）

在仓库根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File tool/check.ps1
```

它对每个包跑 `dart analyze` 与 `dart test`。全部通过才算完成。PR 描述写：做了哪些验收条目、对应的测试名、还有哪些没做以及原因。

## 5. 模块清单与依赖顺序

按 v4.2 §20 的交付顺序。前置模块未合并时，可以先用其服务接口的内存假实现开发。

| 编号 | 模块 | 依赖 | 状态 |
|---|---|---|---|
| — | system、messages（参考实现） | — | 框架已完成 |
| M01 | storage：SQLite、加密列、迁移 | system | 待写 |
| M02 | accounts：邀请码、登录、设备、管理员 | M01 | 待写 |
| M03 | messages 完整版：编辑/撤回/定时/闪照/搜索/附件 | M01 M02 | 待写 |
| M04 | social：好友、拉黑、群、话题、朋友圈 | M02 M03 | 待写 |
| M05 | models：provider、绑定矩阵、用量、生图 | M01 M02 | 待写 |
| M06 | ai_core：人格、记忆、档案、日记、约定、生活引擎、社交等级 | M03 M04 M05 | 待写 |
| M07 | brain：S1/S2 路由、梗库、领域卡组、预算 | M05 M06 | 待写 |
| M08 | voice：音色工作台、语音消息、通话、语音房 | M05 M06 | 待写 |
| M09 | creative：CR-01～CR-12 | M06 M07 | 待写 |
| M10 | world：3D 街区、房间、形象、Live2D | M04 M06 | 待写 |
| M11 | client_flutter：Android/Windows 外壳 | client_kit | 待写 |
| M12 | lifecycle：配额、清理、备份、导出导入、离开 | M01 M03 | 待写 |
| M13 | hardening：审计全覆盖、串数据回归、全量 AC | 全部 | 待写 |
