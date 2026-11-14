# Admin Password Reset HTTP Implementation Plan

> **For agentic workers:** Follow the existing authorized native execution mode, with an independent read-only review before delivery. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Expose the existing administrator password-reset capability through authenticated HTTP, completing the FR-05 recovery entry point.

**Architecture:** Add one protocol route and a thin AccountsModule handler. Reuse AccountSession.accounts.resetPassword; do not change hashing, password policy, lockout clearing or target-device revocation. Reuse the existing bearer/principal/device comparison helper, giving it a generic name.

**Tech Stack:** Dart, existing AccountsDomain and SQLite store, host Router/Pipeline, package:test.

**Spec:** 鲸言鲸语-需求规格-v4.2.md FR-05 line 92; docs/modules/M02-accounts.md resetPassword interface. Existing domain behavior is authoritative for session invalidation; this is not a new self-service password policy.

## Global Constraints
- Administrator-only HTTP; identity derives from the current bearer, not JSON actor fields.
- Strict body: exactly one string field `newPassword`; target is the path accountId.
- Reuse existing 12–1024-character password policy, asynchronous hash and post-hash bearer revalidation.
- Never echo credentials, hashes or session tokens; no schema changes or UI.

## Review Focus
- Ordinary users, anonymous, expired/revoked tokens and spoofed cached principals cannot reset any account.
- Malformed fields, IDs and passwords produce no hash/state mutation.
- Reset preserves other users and existing admin authority, but clears target lockout and revokes target sessions as the domain already does.
- A revoked admin while hashing cannot finish the reset.
- SQLite restart retains the new credential and safe response stays free of password/hash/token material.

---

### Task 1: Reset route adapter and real-SQLite acceptance tests

**Files:**
- Modify: packages/jingyu_protocol/lib/src/routes.dart
- Modify: apps/host/lib/src/accounts/accounts_module.dart
- Create: apps/host/test/admin_password_reset_test.dart

**Interfaces:**
- Consumes: AccountService.resetPassword(AccountId id, String newPassword); domain.scope and domain.authenticate.
- Produces: Routes.adminAccountPasswordReset = `/api/v1/admin/accounts/{accountId}/reset-password`; POST body `{newPassword: string}`; successful response contains only `{reset: true}`.

- [x] Write tests using the literal intended path so missing route produces HTTP 404, not a compile failure.
- [x] Run focused tests and observe reset success expectations fail with 404 (RED).
- [x] Mount the route with Access.admin; validate current bearer/principal/device, target ID and body; invoke the existing facade.
- [x] Verify old password rejected, new password accepted, lockout cleared and target bearer/refresh invalidated; restart persistence; rejection/zero-write and in-flight revocation regressions.
- [x] Run host analysis and related account routes: 21 tests pass, including 11 reset regressions. Real hashing and DB/WAL/SHM secrecy included.
- [x] Obtain independent security review: no Critical/Important findings; reviewer re-ran reset and own-AI tests (20 passed).
- [ ] Run full repository check/CI, commit as deployment agent and open a new main-based PR; leave other PRs unchanged.
