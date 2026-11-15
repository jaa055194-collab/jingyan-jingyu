# Recorded Token Rolling-Seven-Day Trend Plan

> Authorized native execution, TDD and independent review. Do not alter existing PR branches.

**Goal:** A bounded multi-day recorded-token projection supporting FR-48 usage visibility, explicitly not calendar/ISO “this week”.

**Architecture:** Fresh main-based independent service and GET `/api/v1/ai-profiles/{aiId}/usage/trend`. One transaction verifies current active canonical owner/profile, reads the persisted explicit offset, samples injected clock once, and projects today plus previous six civil dates. Preserve recorded budget_day keys, not historical offset rebucketing. No migration, mutation, provider/runtime call or dependency on unmerged PR22.

**Spec:** v4.2 FR-48:393. Rolling7 is an explicit backend subset; calendar-week definition and UI are not resolved by this implementation.

## Response contract
`window: rolling7`, `basis: recordedBudgetDay`, `offsetMinutes`, `startDay`, `endDay`, `days` (seven ascending entries), `sourceUsageUnknown` (all-history flag). Each day: `day`, `recordedTokens` decimal string, `byLayer` complete B0–B4 decimal-string map, `sourceUsageUnknown` flag. Pending contributes no estimated tokens. Empty known subtotal is zero, distinguished by flags. No caller-controlled date/range/owner/offset query parameters.

## Safety constraints
- Revalidate bearer and exact principal account/device, derive owner only from current identity; no admin override. Inside transaction check active human operator, active AI/profile/canonical mapping. New owner cannot see old owner's ledger.
- Missing/legacy-null/invalid persisted offset -> configurationRequired, never default UTC. Budget exhaustion does not block usage visibility.
- Use BigInt sums/decimal-string JSON, validate canonical nonnegative counters and component totals/categories. No SQL SUM/int64 overflow or monetary claims.
- Filter known rows by seven recorded date keys; include all-history pending to preserve unknown beyond window. Settlement stays request-start day. Historical offsets remain metadata, not a filter.
- No request IDs/provider secrets/body output. No ledger/config writes. Existing DB transaction may take BEGIN IMMEDIATE lock; don't claim physically readonly transaction.

## Steps
- [x] Literal endpoint empty-window test observes404 RED.
- [x] Add seven-day/cutoff/empty/pending/exact-counter/ownership/clock/month-year/offset/settlement/corruption/no-write/session tests; single clock sample and same-owner other-profile isolation included.
- [x] Minimal service and authenticated route, mount ModelsModule; no changes to domain metering.
- [x] Focused trend14 + existing usage/budget23 + model assembly2 =39 passed, host analysis clean. Independent static review found no serious issue; reviewer did not run Dart while full verification was active.
- [ ] Complete full repository check/final-head CI.
- [ ] Explicit-agent publish/tree equality, independent PR, final-head CI before ready.
