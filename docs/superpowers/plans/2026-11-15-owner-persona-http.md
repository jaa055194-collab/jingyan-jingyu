# Explicit Owner Persona Management HTTP Plan

> **For agentic workers:** Use authorized native execution, TDD and independent security review; keep previous PRs unchanged.

**Goal:** Expose the already implemented persona card initialization/read/manual-edit/lock capabilities for its current human operator.

**Architecture:** Add a focused PersonaModule and route adapter wrapping SqlitePersonaService, register existing append-only migration601 unchanged in default host assembly. No AI self-iteration or memory authorization endpoint. Only explicit supplied complete P0/P1/P2 initializes a card; reads never create defaults. Existing A1 (decisions override v4.2) and service CAS/lock/history semantics remain unchanged.

**Tech Stack:** Dart, current AccountsDomain/SqlitePersonaService, SQLite/AES-GCM column cipher, Router/Pipeline.

**Spec:** v4.2 FR41, docs/modules/M06-ai-core.md, docs/architecture/02-decisions.md A1 (P0/P1 lockable, P2 autonomous).

## Constraints
- Current bearer/account/device match; human actor and owner both derive from current authenticated account, never payload. Canonical ownership/active AI checked again by existing service in each Tx. No admin bypass.
- POST /ai-profiles/{aiId}/persona/initialize exact {p0,p1,p2} nonempty string maps; GET /persona current safe card {aiId,version,locked,layers}; PATCH /persona exact {expectedVersion,reason,diff:{p0?,p1?,p2?}}; PUT /persona/lock exact {expectedVersion,locked}.
- expectedVersion positive integer for mutations; return changed card via change.after and its version/lock, no extra re-read race. No model actor/evidence, owner override, auto initialization or arbitrary stored history exposure.
- History rows remain encrypted and append-only through the existing service. Export current card only, not a memory export. Size bound for initialize/edit is the reference adapter1MiB JSON limit; route strictly rejects unknown keys/types.
- Ownership reassignment does not silently migrate/re-encrypt existing personas; existing service safe notFound/conflict behavior is retained and documented.
- Register601 in composition root; update explicit migration/module-list assembly tests. Do not rewrite published SQL.

## Review Focus
- Cross-owner/admin/AI/disabled/transferred actors denied before returning card text; stale bearer/principal device mismatch401.
- Default host routes and migration actually available, not only test-only opt-in assembly.
- No read creates cards; explicit initialize duplicates409, stale edit/lock409, invalid empty-layer deletion400 without history mutation.
- P0/P1 lock does not block owner's manual edit; no AI self-iteration route or model credentials created.
- Cipher corruption500 without partial card, encrypted DB/history no plaintext, restart persists, mutation uses service CAS.

## Tasks
- [x] Write real default-host anonymous route test; observe404 RED before module.
- [x] Add real-SQLite owner initialization/read/patch/lock tests and auth/CAS/corruption/restart regressions, payload/expiry and AI-impersonation tests; authenticated default production module smoke test included.
- [x] Add minimal new module/routes, register existing601 and shared route constants, adjust assembly expectations.
- [x] Run focused persona/account/assembly tests:38 passed, host analysis clean; independent static security/correctness review no Critical/Important (no independent Dart execution).
- [ ] Complete final full repository checks and final-head CI.
- [ ] Publish separate main-based PR with explicit agent author/tree verification; final-head CI before ready. No UI/visual evidence needed.
