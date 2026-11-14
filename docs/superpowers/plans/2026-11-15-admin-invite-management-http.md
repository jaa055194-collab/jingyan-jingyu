# Administrator Invite Metadata and Revocation HTTP Plan

> **For agentic workers:** Use the authorized native execution mode, TDD and independent security review. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Complete FR-05 invitation management transport by exposing the already-implemented metadata and revoke capabilities.

**Architecture:** Add GET to the existing admin invite collection and POST to a shared invite-revoke path. Reuse AccountSession.inviteMetadata and session.invites.revoke; do not change invitation generation, storage, expiry/count semantics or redemption transaction. Begin on main aa90767, independent of PR16–20.

**Tech Stack:** Dart Router/Pipeline, AccountsDomain, existing SQLite store, package:test.

**Spec:** 鲸言鲸语-需求规格-v4.2.md FR-05 (expires/maxUses/usedCount/revokedAt and one-time codes); docs/modules/M02-accounts.md InviteService.revoke. Existing public service behavior, not new product policy.

## Global Constraints
- GET `/api/v1/admin/invites` is Access.admin and uses adminInvitesPath override for mounting.
- POST `/api/v1/admin/invites/{inviteId}/revoke` is Access.admin, no entity body; reject parsed body, nonzero/malformed Content-Length and Transfer-Encoding.
- Bind current bearer to principal account/device; facade independently revalidates current administrator authority.
- Metadata contains only id, expiresAt, maxUses, usedCount, revokedAt. Timestamps stay UTC epoch milliseconds; plaintext code and digest remain absent.
- No migration. Repeated revoke preserves existing timestamp-overwrite behavior; no retroactive cancellation of completed registrations.

## Review Focus
- Neither listing nor revocation may leak the one-time code, hash, tokens or arbitrary injected fields.
- Anonymous/nonadmin/stale or mismatched principal requests fail without invite/account mutation.
- Revocation during in-flight password hashing prevents the redemption commit; no sleeps in test.
- Real HTTP null body framing must not bypass bodyless revoke validation.
- List retains expired/exhausted/revoked entries; revocation persists across restart without changing counts or unrelated invites.

---

### Task 1: Thin HTTP exposure with lifecycle and race tests

**Files:**
- Modify packages/jingyu_protocol/lib/src/routes.dart (Routes.adminInviteRevoke).
- Modify apps/host/lib/src/accounts/accounts_module.dart (GET list, POST revoke; reuse live-session helper).
- Create apps/host/test/admin_invites_http_test.dart.
- Document accounts README / requirements traceability.

**Interfaces:**
- Consumes AccountSession.inviteMetadata() and InviteService.revoke(String).
- GET returns existing list directly; successful revoke returns `{revoked:true}`.

- [x] Write HTTP list/revoke tests using literal desired routes; observe both missing route HTTP 404 RED.
- [x] Verify issue/list exact allowlist/types/secrecy, revoke/list/redeem404/unrelated invite and restart.
- [x] Add deterministic revoke-during-hash test and metadata state preservation cases.
- [x] Cover anonymous/nonadmin/stale/mismatched principal and strict body/ID rejection including real null framing.
- [x] Implement minimal adapters without modifying domain/store/migrations.
- [x] Run focused regressions: invite9 + own-AI9 + accounts_routes1 =19 passed; host analysis clean.
- [x] Independent security review of HTTP/session/domain/SQL/transport and tests: no concrete Critical/Important issue. Reviewer did not duplicate tests while the full run was active; test-pass evidence is the lead's focused run.
- [ ] Complete local full repository check and final-head CI.
- [ ] Commit/publish with explicit deployment-agent author, create separate main-based PR, await final-head CI and report ready. Leave earlier PRs unchanged.
