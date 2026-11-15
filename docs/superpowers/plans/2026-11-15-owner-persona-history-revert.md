# Owner Persona History and Revert Implementation Plan

> **For agentic workers:** Implement task-by-task with test-first verification and an independent whole-branch review.

**Goal:** Let the current human operator inspect bounded persona change history and restore a selected change's before-snapshot through authenticated HTTP.

**Architecture:** Extend the existing persona module only. Keep internal `history(ai)` behavior intact; add a bounded `historyPage(ai, {afterVersion = 0, limit = 50})` read and reuse the existing transactional `revert` operation. No schema, UI, automatic iteration, memory authorization, or framework redesign.

**Tech Stack:** Dart, existing host router, SQLite, AES-GCM column cipher; no new dependencies.

**Spec:** `docs/modules/M06-ai-core.md` rule 1 and `docs/architecture/02-decisions.md` A1; FR-41 (subject to A1).

## Global Constraints

- Cross-owner access and absent resources return 404; no administrator bypass.
- Recheck bearer account/device at the HTTP boundary and current canonical ownership in the database transaction.
- Business time uses injected Clock; history remains encrypted and append-only.
- Existing `history(ai)` callers remain unchanged.
- Route paths use protocol Routes constants; no external calls or new dependencies.

## Review Focus

- Ownership transfer, disabled principals and stale tokens must not reveal previous-owner history.
- A stale expectedVersion must not overwrite a newer accepted edit.
- Revert restores the chosen before-snapshot, including undoing later content edits, while retaining the current lock.
- A bounded request must not decrypt all earlier/later history; corrupted selected data returns only a safe error.
- Malformed pagination, forged actor/owner fields, and non-content revert targets must not write history.

---

### Task 1: Bounded owner history HTTP

**Files:** `apps/host/lib/src/ai/persona/persona_service.dart`, `persona_module.dart`; `packages/jingyu_protocol/lib/src/routes.dart`; `apps/host/test/persona_http_test.dart`.

**Interfaces:** Add `PersonaHistoryPage` with immutable `changes` and nullable `nextAfterVersion`; add `historyPage(AiId ai, {int afterVersion = 0, int limit = 50})`. GET `/persona/history` accepts only `afterVersion` (>=0) and `limit` (1..100), decimal integers. Response `{changes: [...], nextAfterVersion: int|null}`; each change includes id/version/kind/actorAccountId/before/after/diff/reason/evidenceIds/at/lockedBefore/lockedAfter/revertsChangeId. Ascending version keyset pagination queries at most limit+1 rows, decrypts only returned records. Unknown/uninitialized persona is 404; end-of-history is an empty successful page.

- [x] Add real SQLite/HTTP tests for ordered pages, field fidelity, empty tail, default/bound validation, encryption, cross-owner/admin rejection, stale/mismatched identity, transfer/disable, corruption and selected-only decryption.
- [x] Run focused tests and observe missing-route 404 failures.
- [x] Implement bounded service read and route without changing existing unbounded history behavior.
- [x] Run focused and existing persona regression tests.

### Task 2: Owner CAS revert HTTP

**Files:** same persona module, protocol routes, HTTP tests; default host assembly test.

**Interfaces:** POST `/persona/revert` accepts exactly `{changeId: String, expectedVersion: int>=1, reason: String}`; invokes existing `revert(ai, changeId, expectedVersion:, reason:)`; response uses existing current-card shape. Selected change belongs to the exact owner/AI. Initialize/lock targets cannot revert; repeat/no-op/stale conflicts remain existing service behavior.

- [x] Add failing HTTP tests for reverting selected content with later edits, lock retention, append-only history, stale/concurrent CAS, wrong owner/AI targets, invalid input, initialization/lock targets, corrupted history and persistence after reopen.
- [x] Observe missing route failing before implementation.
- [x] Add route using existing validation/authentication and transactional service.
- [x] Run focused tests and default-host assembly route regression.
- [ ] Run full `tool/check.ps1`, independent review, update REQ-020/status with actual evidence and limitations, inspect final diff, commit, push, open PR, and follow CI.
