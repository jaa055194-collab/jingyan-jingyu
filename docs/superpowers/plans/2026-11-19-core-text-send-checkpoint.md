# Core Text Send Checkpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a single explicit plain-text send durable without leaving the already-queued text behind as a sendable draft after restart.

**Architecture:** Keep the existing per-account shell snapshot and outbox ID/flush semantics. Stage the new item and consume only the matching draft in one serialized snapshot replacement; publish the in-memory transition only when the replacement succeeds. The Flutter runtime invokes that operation and clears only the captured draft revision.

**Tech Stack:** Dart, Flutter, existing JSON snapshot storage and client outbox.

**Spec:** [#131 roadmap, package A and Review Focus](2026-11-18-project-delivery.md) and [v4.2](../../../鲸言鲸语-需求规格-v4.2.md) FR-10, FR-13, FR-14, AC-18, AC-32. Baseline: `main` e43cde7, which already includes #130 happy-path readback and #134 owner AI entry.

## Global Constraints

- Android + Windows; no new dependency, snapshot schema, wire contract or visual change. Android device acceptance is handled separately.
- Preserve existing outbox IDs, FIFO, per-account/conversation isolation and ordinary enqueue/mention/plug-in behavior. Do not deduplicate by text.

## Review Focus

- A crash between the old writes can restore an already-queued draft. T1 checks that no such snapshot is written and restart restores one queue ID.
- A storage error must not leak a provisional message into a later flush. T1 asserts no new item or submission and a retry with one ID.
- A later edit, even with the same text, must remain visible and durable. T1 gates the pending write and updates the composer while it waits.
- Sending in one conversation must not alter another conversation's draft. T1 asserts that an unrelated durable draft survives both restart and retry.
- Repeated intentional sends of identical text require distinct IDs. T1 queues both offline before reconnecting.
- A synchronous listener must not enqueue Send before the corresponding edit is queued. T1 invokes Send from the first draft notification, then reselects the chat and reads the snapshot.

### Task 1: Atomically checkpoint a plain-text draft

**Files:** `packages/jingyu_client_kit/lib/src/outbox.dart`, `packages/jingyu_client_kit/lib/src/shell_controller.dart`, `apps/client_flutter/lib/app/runtime.dart`, `apps/client_flutter/test/runtime_text_send_test.dart`, `docs/requirements-traceability.md`.

**Interfaces:** `ClientShellController.enqueueTextDraft(String conversationId, String text)` serializes the transition with `saveDraft` and `flush`. The package-internal `OutboxCheckpoint.enqueueWithCheckpoint` extension stages an item with the existing allocator and appends it only after the checkpoint completes. The snapshot remains compatible with existing readers.

- [x] Add Flutter runtime tests around a controllable snapshot store and loopback host. Assert that Send never writes a split state, reboot restores the same ID and no original draft, write failure retains the draft without queuing or submitting, and re-entered text can be sent separately with a distinct ID.
- [x] From `apps/client_flutter`, run `flutter test --no-pub test/runtime_text_send_test.dart -r expanded`. Observe the split write, remaining item after failure, and lost new draft revision on the original implementation. Verify the listener ordering regression fails separately before fixing it.
- [x] Stage the draft transition via the interfaces above. Preserve different drafts and only clear the runtime view while its generation, selected conversation and captured draft revision still match. Schedule the originating draft save before notifying listeners. Keep generic `enqueue` unchanged.
- [x] Rerun the regressions and complete Flutter suite and analysis. Run the repository checks and the final changed client-kit package checks. Independently review the diff and record the verification boundary in the traceability matrix.
