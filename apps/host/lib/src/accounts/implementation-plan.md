# M02 Accounts Implementation Plan

> **For agentic workers:** Execute the tasks below with test-first checks and an independent whole-branch review.

**Goal:** Replace static authentication with accounts, invitations, revocable device sessions and a single administrator.

**Architecture:** Actor-scoped account services use an accounts store; the in-memory store serializes transactions. The production adapter consumes M01 Database/Tx once available. Authentication always resolves current device/account state.

**Tech Stack:** Dart 3.14, crypto, package:test; Windows offline test execution.

**Spec:** docs/modules/M02-accounts.md, docs/modules/README.md and v4.2 FR-04–07.

## Global Constraints

- Invitations and tokens are stored only as sha256; passwords use Argon2id or PBKDF2-HMAC-SHA256 at least 600000 iterations.
- Device limit 2; evict least recently used and immediately revoke both session credentials.
- Five consecutive bad passwords lock the account for 15 minutes.
- M02 migrations use 100–199; SQL parameters must be bound.
- Administrator output contains only metadata; exactly one administrator, initialized outside public routes.
- No production fake storage or legacy arbitrary-principal token issuance.

## Review Focus

- Concurrent redemption must not overspend invitations or leave orphan accounts on failure.
- Refresh rotation must reject replay and remote revocation must reject all credentials.
- Account lockout and disabled/operator accounts must not permit session creation.
- Wrong-account device access must disclose no device metadata.
- Administrator metadata must not leak passwords, tokens or injected message content.

### Task 1: Password hashing

Files: apps/host/lib/src/accounts/password_hasher.dart; apps/host/test/password_hasher_test.dart; apps/host/pubspec.yaml.

- [x] Write failing tests for salted round trips, wrong password and malformed hashes.
- [x] Run red, implement safe PBKDF2 encoding and constant-time verification, run green offline.

### Task 2: Accounts store and actor-scoped services

Files: apps/host/lib/src/accounts/{accounts_store,account_service,invite_service,device_service,db_authenticator}.dart; apps/host/test/{accounts_test,accounts_store_contract}.dart.

Interfaces: AccountService/InviteService/DeviceService match M02 signatures; store transactions are serialized and commit atomically. Services enforce caller identity via actor-scoped facades.

- [x] Add failing acceptance tests AC-02a–e, FR-04/07 and store contract tests.
- [x] Implement account/operator/invitation/session lifecycle and hashed-only persistence boundary.
- [x] Run focused tests offline and review concurrency/revocation behavior.

### Task 3: Production integration

Files: accounts_module.dart, accounts_migrations.dart, SQL accounts store adapter; necessary approved host assembly, route constants and trusted peer-IP plumbing.

- [x] Confirm original authorization context for framework integration and consume M01 interfaces.
- [x] Add failing host login/revocation/admin and trusted-IP tests.
- [x] Replace static issuance fixtures with real account/device fixtures; initialize administrator through script.
- [x] Apply migrations 100–199 and pass identical store contract on SQLite and memory implementations.

### Task 4: Delivery

- [x] Run offline analysis/tests for all packages and inspect full diff.
- [x] Independent review; fix verified findings and rerun affected checks.
- [x] Maintain per-AC evidence in M02 requirements matrix and PR body.
- [ ] Commit as configured account, push ticket branch and open PR, bind immediately.
- [ ] Deliver ready only after complete validation; otherwise label useful partial draft honestly.
