# M01 Storage Implementation Plan

> **For agentic workers:** Execute the test-first tasks below in this ticket; independent review follows implementation.

**Goal:** Implement M01 SQLite persistence, sequential transactional migrations, encrypted columns, protected KEK/DEK and persistent audit.

**Architecture:** Keep the existing Database/Tx and AuditLog consumers unchanged. StorageModule supplies Database/ColumnCipher and an AuditLog instance injected into SystemModule at assembly (the service container rejects duplicate registration). Windows CNG provides AES-GCM and DPAPI without adding an unapproved crypto dependency.

**Tech Stack:** Dart, sqlite3 2.x FFI, Windows BCrypt/DPAPI.

**Spec:** docs/modules/M01-storage.md (repository baseline, read 2026-11-13).

## Global Constraints

- Only sqlite3 may be added as a direct dependency; no ORM, no packages/* interface changes.
- All caller values use bound parameters; migration SQL is trusted static module code.
- Migration 1 creates only schema_migrations, key_store, audit_log; append-only versions.
- WAL, foreign_keys, 96-bit random nonces, AES-256-GCM and table:column:row AAD.
- KEK is DPAPI-protected; only a wrapped DEK is persisted in key_store.
- Windows tests run offline after dependency setup; no download during test execution.

## Review Focus

- Concurrent async operations must not enter another transaction; rolled-back writes stay absent.
- Failed migrations leave earlier versions intact and never advance the failed version.
- Corrupted envelope/KEK must fail closed rather than silently replace keys.
- Audit queries filter both target kind and ID and preserve insertion order/scalar metadata.
- Reopening must reuse the same DEK and decrypt previous ciphertext.

### Task 1: Database and migrations

Files: storage/database.dart, storage/sqlite_database.dart, storage/migrations.dart; test/storage_test.dart.
Interfaces: Database/Tx exactly as specified; SqliteDatabase.open(path, migrations), close().

- [x] Write failing M01-1/2/3/4/7 tests for nested directory creation, migration ordering/retry, rollback, WAL/FK and concurrency.
- [x] Run tests and confirm missing implementation failures.
- [x] Implement a serialized connection, transaction-scoped Tx and transactional version tracking.
- [x] Run relevant tests green.

### Task 2: Windows cryptography

Files: storage/cipher.dart, storage/key_provider.dart; test/storage_crypto_test.dart.
Interfaces: ColumnCipher exactly as specified; AesGcmColumnCipher(List<int> key); KeyProvider supplies a 32-byte KEK.

- [x] Write and run failing known-vector, M01-5, DPAPI persistence/corruption tests.
- [x] Implement Windows BCrypt AES-GCM and DPAPI protected persisted KEK; injectable EnvKeyProvider for tests.
- [x] Verify tests offline on Windows.

### Task 3: Envelope, audit and assembly

Files: storage/storage_module.dart, storage/sqlite_audit_log.dart; host dependency manifest and assembly; test/storage_audit_contract.dart, test/storage_test.dart.
Interfaces: StorageModule name storage dependsOn system; audit object injected into existing SystemModule constructor; Database and ColumnCipher registered by storage.

- [x] Write and run failing M01-6/8 and module lifecycle/reopen tests; run same audit contract for memory and SQLite.
- [x] Implement wrapped persistent DEK, lazy-start lifecycle, persistent audit and local defaultModules wiring without changing framework APIs.
- [x] Verify no plaintext in database/WAL/KEK and roundtrip across restart.
- [x] Run full repository check, offline host suite, independent review; fix issues and repeat affected checks.
- [x] Commit and create PR with M01-1 through M01-8 evidence; no merge.
