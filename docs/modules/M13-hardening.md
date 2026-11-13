# M13 · hardening：审计全覆盖、串数据回归、全量验收

> 依据：v4.2 FR-67、NFR-05/07/09/10、§19 全部 AC、AC-31。依赖：全部模块。

## 要写的文件

```text
apps/host/test/regression/
  cross_user_test.dart     串数据回归：A 永远查不到 B
  admin_no_content_test.dart  管理端无正文
  outbound_test.dart       全部出站点都经过 UrlGuard
  audit_coverage_test.dart 规定动作都写了审计
tool/init_host.ps1         一键初始化宿主（AC-31）
docs/acceptance.md         AC-01～35 与 CR 验收逐条记录：环境、步骤、结果、证据
```

## 规则

1. 串数据回归（FR-67、NFR-09，发布硬门槛）：建两个用户 A、B，各自写消息、记忆、收藏、动态、日记、附件；用 A 的 token 调**每一个**读接口，断言响应里找不到 B 的任何内容。路由清单从 `Router.describe()` 取，新增路由会自动进入测试。
2. 管理端：用管理员 token 调每一个 `Access.admin` 路由，响应里搜不到已知正文、记忆正文、明文 key。允许的例外只有 `02-decisions.md` A-8 的旧版正文路由。
3. 出站：把 `UrlGuard` 换成记录调用的假实现，跑完各模块测试后断言每一次出站都先经过它。
4. 一键初始化（AC-31）：从空目录完成建库、创建唯一管理员、生成第一个邀请码、写入 tailnet 监听地址；不依赖任何旧库、旧配置、旧路径。
5. `docs/acceptance.md`：每条 AC 写明环境、步骤、结果、证据。没跑或没通过的如实写"未通过"，不要把模糊项写成通过。

## 验收

- [ ] AC-01 串数据回归全绿；管理端无正文、无记忆正文、无明文 key。
- [ ] AC-31 在空目录运行 `tool/init_host.ps1` 后宿主可启动、管理员可登录。
- [ ] `docs/acceptance.md` 覆盖 AC-01～AC-35 与 CR-01～CR-12，每条都有结果。
