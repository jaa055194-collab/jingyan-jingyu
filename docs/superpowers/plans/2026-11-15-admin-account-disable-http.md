# Administrator Account Disable HTTP Implementation Plan

> **For agentic workers:** Continue the authorized native implementation mode with TDD and an independent read-only review. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Expose FR-07 account disabling through a thin admin-only HTTP adapter to the existing scoped AccountService.disable.

**Architecture:** Add a protocol route and an AccountsModule handler, reusing existing current-bearer/account/device matching. Do not change domain policies: disabling a human or AI removes that account's devices, is repeatable, and cannot disable the single administrator. No schema changes or re-enable/delete workflow.

**Tech Stack:** Dart, Router/Pipeline, AccountsDomain, existing SQLite account store, package:test.

**Spec:** 鲸言鲸语-需求规格-v4.2.md FR-07 (administrator operations include disabling); docs/modules/M02-accounts.md AccountService.disable. Passwords, ownership and target-account semantics are unchanged.

## Global Constraints
- POST `/api/v1/admin/accounts/{accountId}/disable`, Access.admin, target identity only in the path.
- No request body; malformed IDs or bodies return 400. Anonymous/stale credentials return 401, ordinary users 403.
- Resolve authority from the current bearer and verify principal account and device agree. Delegate to the existing scoped facade.
- No content or credential material in success response; return `{disabled: true}` only.
- Existing administrator-protection conflict and immediate target-device revocation are preserved, not invented as new policies.

## Review Focus
- An ordinary human cannot use this admin route even to disable their own AI (the separate domain capability remains unchanged).
- A cached administrator principal cannot substitute another account's bearer or a different device.
- Only target devices/refresh credentials disappear; unrelated people, administrator and AI ownership mappings remain unchanged.
- Unknown account returns 404; protected administrator returns 409; repeated disable remains successful.
- SQLite restart retains disabled state and revocation; UI, account deletion, re-enable and audit browsing are excluded.

---

### Task 1: Strict disable adapter with real-SQLite lifecycle regressions

**Files:**
- Modify: packages/jingyu_protocol/lib/src/routes.dart
- Modify: apps/host/lib/src/accounts/accounts_module.dart
- Create: apps/host/test/admin_account_disable_test.dart
- Document: apps/host/lib/src/accounts/README.md and requirements-traceability.md

**Interfaces:**
- Consumes AccountService.disable(AccountId) and current domain.scope/domain.authenticate checks.
- Produces Routes.adminAccountDisable and POST handler with standard safe failure envelopes.

- [x] Write successful human-disable test using a literal desired path and observe HTTP 404 RED.
- [x] Implement route registration, live session identity matching, empty-body and path parsing, facade delegation.
- [x] Verify disabled state, access/refresh/held-scope invalidation, unrelated users unaffected and restart persistence.
- [x] Verify AI target, nonadmin/anonymous/stale/mismatched principals, invalid bodies/IDs, unknown/protected targets and idempotence.
- [x] Run account regressions (19 pass) and host analysis. Review found raw JSON null bypass; real-socket fixed-length/chunked test observed RED then GREEN after a route-local framing guard. Earlier full repository run passed before this guard; final-head CI is required for the final tree.
- [x] Complete follow-up independent review: original raw-null finding resolved; reviewer independently reran disable 9 + own-AI/account route 10, host analysis and diff checks clean; no remaining serious findings.
- [ ] Final full-repository CI.
- [ ] Publish a new main-based PR with explicit deployment-agent authorship; await final-head CI before ready report. Leave PR16–19 unchanged.
