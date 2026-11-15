# Meme-aware S1 responder implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the M07 S1 fast brain reply with an active meme hit (FR-46 接梗 / FR-47 梗库) before falling back to curated rules, without touching the router or any framework interface.

**Architecture:** Add a `MemeS1Responder` decorator that implements the existing `S1Responder` port. It consults an injected `MemeLibrary` with an injected `Clock` for expiry; on a hit it returns the meme's short reply (clamped to 30 code points); otherwise it delegates to a fallback (default `RulesS1Responder`). Padding always delegates so it stays neutral.

**Tech Stack:** Dart 3.9+, existing `jingyu_core` `Clock` and M07 `MemeLibrary`; no new dependencies.

**Spec:** `docs/modules/M07-brain.md` (S1 接梗 / rule 3), `鲸言鲸语-需求规格-v4.2.md` FR-46/FR-47, AC-34 (meme hits).

## Global constraints

- S1 output stays `source=s1` via the existing router, has empty `activityRefs`, and makes no user/world factual assertion or promise.
- Memes are curated (product/user/AI-approved); S1 only replays them, never generates.
- No router/framework/package interface change, no persistence, no network, no default-host wiring.
- PR #46/#47 stay draft; never mark a PR ready before the owner confirms.

## Review focus

- Expired memes must not be used (Clock drives `isActiveAt`).
- Padding must remain neutral even when a meme matches.
- A long meme reply must not break the ≤30-codepoint S1 expectation and must not split a Unicode scalar.
- No meme / empty text must fall back to the existing curated behavior.
- Router path must still skip S2 for a simple meme hit.

## Task 1: MemeS1Responder + tests

**Files:** Create `apps/host/lib/src/brain/meme_s1_responder.dart` and `apps/host/test/brain_meme_s1_responder_test.dart`; extend traceability.

**Interfaces:** `MemeS1Responder({required MemeLibrary memes, required Clock clock, S1Responder? fallback, int maxReplyChars = 30}) implements S1Responder`.

- [ ] Write failing tests: active hit, expired miss→fallback, no-hit→fallback, padding neutral, Unicode-safe 30-codepoint clamp, empty text, real-router S1-only + activityRefs empty.
- [ ] Observe absent-file then throwing-skeleton failures.
- [ ] Implement the decorator.
- [ ] Run focused + existing brain tests, host analyze, then exact-head CI.
- [ ] Independent review, fix findings, update traceability, commit, push, draft PR.

## Self-review

This wires existing tested pieces (MemeLibrary, RulesS1Responder) into S1. It does not implement semantic/embedding matching (uses the library's existing regex/keyword + optional injected matcher), meme retrieval wiring/budget, or default-host assembly. No full AC-34 acceptance claim.
