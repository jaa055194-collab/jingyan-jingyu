# Plugin runtime state Implementation Plan

> **For agentic workers:** Implement task-by-task with independent review before delivery. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 插件在激活及斜杠指令执行时使用同一个受限上下文，保留插件私有状态。

**Architecture:** 在现有 PluginHost 内按插件 id 保有激活成功的 _Context。不扩展 PluginContext，不改变调用者签名；失败激活不保留上下文，卸载清空。

**Tech Stack:** Dart，现有 test 包，不新增依赖。

**Spec:** docs/plugins/01-plugin-spec.md §3–4；docs/modules/M11-client-shell.md §规则3。

## Global Constraints

- client_kit 不得依赖 Flutter 或 dart:io。
- 不新增框架接口，不改变 pluginApiVersion。
- 未声明 localStorage/sendMessage 的插件仍不得访问相应能力。
- 这是本次总项目落地中的局部前置修复，不构成 M11 或全产品完成。

## Review Focus

- 激活时写入的状态在首次命令中可读。
- 连续命令的写入可持续读取。
- 两个插件相同存储键彼此隔离。
- 卸载后重新加载不得保留旧上下文。
- 激活失败及后续重试不得污染有效插件状态。

---

### Task 1: Reuse active plugin context

**Files:**
- Modify: packages/jingyu_client_kit/lib/src/plugin_host.dart
- Test: packages/jingyu_client_kit/test/plugin_context_test.dart

**Interfaces:**
- Consumes: PluginHost.load(ClientPlugin), runSlash(String), unloadAll().
- Produces: 原签名不变，context.storage 在同一激活周期内跨调用一致。

- [x] 写首次调用延续状态、跨调用、按插件隔离、卸载重载、失败激活重试行为测试，并覆盖未授权能力拒绝。
- [x] 执行 `dart test test/plugin_context_test.dart`，观察到首次命令状态丢失导致失败（期望 `11`，实际 `1`）。
- [x] 为成功激活的插件保留 `_Context`；命令执行重用；卸载清空；失败时不保存。
- [x] 执行局部测试与 `dart analyze --fatal-infos`；client_kit 全包测试及分析通过。
- [ ] 独立审查 diff，提交及创建PR。

### Task 2: Maintain implementation evidence

**Files:** `docs/requirements-traceability.md`

- [x] 记录插件私有状态实现与实际验证结果，明确配额策略尚未集成及其它模块缺口。
- [ ] 独立审查最终工作树；完成提交并创建PR。
