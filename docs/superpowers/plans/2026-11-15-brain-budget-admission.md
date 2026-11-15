# Brain budget-aware reply admission implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the existing brain router honor B2-layer exhaustion and FR-58 hard-stop precedence before it spends anything on S1 padding or S2.

**Architecture:** Add an app-local, injected admission policy. A trusted per-request resolver maps the AI/conversation to a budget snapshot derived from the authenticated principal; the policy reduces the snapshot plus message complexity to `proceed | deferSlow | silent`. The router consults it after group admission and before pacing/padding/S1/S2. Existing router behavior is unchanged when no policy is injected.

**Tech Stack:** Dart 3.9+, `jingyu_core` `Result`/`Clock`; no new dependencies.

**Spec:** `docs/modules/M07-brain.md` rule 5, `鲸言鲸语-需求规格-v4.2.md` FR-48 (B2 degradation) and FR-58 (hard stop), `docs/architecture/02-decisions.md` B-5; AC-35 subset.

## Global constraints

- Trusted identity/kind comes from the resolver adapter, never from `IncomingMessage.senderId`/`inGroup`.
- A snapshot is advisory admission, not spend authorization; the existing gateway/usage meter stay authoritative and re-check atomically.
- No package/framework interface changes, no routes, schema, default-host assembly, UI or model call.
- Keep PR #46 draft; never mark this or any PR ready before the owner confirms.

## Review focus

- Simple (S1/B1) replies must still work when only B2 is exhausted.
- Hard stop must suppress replies even for a simple greeting and before any padding.
- Deferral must not invoke S1 padding, pacing, or S2, and must not become an S1 promise.
- Group denial must short-circuit before budget admission (no policy call).
- A resolver error must fail closed without leaking details.

## Task 1: Budget admission policy + router seam

**Files:** Create `apps/host/lib/src/brain/budget_policy.dart` and `apps/host/test/brain_budget_admission_test.dart`; modify `apps/host/lib/src/brain/router.dart`; extend traceability.

**Interfaces:**
- `BrainBudgetSnapshot({globalHardStop, capabilityHardStop, slowLayerExhausted, trustedOwnerPrivate})`
- `enum BrainDisposition { proceed, deferSlow, silent }`
- `typedef BrainBudgetResolver = Future<Result<BrainBudgetSnapshot>> Function(AiId, ConversationId?)`
- `abstract class BrainAdmission { Future<Result<BrainDisposition>> admit(AiId, {required ConversationId?, required Complexity}) }`
- `BrainBudgetPolicy implements BrainAdmission` (snapshot → disposition)
- `RulesFirstBrainRouter({..., BrainAdmission? admission})`

- [ ] Write failing unit tests for every boundary (normal, B2-owner-private, B2-other, B2-simple, global/capability hard stop, error propagation).
- [ ] Write failing router tests: proceed unchanged; deferSlow single `source='s2'` "稍后回" with zero S1/S2/pacing; silent no output even for greeting; group-denied never calls admission; resolver error fails closed; unsure deferral.
- [ ] Run focused tests; observe absent-feature then throwing-skeleton failures.
- [ ] Implement snapshot/policy and router seam exactly as specified.
- [ ] Run focused + existing brain tests, host analyze; then exact-head CI.
- [ ] Independent review, address findings, update traceability, commit, push, draft PR.

## Self-review

This increment covers only admission *disposition*; actual B1/B2 metering, hard-stop enforcement, canonical snapshot production and default-host wiring remain out of scope and are explicitly not claimed. The gateway remains the authoritative spend gate.
