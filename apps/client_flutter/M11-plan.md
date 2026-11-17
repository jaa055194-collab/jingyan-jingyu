# M11 Flutter Client Shell Implementation Plan

> **For agentic workers:** implement scoped tasks with independent review; checklist tracks current delivery.

**Goal:** Bind the existing Dart client kernel to Android and Windows native shells and durable storage.

**Architecture:** Flutter renders onboarding, conversations and settings. Client kit coordinates durable outbox/cursor/drafts/consent; platform adapters own secure credentials and operating-system integration. Host identity is supplied by authenticated host configuration.

**Tech Stack:** Flutter 3.50 / Dart 3.14, native Kotlin and C++, existing path packages only.

**Spec:** docs/modules/M11-client-shell.md and v4.2 FR-09/11/13/18/61; Issue #5 authorization extends host identity/clientkit contracts.

## Global Constraints

- Android and Windows only; use all four requested path packages.
- Business logic in clientkit; adapters and UI in shell.
- Outbox enqueue/flush; inbound SyncCursor.accept and gap SyncRequestFrame.
- Never infer trusted host identity from platform or address.
- No third-party runtime dependencies beyond Flutter scaffold and existing packages.
- No merge. Before/After actual captures required; absent baseline application is identified honestly.

## Review Focus

- Restart after uncertain submission retains clientMsgId and avoids duplicates.
- Disk failure must not silently lose draft, queued message or cursor.
- Concurrent flushes must not submit the same queue head concurrently.
- PIN and token never persist as cleartext; failed unlock leaves content covered.
- Friend devices cannot activate host-only plugins.

## Tasks

- [ ] Clientkit: failing behavioral tests for durable outbox/retry, gap sync, consent, lock, onboarding; implement minimal controllers and run package tests.
- [ ] Host identity: failing endpoint tests for unauthenticated/friend/trusted device; add explicit configuration and authenticated response; run host tests.
- [ ] Native shell: generate with required flutter create command; capture generated application baseline; implement native platform channel adapters; compile Android and Windows.
- [ ] Flutter bindings: persistence/network adapters, shared theme/navigation, onboarding/chat/settings and error/loading/offline states; widget tests first.
- [ ] Delivery: analyze/test/build both platforms, whole-repository checks, inspect actual captures at same viewport, independent review, commit/push/PR with per-AC verification and limitations.
