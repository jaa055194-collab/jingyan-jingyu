# M07 rules-only S1 increment — requirement traceability

Source baseline: repository v4.2 FR-46, `docs/architecture/02-decisions.md` B-1/B-5 and `docs/modules/M07-brain.md`, read 2026-11-15. This records a bounded implementation increment, not completion of M07 or the entire AC-33.

| ID | Source | Requirement / status | Acceptance | Implementation | Check / evidence | Gap |
|---|---|---|---|---|---|---|
| M07-S1-001 | FR-46 simple transactions; B-5 rule fallback | Approved baseline; implemented, focused verification passed | Known standalone greeting/ack/emoji receives a short social reaction without model access | `s1_responder.dart`, `RulesS1Responder` | `brain_s1_responder_test.dart`: 22 table-driven direct cases; greeting through real router, S2 calls=0 | Caller must select/inject responder; no automatic `chat.fast` health/budget wiring |
| M07-S1-002 | B-1 rules 5–6; M07 rules 2–3 | Approved baseline; implemented, focused verification passed | No activity log bound: no claimed life event, no activity references; unknown/action/factual text gets neutral follow-up, no input echo or promises | Same | Direct cases for watering plants, meals, weather, action request, synthetic private text; padding adversarial cases | Does not cite real activity records; trusted activity adapter deferred |
| M07-S1-003 | FR-46 optional padding; B-1 routing | Approved baseline; implemented, focused verification passed | Complex and unsure inputs receive neutral S1 padding then S2; disabling padding leaves S2 only | Existing unchanged router + new responder | Real-router ordered pieces, source markers, complex/unsure, disabled-padding tests | No model-backed S2 or default-host assembly |
| M07-S1-004 | M07 rule 4 | Approved baseline; composition verified | Denied group emits no S1/S2 pieces | Existing unchanged router and injected policy | Real-router denied-group test | Does not supply actual M04 policy adapter |

## Verification record

- Baseline revision: `1c60bb43dc4f615d1cb2925218035f0d192e21c4`; Windows x64, Dart 3.14.0.
- TDD: focused test first failed to load the absent implementation; after adding a throwing interface skeleton, 25 behavior tests failed with `UnimplementedError` while the two unchanged-router gate paths passed. After implementing the curated reactions, `dart test test/brain_s1_responder_test.dart` passed 27/27; with two additional quoted/embedded greeting cases it passed 29/29.
- Repository `tool/check.ps1`: `ALL CHECKS PASSED`, exit 0; analysis clean in all five packages; tests passed: core 20, protocol 9, host kit 10, client kit 133, host 717 (original 27-case focused file loaded in that run; two final additive cases passed in the separate 29-case run). Final revision is recorded in the PR; this is not a full-product acceptance claim.

## Deliberately not claimed

No memoization, semantic/regex meme retrieval, AI/circle authorization, model binding, B1 metering, B2 degradation, host transport delivery, UI, persistence, real activity citation or downstream memory-candidate exclusion is implemented here. `source=s1` is preserved by the existing router but alone does not prove a downstream memory filter. No UI changed, so visual comparison is not applicable.

## Budget-aware reply admission (2026-11-15)

Baseline: main `3ac8e9f589da87fc426250f6811067f7c2d7c831`. Sources: FR-48 (B2 degradation), FR-58 (hard stop), M07 rule 5, decisions B-5. This adds admission *disposition only*; the gateway/usage meter remain the authoritative spend gate.

| ID | Source / approval | Observable acceptance | Implementation | Evidence / status | Remaining gap |
|---|---|---|---|---|---|
| M07-BUD-001 | FR-48 B2 / M07 rule 5 | Normal budget proceeds; B2 exhausted still allows trusted owner-private slow replies | `budget_policy.dart` `BrainBudgetPolicy` | `brain_budget_admission_test.dart` normal + owner-private cases; focused pass | Snapshot is advisory; authoritative B2 metering unchanged |
| M07-BUD-002 | FR-48 / M07 rule 5 | B2 exhausted defers non-owner slow replies to a single `source=s2` "稍后回" with no padding/pacing/model (pacing enabled in test); simple S1 replies unaffected end-to-end | Policy + `RulesFirstBrainRouter.respond` seam | deferral (enabled pacing), unsure, and real-policy router-level simple-unaffected tests; focused pass | Friend/group distinction supplied by trusted resolver, not implemented here; `deferSlow` is canned text, not model output, and needs a distinct downstream marker |
| M07-BUD-003 | FR-58 hard stop | Global/capability hard stop is `silent` for every complexity (including simple) and overrides the owner exception, before any padding | Policy + router | silent simple/complex and capability (simple+complex) override tests; focused pass | Actual hard-stop detection and enforcement remain gateway/usage responsibilities |
| M07-BUD-004 | M07 group gate / fail-closed | Group denial short-circuits before admission; resolver `Err` or thrown exception yields no reply and no model call | Router ordering + `valueOrNull` fail-closed; `BrainBudgetPolicy` try/catch | group-first, `Err`, and thrown-resolver tests; focused pass | Trusted identity derived by adapter, not message fields |

Verification: TDD absent-file then throwing-skeleton failures observed (`1 passed, 13 failed` with skeleton), then `dart test test/brain_budget_admission_test.dart` 17/17 and existing brain suite 91/91; host `dart analyze --fatal-infos` clean. Review-driven hardening added an enabled-pacing deferral assertion, router-level simple-unaffected and simple+capability tests, thrown-resolver fail-closed, and a `deferSlow` output-contract note. Exact-head CI recorded in the PR.

Deliberate limits: no B1/B2 metering, no canonical snapshot production, no default-host wiring, no model/budget hard-stop enforcement, no UI; no AC-35 full acceptance claim. Trusted resolver must avoid trusting `senderId`/`inGroup`.
