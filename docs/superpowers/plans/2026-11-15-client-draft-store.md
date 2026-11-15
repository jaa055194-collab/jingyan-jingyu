# Client draft store implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide a pure-Dart, account- and conversation-scoped input draft store for the M11 client, so a shell can persist drafts and survive conversation switching / restart (AC-32, v4.2 line 142).

**Architecture:** Add `DraftStore` + immutable `ConversationDraft` to `jingyu_client_kit` (UI-free, Flutter-free). Drafts are keyed by (accountId, conversationId); empty/whitespace text clears; a versioned JSON snapshot supports atomic import with validation and leaves existing data untouched on corruption. The shell owns encrypted persistence; this package provides the in-memory model and snapshot only.

**Tech Stack:** Dart 3.9+, `jingyu_core` `validateId`; no new dependencies.

**Spec:** `鲸言鲸语-需求规格-v4.2.md` line 142 (草稿保护：按会话持久化，切换/重启不丢失), AC-32; `docs/modules/M11-client-shell.md`.

## Global constraints

- No Flutter import; logic stays in client_kit.
- Account isolation: one account's drafts are never visible to another.
- Snapshot import validates fully and commits atomically; a corrupt snapshot must not erase current drafts.
- No shared documentation files edited (avoid overlap with the in-flight M07 draft PRs); traceability recorded in the PR body and this plan.

## Review focus

- Whitespace-only drafts clear rather than persisting a blank entry.
- Import of a duplicate conversation id or invalid id fails closed.
- Snapshot round-trips Unicode and preserves updatedAt to UTC.
- `clearAccount` touches only the target account.
- list ordering is deterministic.

## Task 1: DraftStore + tests

**Files:** Create `packages/jingyu_client_kit/lib/src/draft_store.dart` and `packages/jingyu_client_kit/test/draft_store_test.dart`; add export in `packages/jingyu_client_kit/lib/jingyu_client_kit.dart`.

**Interfaces:** `ConversationDraft({conversationId, text, updatedAt})`; `DraftStore()` with `save(String accountId, String conversationId, String text, {required DateTime updatedAt})`, `draft`, `draftText`, `hasDraft`, `drafts`, `clear`, `clearAccount`, `exportAccount`, `importAccount`.

- [ ] Write failing tests for the behaviors above.
- [ ] Observe absent-file then throwing-skeleton failures.
- [ ] Implement the store.
- [ ] Run `dart test test/draft_store_test.dart`, package analyze, then exact-head CI.
- [ ] Independent review, fix findings, commit, push, draft PR.

## Self-review

This is the client-side data model for AC-32 drafts; it does not implement encrypted disk persistence, UI, or draft syncing across devices (server/shell responsibility). No full AC-32 acceptance claim.
