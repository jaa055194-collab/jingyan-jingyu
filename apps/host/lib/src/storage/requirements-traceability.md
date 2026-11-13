# M01 验收追踪

基线：Issue #3 与 docs/modules/M01-storage.md，读取 2026-11-13。范围为 Windows 宿主持久化底座；业务表、备份调度与消息仓储属于后续模块。下列已批准条件均由 Windows x64 / Dart 3.14.0 实测。

| ID | 来源 | 原始要求摘要 / 验收条件 | 实现 | 测试或检查 | 证据与状态 |
|---|---|---|---|---|---|
| M01-1 | M01 验收 1 | 空目录建库，版本为最新 | sqlite_database.dart / migrations.dart | empty directory creates latest schema | storage_test.dart，通过 |
| M01-2 | M01 验收 2 | 重启不重复迁移且保留数据 | sqlite_database.dart | restart does not repeat migrations | storage_test.dart，通过 |
| M01-3 | M01 验收 3 | 失败迁移 DDL/数据和版本回滚，可修复后重试 | sqlite_database.dart | failed migration rolls back DDL；bootstrap rollback | storage_test.dart，通过 |
| M01-4 | M01 验收 4 | 事务抛错整体回滚；异步并发不串事务 | sqlite_database.dart | transaction rolls back all writes；unrelated operations wait；Tx expiry | storage_test.dart，通过 |
| M01-5 | M01 验收 5 | AES-256-GCM，96-bit nonce，AAD、tag 验证 | cipher.dart | NIST known vector；tamper/AAD/wrong key；random nonce | storage_test.dart + storage_crypto_test.dart，通过 |
| M01-6 | M01 验收 6 / 规则 5 | 加密正文无明文落盘；DEK 用 KEK 包裹；KEK DPAPI 保护 | storage_module.dart / key_provider.dart | 数据库字节搜索；DEK 重启解密；DPAPI reload/corruption | storage_test.dart + storage_crypto_test.dart，通过 |
| M01-7 | M01 验收 7 | integrity_check 返回 ok | sqlite_database.dart | normal database passes integrity check | storage_test.dart，通过 |
| M01-8 | M01 验收 8 | 持久审计与内存语义相同 | sqlite_audit_log.dart | 同一契约针对 memory/SQLite；重启持久性 | storage_audit_contract.dart + storage_test.dart，通过 |
| M01-R1 | M01 规则 1–3/6 | 参数绑定、逐版本事务、WAL/FK、仅基础三表 | migrations.dart / sqlite_database.dart | injection-shaped bound value、FK rejection、WAL/table inspection | storage_test.dart，通过 |
| M01-R2 | M01 规则 7–8 | 注册 Database/ColumnCipher，替换默认审计 | storage_module.dart / defaultModules | Registry lifecycle/interface lookup；host suite | storage_test.dart + host_test.dart，通过 |

复现：在 apps/host 先执行 `dart pub get --offline`（依赖首次需缓存准备），再执行 `dart test`；仓库完整检查 `powershell -ExecutionPolicy Bypass -File tool/check.ps1`。SQLite 2.9.4 使用系统 winsqlite3.dll 回退，不在测试中下载 DLL。AES/DPAPI 为 Windows 原生 API，非 Windows 明确拒绝而不回退不安全密钥。
