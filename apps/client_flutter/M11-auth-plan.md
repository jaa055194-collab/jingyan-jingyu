# M11 authenticated connection Implementation Plan

> **For agentic workers:** implement scoped tasks test-first with independent review.

**Goal:** Replace the fail-closed login placeholder with actual invitation redemption/login and identity-isolated persistence, without falsely completing room onboarding.

**Architecture:** HTTP adapter validates session payloads. Runtime switches controllers only after secure credentials are stored. Snapshot filenames are partitioned by canonical host origin, authenticated account and device. Existing guest snapshots are preserved, never attached to new credentials.

**Tech Stack:** Flutter/Dart, existing protocol paths, native protected session store; no added packages.

**Spec:** docs/modules/M11-client-shell.md rules 1–6; Issue #5; host accounts_module.dart redeem/login contract.

## Global Constraints
- PR #8 must not merge or enable auto-merge without explicit owner agreement (2026-11-15 trigger d6149728a75f4425842d9bad5f0b7c22).
- Preserve current UI visual language and all existing package interfaces except M11-local credential additions.
- No plugin installation UI: bounded-inflate security prerequisite must be verified before adding that flow (upstream #42 now contains the fix).
- Room completion remains unavailable until an actual world contract exists; no success mock.

## Review Focus
- Retrying after redeemed invite does not consume another invite when only login failed.
- Credentials/refresh token never enter ordinary snapshot JSON or error text.
- Different host/account/device never share outbox/drafts/consent.
- Invalid session payload and cleartext nonlocal connection fail before sensitive requests.
- Restoring old unscoped sessions never flushes legacy data under new credentials.

## Tasks
- [ ] HTTP auth adapter: local-server red/green tests for redeem/login payloads, validated session, malformed credentials and invite retry checkpoint.
- [ ] Persistence: red/green isolation tests for canonical host + account + device filename and preserving unrelated snapshots.
- [ ] UI: red/green credential fields (new account / existing account), password obscuring and validation; retain room-step failure semantics.
- [ ] Runtime: native secure session save first, isolated controller initialization, safe old-session handling, complete error containment.
- [ ] Verification: complete Flutter suite/analyzer, relevant kit tests (bounded inflate forged-header case included); independent security/correctness review; update draft with actual limitations.
