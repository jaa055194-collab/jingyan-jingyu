# M07 bounded brain increments — requirement traceability

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

No memoization, semantic/regex meme retrieval, AI/circle authorization, model binding, B1 metering, B2 degradation, host transport delivery, UI, persistence, real activity citation or downstream memory-candidate exclusion is implemented in the S1 increment. `source=s1` is preserved by the existing router but alone does not prove a downstream memory filter. No UI changed, so visual comparison is not applicable.

## Single-turn domain-aware S2 composition (2026-11-15)

Baseline: main `cf3adfd61cb8abe21a611c3ec7dc6cce5a29936d`. Approved sources: repository FR-47, M07 rule 8 / AC-34; architecture boundary unchanged. This increment implements the existing domain helper's S2 consumer, not a concrete model adapter or complete M07.

| ID | Source / approval | Observable acceptance | Implementation | Evidence / status | Remaining gap |
|---|---|---|---|---|---|
| M07-S2-001 | FR-47 / AC-34; approved baseline | Matching card is a separate per-turn argument, at most 500 Unicode code points even with oversized registry config; next unrelated turn has no retained card | `s2_responder.dart`, `DomainAwareS2Responder` / `S2Generation` | `brain_s2_responder_test.dart`: card + chunk preservation, next turn, oversized emoji cap; focused verification passed | Concrete generator must honor untrusted reference-context placement and no persistence; no production history adapter here |
| M07-S2-002 | FR-47 unfamiliar-domain honesty; approved baseline | Known domain without a card replies honestly and does not start generation; unrecognized text passes through without a card | Same + existing registry | Known-packless and unrelated-next-turn tests; focused verification passed | Retains existing first-keyword-match semantics, not exhaustive or multi-domain detection |
| M07-S2-003 | FR-67 / architecture private-data boundary | Resolver receives current AI and complete message on every request; concurrent AI requests and same AI in distinct conversations do not reuse cards | Request-local resolver and stream state, no shared cache | Distinct AI, concurrent completion order and distinct conversation tests; focused verification passed | Resolver is a trusted authorization port, not implemented ACL enforcement |
| M07-S2-004 | FR-46 streaming S2 composition / lifecycle correctness | Preserves chunks/errors without retries; downstream cancel cancels active generator; cancel during pending lookup completes without waiting and never starts generation | Request-local stream controller and upstream subscription | Generation error, active cancel, pending-lookup cancel regressions; focused verification passed | Pending resolver Future itself is not cancellable; its eventual failure is handled. Real network/provider cancellation remains adapter responsibility |
| M07-S2-005 | M07 group gate / AC-33 composition | Existing simple and group-denied paths never start domain lookup or S2; complex path retains S1 padding then S2 pieces | Existing unchanged router + new responder | Real-router ordered chunks and gate tests; focused verification passed | Actual M04 policy/default-host assembly remains separate |

### Verification and review

- Windows x64 / Dart 3.14.0. Test-first missing-file failure followed by a throwing interface skeleton's behavioral failures; initial 11 tests passed after implementation. The skeleton run was interrupted after confirming failures because a cancellation test's teardown awaited a never-subscribed controller; test cleanup was corrected.
- Added pending-lookup cancellation regression: initial `async*` implementation failed because generation still started after cancellation. Independent review reproduced it. Replaced handoff with cancellation-aware request-local controller; 12 new tests + existing brain suite passed 103/103, host analysis clean. Added same-AI/different-conversation case and strengthened cancellation to complete before resolver settlement; final focused file passed 13/13 and host analysis clean.
- First full repository run loaded the pre-fix cancellation implementation, reproduced that regression, and was stopped rather than counted as passing. A second corrected-tree run was superseded when main externally advanced via PR #45; it was stopped, not counted as passing. The ticket branch was fast-forwarded to main `3ac8e9f589da87fc426250f6811067f7c2d7c831`, with no brain-source overlap. Final combined-tree full check is recorded in the PR / worker report when complete.
- Follow-up independent read-only review ran the final 13 tests and targeted analysis successfully; cancellation finding closed, no remaining Critical/Important findings. Static review covered pause/resume and synchronous setup errors, but these additional paths were not dynamically tested and are not counted as coverage.

### Deliberate limits

No UI, default-host assembly, provider invocation, tokenizer, memory/ACL adapter, budget wiring, domain-card persistence or network retrieval changed. Cards use the existing registry's first-match behavior. This seam keeps no history and does not persist cards; the `ephemeral` contract does not prove that a future generation adapter will honor it. A local unfamiliar-domain reply is not a full production budget policy. Concrete generation must enforce its own authoritative spend/permission checks. No real provider streaming, all AC-34 acceptance, token savings or complete AI chat product usability is claimed.
