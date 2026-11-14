# M02 requirements and verification

Baseline: Issue #4; docs/modules/M02-accounts.md; architecture decisions C-4 and v4.2 FR-04–07. Read 2026-11-13. Production integration consumes M01 PR #6 at a1ad4e7; no M01 implementation changes belong to the M02 diff. Necessary host/protocol/IP wiring directly implements the requested replacement. No arbitrary-principal production issuance remains.

Environment: Windows x64, Dart 3.14.0, cached crypto 3.0.8 / sqlite3 2.9.4, offline dependency resolution. Final frozen-source bare `dart test`: 97 passed, 0 failures (12m43s); host analysis clean. Each requirement below is verified on this delivery tree.

| ID | Source | Acceptance | Implementation | Verification evidence | Status |
|---|---|---|---|---|---|
| M02-001 | AC-02a | 20 concurrent redeems yield exactly maxUses successes | AccountsDomain.redeem, atomic store commit | Shared memory + SQLite acceptance and HTTP AC tests passed | 验证通过 |
| M02-002 | AC-02b | Expired, revoked and exhausted invites fail | _usableInvite / commit recheck | Shared memory + SQLite acceptance and HTTP AC tests passed | 验证通过 |
| M02-003 | AC-02c | Five failures lock account 15 minutes, including correct password | Optimistic login with current-state counter | Shared memory + SQLite AC, HTTP lockout and six concurrency regressions passed | 验证通过 |
| M02-004 | AC-02d | Third login invalidates least recently used device bearer immediately | _register + DbAuthenticator | Shared memory + SQLite acceptance and HTTP AC tests passed | 验证通过 |
| M02-005 | AC-02e | Remote revocation invalidates bearer on next request | Scoped device revoke + current store lookup | Original memory AC and actual host HTTP revoke passed | 验证通过 |
| M02-006 | FR-04 | Human operator mandatory, other humans cannot manage AI | Scoped account facade + relational ai_operator | Shared memory + SQLite FR-04 and SQL relationship tests passed | 验证通过 |
| M02-007 | FR-07 | Admin metadata omits injected message content and credentials | Explicit metadata allowlist, Access.admin | Actual host test inserts known private message and checks host/admin accounts HTTP responses; passed | 验证通过 |
| M02-008 | Rules 1 / acceptance | No plaintext passwords, invites or tokens in store | PasswordHasher / SHA-256 / SQL adapter | Actual SQLite/database WAL/SHM raw-byte scans passed before/after close/restart; memory snapshots exclude secrets; SQL rejects unhashed credentials | 验证通过 |
| M02-009 | C-4 / rule 4 | First initialization creates the only administrator | Trusted init_accounts script, unique DB admin index, protected admin disable | Singleton behavioral red then green; actual init script first success / second conflict passed | 验证通过 |
| M02-010 | Dependency / migrations | Executable 100–199 migrations and SQLite persistence | accountsMigrations version100, SqlAccountsStore.start | SQL restart, schema, bindings, rollback and shared store contract:10 passed | 验证通过 |
| M02-011 | FR-05 | IP + account + invitation rate limits use trusted transport IP | AccountsRateLimiter + socket remoteAddress + redeem route | Two limiter tests, peer copy test and actual HTTP spoofed-header test passed | 验证通过 |
| M02-012 | Routes | Login/refresh/devices/revoke/admin enforce access | AccountsModule + shared Routes constants | Public redeem/login/devices/revoke/refresh HTTP AC and admin authorization passed | 验证通过 |
| M02-013 | Password hashing | Salted PBKDF2-HMAC-SHA256 >=600000 rounds | PasswordHasher (fallback: no usable offline pure Dart Argon2id available) | Six hash tests passed, including independent Unicode known vector; six async race/responsiveness regressions passed | 验证通过 |

| M02-016 | v4.2 FR-05 / M02 InviteService.revoke | Admin HTTP metadata list and revoke delegate to existing scoped facade, omit one-time code/digest, retain epoch-ms types and existing lifecycle | GET adminInvitesPath; POST Routes.adminInviteRevoke; AccountsModule._invites/_revokeInvite | List and revoke HTTP-404 RED; admin_invites_http_test 9 real-SQLite/HTTP cases + own-AI/accounts_routes regression (19 passed), host analysis clean; full-tree CI tracked separately | 局部验证通过；无新schema或邀请策略 |

M02-016 tests cover metadata's exact five-field allowlist, revoke/redemption denial and restart persistence, unrelated invite usability, retained expired/exhausted/revoked states, existing repeated timestamp update, anonymous/nonadmin/stale and mismatched principals, no-write malformed body/ID rejection, deterministic revocation during password hashing with no new account/count write, actual HTTP fixed-length/chunked JSON null rejection and configured collection-path compatibility. One-time invite codes remain issue-only.

Final checks: four support packages resolved offline, analyzed cleanly and passed20/9/10/11tests. Host `dart analyze --fatal-infos` clean and final bare `dart test`97passed/0failed. Real-file credential persistence, public HTTP acceptance, device revocation and spoofed-header GET/POST all included. One-time administrator script first success/second conflict also verified. Independent read-only review found no serious remaining defect.

Implementation limits: account state loads are O(total accounts/devices/invites) per transaction, appropriate for the specified small circle. Password workers are limited to two active isolates. Local fixed-window admission defaults30 requests/minute per dimension; account lockout persists in SQLite. Access expires after1h, refresh after30d and rotates on every use. Names1–100 characters, human passwords12–1024 characters. Administrator possession of the host still permits technical data access; metadata filtering does not claim cryptographic invisibility.
