# 01 · 分层与依赖规则

> 适用于所有参与实现的模型与人。违反本文件的 PR 直接退回，不讨论"这次特殊"。
> 需求依据：v4.2 FR-09/10/12/14/67、NFR-01/05/06/09；需求方 2026-11-13 答复第 14 条（插件化）。

## 1. 目录与职责

```text
packages/
  jingyu_core/        领域原语：标识、Result、Clock、可见性、记忆分层、预算分层。零依赖。
  jingyu_protocol/    线协议：帧、路由常量、错误码、严格编解码。依赖 core。
  jingyu_host_kit/    宿主模块框架：HostModule、Registry、Router、Pipeline。依赖 core + protocol。
  jingyu_client_kit/  客户端内核：插件契约与 PluginHost、Outbox、SyncCursor。依赖 core + protocol。
apps/
  host/               宿主服务（家中常驻 Windows 电脑）。按模块装配。
  client_flutter/     Android + Windows 外壳（M11 创建），只做 UI 绑定，逻辑放 client_kit。
docs/
  architecture/       本目录：分层、数据、安全、需求口径。
  modules/            逐模块编写指令（M01…）。实现模型按这些文件干活。
  plugins/            插件规范与示例。
```

## 2. 依赖方向（只允许箭头方向）

```text
core  ←  protocol  ←  host_kit  ←  apps/host
                   ←  client_kit ←  apps/client_flutter
```

- `core` 不得 import 任何其他包，也不得 import `dart:io`。
- `protocol` 不得 import `dart:io`，保证双端可用。
- `host_kit` 不得 import `dart:io`：模块路由必须能在纯单元测试里调用。`dart:io` 只出现在 `apps/host/lib/src/http_server.dart` 与具体存储/网络适配器里。
- `client_kit` 不得 import Flutter。凡是能脱离 UI 测试的逻辑都放这里。
- `apps/host` 内的模块之间**不得互相 import 实现文件**。跨模块调用只能通过 `HostServices` 登记的抽象接口。

## 3. 宿主模块的标准形状

每个宿主模块是 `apps/host/lib/src/<module>/` 下的一个目录：

```text
<module>/
  <module>_module.dart   继承 HostModule：name、dependsOn、configure、mount、start、stop
  <module>_service.dart  对外接口（abstract class），登记到 HostServices
  <module>_store.dart    存储接口 + InMemory 实现（持久化实现单独文件）
  ...
apps/host/test/<module>_test.dart
apps/host/test/<module>_store_contract.dart   存储契约测试，内存与 SQLite 实现共用
```

参考实现：`messages/`（`MessagesModule` + `MessageStore` + `message_store_contract.dart`）。新模块照它的结构写。

## 4. 硬性规则（每条都已有框架支撑，不要绕开）

| 规则 | 框架支撑 | 依据 |
|---|---|---|
| 可预期失败用 `Result` 返回，不抛异常穿透模块 | `jingyu_core/result.dart` | — |
| 业务代码不直接调 `DateTime.now()`，一律注入 `Clock` | `jingyu_core/clock.dart`，`FakeClock` 测试 | FR-44/52、CR-03 |
| 标识用强类型或 `validateId` 校验，非法即 400 | `jingyu_core/ids.dart` | FR-67 |
| 路由路径只能取自 `Routes` 常量 | `jingyu_protocol/routes.dart` | — |
| 路由默认要求登录，公开路由必须显式 `Access.public` | `Router.add` 默认值 | FR-05 |
| 管理员路由用 `Access.admin`，且不得返回他人正文、记忆正文、明文 key | `Pipeline` 鉴权 | FR-07、AC-01 |
| 错误响应只带错误码，不带内部信息 | `HostResponse.failure` | NFR-06/10 |
| 审计不记正文、音频、key | `AuditEntry` 构造时拒绝 | NFR-07/10 |
| 一切按 URL 的出站请求先过 `UrlGuard.check`，每跳重定向重查 | `security/url_guard.dart` | NFR-05、AC-10 |
| "不存在"与"无权看"对外一律 404 | 各模块遵守 | 防探测 |
| 私有数据带 `owner_id`，仓储层强制注入过滤 | 各 Store 接口签名必须带调用者 | FR-67、NFR-09 |

## 5. 新增功能的路径（不大改软件）

1. **宿主侧新能力** → 新建一个 `HostModule`，在 `apps/host/lib/jingyu_host.dart` 的 `defaultModules` 追加一行。
2. **替换已有实现**（例如内存存储换 SQLite）→ 实现同一接口、通过同一契约测试，在装配处换掉，调用方零改动。
3. **客户端新功能**（指令、卡片、设置页、房间生成）→ 写一个 `ClientPlugin`，见 `docs/plugins/01-plugin-spec.md`。
4. **新协议帧** → 只在 `jingyu_protocol` 加 `FrameType` 与解码分支，并补往返测试；破坏性变更抬 `protocolVersion`。

不允许的做法：在 `Pipeline`/`Registry` 里为某个模块加特判；在模块间共享可变全局；为了赶进度在 `core` 里放业务逻辑。
