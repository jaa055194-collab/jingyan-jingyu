# M12 lifecycle · 需求追踪与验收（垂直切片）

> 来源：`docs/modules/M12-lifecycle.md`；v4.2 FR-63/64/65、NFR-11、AC-14/15/29；口径 A-12、B-6、C-4。
> 读取日期：2026-11-16。基线：main `555443265a89411c99c30b47a74937d637652bca`，已合并 PR60（`12ce6e0`）。
> 本文件只记录**本切片**实际交付与验证的事实；真实磁盘/网盘/age/加密适配器不在本切片内。

## 1. 追踪矩阵

| ID | 来源/章节 | 要求摘要 | 审批状态 | 验收条件（可观察） | 实现位置 | 测试/检查 | 状态 |
|---|---|---|---|---|---|---|---|
| REQ-M12-01 | FR-63、B-6 | 每账号 20GB；80% 告警；100% 只停 >50MB 上传，文字/小图/语音仍可发；磁盘 <10% 全停；分片 8MB、并发 ≤3 | 已批准基线 | 三档阈值行为正确、并发第 4 个被拒 | `quota.dart`（既有）、`quota_service.dart`、`sqlite_quota_store.dart` | `quota_test.dart`、`quota_store_test.dart`、`quota_service_test.dart`、`quota_sqlite_store_test.dart` | 验证通过（内存+SQLite） |
| REQ-M12-02 | FR-63、AC-14、B-6 | 视频/语音 90 天过期删 blob 留占位；到期前 7 天提醒；共享媒体其他持有者保留占位；每日 03:30 单队列；写审计 | 已批准基线 | 90 天删 blob+占位、85 天仅提醒一次、共享双方都留占位、同日幂等 | `cleanup.dart`、`sqlite_cleanup_store.dart` | `cleanup_test.dart`、`cleanup_store_test.dart`、`cleanup_sqlite_store_test.dart` | 验证通过（内存+SQLite）；真实 blob 删除待存储适配器 |
| REQ-M12-03 | FR-65、A-12、NFR-11 | 导出该用户全部数据：manifest/SHA256SUMS/会话 JSONL/记忆快照/附件索引；不含 T2 明文与 API key 明文 | 已批准基线 | 包结构完整、SHA256 行齐全、全文搜不到 T2/密钥明文 | `export.dart` | `export_import_test.dart` | 验证通过 |
| REQ-M12-04 | A-12、AC-29 | 导入支持"仅人格"/"人格+聊天记录"；先校验 SHA256SUMS；冲突不覆盖、生成新 id 并报告 | 已批准基线 | 空宿主导入数量一致；仅人格不导聊天；篡改被拒；冲突新 id | `import.dart` | `export_import_test.dart` | 验证通过 |
| REQ-M12-05 | FR-65、C-4、AC-15、NFR-11 | 离开生成删除回执（对象计数+备份轮转到期日），诚实口径"轮转后清除" | 已批准基线 | 回执含计数与 now+30d；含"轮转后清除"不含"瞬间" | `departure.dart`、`sqlite_departure_store.dart` | `departure_test.dart`、`departure_store_test.dart`、`departure_sqlite_store_test.dart` | 验证通过（内存+SQLite）；真实删除与备份轮转待适配器 |
| REQ-M12-06 | FR-64、AC-15 | 每日快照 tar+age 加密→第二块盘→可选远端；30 天轮转；恢复演练 `PRAGMA integrity_check` | 已批准基线 | 密文、30 天轮转、integrity_check=ok 留存 | 未实现（本切片外） | 未执行 | 待实现 |
| REQ-M12-07 | FR-09、分层规则 | 模块可装配、路由可挂载、migration 可登记 | 已批准基线 | 登记 5 服务、boot/shutdown 正常、migration 在 1200–1299 | `lifecycle_module.dart`、`lifecycle_migrations.dart` | `lifecycle_module_test.dart`、`lifecycle_migrations_test.dart` | 已实现未验证（路由/整机装配未接，见 §3） |
| REQ-M12-08 | FR-66、持久化 | Quota/Cleanup/Departure 三存储提供 SQLite 实现，跨重启保留，复用同一契约测试 | 已批准基线 | 内存与 SQLite 两实现通过同一契约；重启后数据仍在 | `sqlite_quota_store.dart`、`sqlite_cleanup_store.dart`、`sqlite_departure_store.dart`；迁移 1200–1206 | `*_sqlite_store_test.dart`（含跨重启用例） | 验证通过 |

## 2. 证据（自动化）

- 命令：`dart test test/quota_test.dart test/quota_store_test.dart test/quota_service_test.dart test/quota_sqlite_store_test.dart test/cleanup_store_test.dart test/cleanup_test.dart test/cleanup_sqlite_store_test.dart test/export_import_test.dart test/departure_store_test.dart test/departure_test.dart test/departure_sqlite_store_test.dart test/lifecycle_module_test.dart test/lifecycle_migrations_test.dart`
- 结果：**85 tests passed**（Dart SDK 3.14.0，2026-11-16；`m12/apps/host`；内存+SQLite 双实现）。
- `dart analyze --fatal-infos`：**No issues found**（exit 0，同一环境）。

## 3. 装配/路由补丁建议（本切片未硬改，交由 Lead 统一改）

### 3.1 `packages/jingyu_protocol/lib/src/routes.dart` 追加常量

```dart
// M12 lifecycle
static const String lifecycleQuota = '$prefix/lifecycle/quota';
static const String lifecycleExport = '$prefix/lifecycle/export';
static const String lifecycleImport = '$prefix/lifecycle/import';
static const String adminLifecycleCleanupRun = '$prefix/admin/lifecycle/cleanup/run';
static const String accountDeparture = '$prefix/account/departure';
```

### 3.2 `apps/host/lib/jingyu_host.dart`

```dart
// imports
import 'src/lifecycle/lifecycle_module.dart';
import 'src/lifecycle/lifecycle_migrations.dart';

// storage.migrations
...lifecycleMigrations,

// defaultModules 追加（放在依赖 storage/messages 之后）
LifecycleModule(clock: clock, audit: storage.auditLog),
```

### 3.3 `LifecycleModule.mount(Router)`（待路由常量合并后）

```dart
router.get(Routes.lifecycleQuota, _quotaHandler);            // principal.accountId
router.post(Routes.lifecycleExport, _exportHandler);         // 生成导出包（返回 jobId/包）
router.post(Routes.lifecycleImport, _importHandler);         // 校验+导入
router.post(Routes.adminLifecycleCleanupRun, _cleanupHandler, access: Access.admin);
router.post(Routes.accountDeparture, _departureHandler);     // 生成删除回执
```

> 处理函数都用 `principal!.accountId` 作为 owner，通过 `HostResponse.fromResult(result, (v) => v.toJson())` 输出；错误只带错误码（NFR-06/10），不返回正文或密钥。

## 4. SQLite 持久化（task-9）

- `SqliteQuotaStore` / `SqliteCleanupStore` / `SqliteDepartureStore` 均实现对应抽象接口，并各自通过 `*_store_contract.dart` 的**同一契约测试**（内存与 SQLite 双实现共用）。
- schema 由 `lifecycle_migrations.dart` 的 1200–1206 提供（quota、cleanup_log、export_jobs、deletion_receipts、quota_disk_state、媒体/提醒/占位/运行、departure_ledger）；版本段 1200–1299，未与既有编号冲突，append-only。
- `LifecycleModule` 通过构造注入接受 `QuotaService/CleanupService/DepartureService`，可在装配时用 SQLite 版 store 组合（见 `lifecycle_module_test.dart` 的 "注入 SQLite 版 store" 用例）；未修改共享 `jingyu_host.dart`/`routes.dart`。
- 为支持真实持久化，`CleanupStore.remindedAt` 由同步改为 `Future<DateTime?>`（内存实现与契约测试同步更新）；`departureStoreContract` 的 seed 回调改为 async 以适配数据库播种。改动均在本模块内，对外行为不变。
- 导出/导入的 `ExportSource`/`ImportSink` 仍为内存参考实现：真实实现需要读取其他模块（消息/记忆/附件）数据，而分层规则禁止模块互相 import 实现文件，应由装配层注入适配器。这不在本切片内。
- 未完成：备份 tar+age/远端/恢复演练（REQ-M12-06）；真实磁盘 blob 物理删除（store 已把 `blob_present` 置 0，物理删由媒体存储适配器执行）。
