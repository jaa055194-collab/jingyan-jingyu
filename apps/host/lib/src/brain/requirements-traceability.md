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

## S1 activity citation (2026-11-15)

Baseline: main `3ac8e9f589da87fc426250f6811067f7c2d7c831`. Sources: `02-decisions.md` B-1 rules 5–6, M07 rule 2. Adds the S1 side of "may mention her own life event only with a real `activity_log` id", using a trusted injected activity source; it does not produce records (M06 life engine owns that).

| ID | Source / approval | Observable acceptance | Implementation | Evidence / status | Remaining gap |
|---|---|---|---|---|---|
| M07-S1-008 | B-1 rule 5 / M07 rule 2 | A status query with a real activity replies with its summary and carries the activity id; no record → fallback with no event claim | `activity_s1_responder.dart` `ActivityS1Responder` | `brain_activity_s1_responder_test.dart` with/without-activity tests; focused pass | Source is a trusted port; actual `activity_log` production not wired |
| M07-S1-009 | B-1 rules 5–6 | Non-status text and user-quoted events never cite an activity; padding is neutral and does no lookup; blank id/summary skipped; real router simple path S2 calls=0 and activityRefs carried | Same + existing router | quoted-event, non-status, padding, blank, and router tests; focused pass | Status-query phrase set is curated; not a general intent detector |

Verification: TDD absent-file then throwing-skeleton failures observed, then `dart test test/brain_activity_s1_responder_test.dart` 7/7 and existing brain suite 91/91; host `dart analyze --fatal-infos` clean. Exact-head CI recorded in the PR.

Deliberate limits: no activity-log production/scheduler, no default-host assembly, no model call; no full AC-33 acceptance. S1 only formats a trusted activity's summary and never asserts user/world facts or promises.
