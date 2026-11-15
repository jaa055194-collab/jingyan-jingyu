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

## Meme-aware S1 responder (2026-11-15)

Baseline: main `3ac8e9f589da87fc426250f6811067f7c2d7c831`. Sources: FR-46 (S1 接梗) and FR-47 (梗库), AC-34 (meme hits). Wires the existing `MemeLibrary` into the existing `S1Responder` port via a decorator; no router/interface change.

| ID | Source / approval | Observable acceptance | Implementation | Evidence / status | Remaining gap |
|---|---|---|---|---|---|
| M07-S1-005 | FR-46 接梗 / FR-47 | An active meme hit is replayed as the S1 reply (empty activityRefs); personal beats general; simple hit answered by S1 with S2 calls=0 | `meme_s1_responder.dart` `MemeS1Responder` / `MemeLibrary` | `brain_meme_s1_responder_test.dart` hit/layer/router tests; focused pass | Regex/keyword matching only (optional semantic matcher not injected here); memes must be curated |
| M07-S1-006 | FR-46/47 expiry + short bound | Expired memes are not used (Clock); padding stays neutral even on a match; over-long reply clamped to 30 Unicode code points without splitting a scalar | Same | expiry, padding, Unicode clamp tests; focused pass | Authoring must keep meme replies short/safe; clamp only caps length |
| M07-S1-007 | AC-33 compose / safe fallback | No hit or empty text falls back to curated rules; complex question uses neutral padding then S2 | Same + `RulesS1Responder` fallback | no-hit, empty, and real-router complex tests; focused pass | No default-host assembly or model `chat.fast` health wiring |

Verification: TDD absent-file then throwing-skeleton failures observed, then `dart test test/brain_meme_s1_responder_test.dart` 9/9 and existing brain suite 91/91; host `dart analyze --fatal-infos` clean. Exact-head CI recorded in the PR.

Deliberate limits: no semantic/embedding retrieval wiring, no persistence, no network, no default-host assembly, no full AC-34 acceptance. S1 replays curated memes only and does not assert user/world facts or promises.
