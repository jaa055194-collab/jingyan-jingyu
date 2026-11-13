# M01 · storage：SQLite、加密列、迁移

> 依据：v4.2 FR-62/64/66、NFR-01/06/07/11。依赖：system。

## 目标

给所有模块一个统一的持久化底座：一个 SQLite 文件、按版本号顺序执行的迁移、正文与 T2 的加密列、事务。

## 允许新增的依赖

- `sqlite3`（pub.dev，FFI 绑定）。不要用 ORM。

## 要写的文件

```text
apps/host/lib/src/storage/
  storage_module.dart      StorageModule：name 'storage'，dependsOn ['system']
  database.dart            abstract class Database（见下）
  sqlite_database.dart     SqliteDatabase implements Database
  migrations.dart          List<Migration> allMigrations；Migration(version, name, sql)
  cipher.dart              abstract class ColumnCipher + AesGcmColumnCipher
  key_provider.dart        abstract class KeyProvider + DpapiKeyProvider（Windows）+ EnvKeyProvider（测试）
apps/host/test/storage_test.dart
```

## 接口（照抄签名）

```dart
abstract class Database {
  Future<T> transaction<T>(Future<T> Function(Tx tx) body);
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> args = const []]);
  Future<int> execute(String sql, [List<Object?> args = const []]);
  Future<int> schemaVersion();
  Future<String> integrityCheck(); // 返回 PRAGMA integrity_check 的结果，'ok' 为通过
}

abstract class Tx {
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> args = const []]);
  Future<int> execute(String sql, [List<Object?> args = const []]);
}

abstract class ColumnCipher {
  /// 返回 `v1:` + base64(nonce|ciphertext|tag)。同一明文两次加密结果不同。
  String encrypt(String plaintext, {required String aad});
  Result<String> decrypt(String sealed, {required String aad});
}
```

## 规则

1. 所有 SQL 用参数绑定，禁止字符串拼接用户输入。
2. 迁移按 `version` 升序执行，每个迁移一个事务；已执行的版本记录在 `schema_migrations` 表。迁移文件只追加，不改已发布的迁移。
3. 启动时 `PRAGMA journal_mode=WAL`、`PRAGMA foreign_keys=ON`。
4. 加密：AES-256-GCM，96-bit 随机 nonce；`aad` 传 `表名:列名:行id`，防止密文被挪到别的行。
5. 数据加密密钥（DEK）由 KEK 包裹后存 `key_store` 表；KEK 在 Windows 上用 DPAPI 保护。明文密钥只在内存（NFR-06）。
6. 迁移 1 只建 `schema_migrations`、`key_store`、`audit_log` 三张表。其余表由各模块在自己的迁移里建，编号见 `migrations.dart` 顶部注释的分段（M02 用 100–199，M03 用 200–299，依此类推）。
7. 登记服务：`Database`、`ColumnCipher`。
8. 写一个 `SqliteAuditLog implements AuditLog`，替换 system 模块的内存实现。

## 验收

- [ ] M01-1 空目录启动后自动建库，`schemaVersion()` 等于最新迁移号。
- [ ] M01-2 重复启动不重复执行迁移。
- [ ] M01-3 迁移中途失败时该迁移回滚，版本号不前进。
- [ ] M01-4 `transaction` 内抛错时整体回滚。
- [ ] M01-5 加密往返一致；改一个字节或换 aad 解密失败；同明文两次密文不同。
- [ ] M01-6 数据库文件里搜不到明文（写入一条加密正文后，按字节搜原文找不到）。
- [ ] M01-7 `integrityCheck()` 在正常库上返回 `ok`。
- [ ] M01-8 `SqliteAuditLog` 通过与内存实现相同的行为测试。
