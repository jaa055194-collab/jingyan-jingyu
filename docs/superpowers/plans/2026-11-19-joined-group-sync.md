# Joined Group History Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A member of a joined-history group can sync the authorized suffix and resume it after restart without reading pre-join rows or skipping real gaps.

**Architecture:** Add an optional authoritative `firstVisibleSeq` to the HTTP sync response using the same access check that limits the SQLite read. The Flutter adapter validates a page against that bound and exact conversation before committing any of it. The client shell's existing serialized snapshot advances over the hidden prefix and removes cached rows below a newer authorized bound; ordinary message ingestion remains contiguous.

**Tech Stack:** Dart host, SQLite, Flutter, existing Dart client shell snapshots.

**Spec:** [#131 workstream A](2026-11-18-project-delivery.md#L51-L54), [decisions C-1](../../architecture/02-decisions.md#c-续表答复摘要), [v4.2 FR-14](../../../鲸言鲸语-需求规格-v4.2.md#L144-L147) and [AC-18](../../../鲸言鲸语-需求规格-v4.2.md#L704). Main baseline `4d083233100797db5030a5a1931f7220842f7814` (includes #141–143).

## Global Constraints

- Keep the existing membership/history rules, HTTP route and request shape, wire frames, dependencies and on-disk snapshot shape. Legacy responses lacking the field keep their original contiguous semantics; both sides must be upgraded to recover a hidden prefix. No change to ACK, read receipts, group configuration, or app layout.
- The server is the authority for message visibility; never treat an arbitrary jump in a returned row as permission to skip history. No Android device operation.

## Review Focus

- A newly joined member's first valid message can be seq 3, not 1. Test the real authenticated host for empty/partial pages and a complete client refresh for seq 3 → 4, without ingesting hidden rows or marking other groups offline.
- A nonmember or an invalid page must not receive/apply a boundary. Test an authenticated nonmember and client pages with a bad floor, a gap, or a row for a different conversation.
- Rejoining can make older cached messages inaccessible. Test pruning even when the numeric cursor already reaches the floor, preserving unrelated conversations and not rewinding on redundant confirmations.
- A floor-only checkpoint or an interrupted checkpoint must restart at the appropriate cursor. Test a real client reopen and a storage failure without partially publishing a cursor or clearing cache.
- A legacy host and ordinary direct/all-history group stay compatible. Existing whole-suite tests and an explicit legacy no-floor page check preserve seq-1 behavior; no new outbox writes.

### Task 1 — Expose the existing authorized history bound

**Files:** `apps/host/lib/src/messages/messages_module.dart`, `apps/host/test/message_membership_boundary_test.dart`, `apps/host/test/host_test.dart`.

**Interface:** On successful `GET /api/v1/conversations/{conversationId}/sync`, return `firstVisibleSeq: int` only when the existing `HistoryMembershipCheck` returns a value greater than 1. It is the membership bound, **not** the requested/effective cursor or the first returned row. Return it even on empty pages and when the requested cursor is beyond the bound. No change to other JSON fields or to 404 behavior.

- [x] Extend the existing membership and authenticated-host tests: hidden seq 1–2, member floor 3, first page `[3]` with `hasMore: true`, next page `[4]`, empty page stays floor 3; ordinary owner page uses legacy shape. Check nonmember still sees 404 without metadata.
- [x] Observe baseline RED for absent floor, then pass the existing bound through the response and rerun both target suites.

### Task 2 — Persist the confirmed floor with the local mirror

**Files:** `packages/jingyu_client_kit/lib/src/shell_controller.dart`, `packages/jingyu_client_kit/test/shell_controller_test.dart`.

**Interface:** `Future<void> applySyncHistoryFloor(String conversationId, int firstVisibleSeq, {void Function()? checkActive})`. Require a positive floor; inside the existing serial queue, make the cursor `max(lastSeq, firstVisibleSeq - 1)`, remove only cached canonical events of this conversation below the floor, and checkpoint both. No write for no change; a failed replacement does not publish state. `acceptMessage` keeps requesting sync on gaps. Both operations take the optional `checkActive` guard inside the queue before any mutation.

- [x] Test first floor 3, then ingest seq 3 (no gap); restore a floor-only checkpoint. Test floor 4 with cursor already 4, previously cached seq 1–4 plus another group; only seq 4 remains and cursor is not rewound. A failed or superseded write must leave the before-state and allow retry.
- [x] Run dedicated tests before implementing the method, then rerun client-kit tests and analysis.

### Task 3 — Apply only validated HTTP pages in both runtime paths

**Files:** `apps/client_flutter/lib/net/host_connection.dart`, `apps/client_flutter/lib/app/runtime.dart`, `apps/client_flutter/test/runtime_joined_group_sync_test.dart`, `docs/requirements-traceability.md`.

**Interface:** `HostConnection.sync` retains its positional `accept` callback and adds optional `Future<void> Function(int firstVisibleSeq)? applyHistoryFloor` and `void Function()? checkActive`. Validate the floor, pagination flags, all frames' conversation, consecutive positive sequences and snapshot encodability before invoking callbacks. Without a floor callback, never skip a gap. Both runtime paths carry an account-generation and lock-epoch guard; unlock restarts from the durable cursor after the interrupted refresh stops.

- [x] With a synthetic loopback host and actual `ClientRuntime`, assert the joined group pages from request 0 to seq 3 then 4, stays online, fetches the ordinary group, restores from seq 4, and never sends. Test an empty first page, true gaps, cross-group rows and unpersistable pages; gate lock/unlock around a late response.
- [x] Reproduce the unsupported joined-history page and review findings, then run targeted host, client-kit and Flutter checks against the changes. Record the specific REQ-008A / AC-18 evidence; do not claim complete group ACL or device acceptance.
- [ ] Finish full checks and matched actual app Before/After on the reviewed revision.
