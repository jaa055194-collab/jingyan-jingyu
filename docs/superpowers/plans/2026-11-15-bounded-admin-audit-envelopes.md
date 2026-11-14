# Bounded Administrator Audit Envelope Read Plan

> Authorized native execution with TDD and independent security review. Keep all earlier PRs unchanged.

**Goal:** Deliver the FR-07 backend slice for administrator audit visibility without exposing metadata, credentials or historical message bodies.

**Architecture:** New AdminAuditModule and bounded read service over existing audit_log. Register module in default host, no schema or AuditLog writer-interface changes. Inside one database transaction validate the current credential against canonical device/account/admin state and the pipeline account/device, then SELECT only envelope columns with bound cursor/limit. Do not nest AccountsDomain transaction calls inside a Database transaction.

**Spec:** v4.2 FR-07:99–101; NFR audit privacy. Decisions A8 historical old-body access remains a separate route and is NOT completed or redefined by this envelope-only slice.

## Wire contract
GET `/api/v1/admin/audit?afterId=0&limit=50`, Access.admin. Allowed query fields exactly afterId/limit. afterId canonical nonnegative decimal <= signed-int64 maximum; limit integer1–100. Response `{entries:[{id,at,actorId,action,targetKind,targetId}],nextAfterId,hasMore}`. id/nextAfterId are decimal strings to avoid browser precision loss. Ordered ascending id, exclusive afterId cursor, at most limit rows plus one lookahead. Never SELECT/decode meta, joins to version bodies, payloads or secret fields.

## Constraints and review focus
- Live same-Tx device access_hash/account/device/expiry + active human admin authorization; compare expected principal account/device. Invalid/stale/mismatched credentials401. Nonadmin rejected by Pipeline403 and canonical service check. Do not rely on cached isAdmin.
- Hash bearer only, no logging/exposing plaintext. No audit-entry/domain writes (normal outer Pipeline auth may touch device last_used_at).
- No schema/migration/writer behavior changes, global metadata filtering/sorting beyond id, deletion/retention, unbounded scans or content hydration.
- Revalidate canonical authority within same serialized Tx as SELECT to close pre-read revocation gap; bound query is LIMIT+1.
- Default host route and module must actually be registered; update exact module-list assembly expectation.

## Tasks
- [x] Literal-path default-host test observes404 RED.
- [x] Add realSQLite/HTTP pagination/largeID/secrecy/auth/revocation/restart/invalidquery/no-write tests, disabled/demoted/missing-refresh/expired-refresh and real authenticated default-host coverage.
- [x] Implement small service/module/constants/default registration, without account/audit writer refactor.
- [x] Focused audit read11 + default-host2 + storage/accounts regressions =32 passed, host analysis clean.
- [ ] Full repository checks and independent security review.
- [ ] Explicit-agent new branch publish/tree check, separatePR and final-headCI before ready.
