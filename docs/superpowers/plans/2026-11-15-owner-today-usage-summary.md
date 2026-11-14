# Owner Today's Recorded Token Summary Implementation Plan

> **For agentic workers:** Continue authorized native implementation with TDD and an independent security/correctness review. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Provide the FR-48/58 backend slice showing an operator today's recorded AI token usage, even when model admission is blocked.

**Architecture:** Add a separate owner-scoped read service over the existing 503/504 ledger/configuration. In one transaction verify current active canonical owner/AI, read the explicitly persisted fixed offset, compute today once from the injected server clock, aggregate settled rows for that civil-day key, and separately flag unresolved usage across all days. Mount a new authenticated ModelsModule route. No metering/gateway/budget mutation, outbound call or migration.

**Tech Stack:** Dart, existing Database/Tx, BigInt decimal-text counters, Router/Pipeline, real SQLite tests.

**Spec:** v4.2 FR-48 line393 (today's per-layer usage) and FR-58 line468 (AI/capability/day quotas). Partial backend read only, not weekly trends/UI/currency/provider attribution or permission to dispatch models.

## Global Constraints
- GET `/api/v1/ai-profiles/{aiId}/usage`; aiId is the profile ID, owner comes only from current principal.
- Current bearer must match pipeline account/device; service transaction rechecks canonical active human owner and AI. Foreign, missing, transferred or disabled AI is 404, no admin bypass.
- No caller day/timezone/owner/query controls. Missing/legacy-null/invalid persisted offset returns `{configurationRequired:true}`, not a fabricated UTC day.
- Response keys: `budgetDay`, `offsetMinutes`, `recordedTokens` (decimal string), `byLayer` and `byCapability` (fixed enum-key maps of decimal strings), `sourceUsageUnknown` (all-days bool map by capability).
- Count all known rows matching existing `budget_day` semantics regardless of the row's original offset; never reinterpret historical rows or hide overage.
- Unknown is not zero: pending rows contribute flags, not estimated tokens. Exhausted budgets do not block the read.
- Aggregate with BigInt, never SQL SUM/CAST or JSON floating point. Invalid selected stored counters/enum values fail safely with internal error and no partial response.

## Review Focus
- Reassignment must not expose previous owner's ledger to the new operator; every query binds owner and profile.
- Pending usage from yesterday remains visibly unknown today.
- Fixed-offset midnight and offset changes match the existing metering day keys; settlement stays on start day.
- Counter totals beyond int64/JS safe precision and known zero stay exact.
- No request IDs, conversation/body/provider credentials or arbitrary ledger columns in response; no database mutation.

---

### Task 1: Transactional read projection and HTTP boundary

**Files:**
- Create apps/host/lib/src/models/usage_summary.dart
- Create apps/host/lib/src/models/usage_routes.dart
- Create apps/host/test/usage_summary_test.dart
- Modify apps/host/lib/src/models/models_module.dart and packages/jingyu_protocol/lib/src/routes.dart

**Interfaces:**
- `UsageSummary.forOwner({required String ownerId, required Database db, required Clock clock})`.
- `Future<Result<Map<String,Object?>>> today(AiId ai)`; configurationRequired uses existing safe failure-details convention, translated to HTTP200 by route.
- `mountUsageRoutes(Router,{required Database db,required Clock clock,required AccountsDomain accounts})`.

- [x] Write literal-path HTTP test; observe absent-route404 RED.
- [x] Add settled/empty/pending/overage, owner/AI lifecycle, timezone, exact-bigint, malformed-state, no-write and session rejection tests, plus exact-midnight/start-day settlement/second-profile isolation.
- [x] Implement the read projection and route; mount in existing ModelsModule's accounts-enabled branch.
- [x] Run focused usage/budget/model assembly regressions:40 passed; host analysis clean. Independent review reran38 and analysis, no Critical/Important. Added suggested nonblocking corrupt counter/capability cases.
- [ ] Complete final repository check and final-head CI.
- [ ] Publish a new main-based PR with explicit agent author and exact tree check. Await final-head CI before ready report. Leave PR16–21 unchanged.
