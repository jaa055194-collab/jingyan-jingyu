# Domain-aware S2 responder implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing FR-47 domain helper usable by the existing streaming brain router without importing another module's implementation.

**Architecture:** Add an M07-local S2 responder that resolves an explicitly authorized domain registry for each AI/message. It supplies the current turn's bounded domain injection to an injected generation port, or answers honestly without generation for a known domain with no card. It keeps no conversation history, registry cache or persistence path.

**Tech Stack:** Dart 3.9+, existing core IDs and test package; no new dependencies.

**Spec:** `docs/modules/M07-brain.md` rules 4/8 and AC-34; `鲸言鲸语-需求规格-v4.2.md` FR-47; `docs/architecture/01-layering.md`.

## Global constraints

- No framework/package interface changes or cross-module implementation imports.
- Domain cards are at most 500 Unicode code points for this consumer and for this turn only; no automatic network retrieval.
- No default-host/model/ACL/persistence integration or full M07 acceptance claim.
- Do not change PR #45 or PR #8 or their readiness/merge settings. Both were draft at intake; PR #45 was subsequently merged externally, and this branch was fast-forwarded to that main baseline. PR #8 remains a separate draft.

## Review focus

- A shared responder must resolve each AI/message separately; cards must not leak to another AI or conversation.
- A registry configured above 500 must not bypass FR-47 at the S2 boundary.
- Known-but-packless domains must not invoke a model that invents expertise.
- Stream errors/cancellation must not trigger retry, buffering or fabricated success.
- Simple and group-denied router paths must never start S2/domain resolution.

## Task 1: Domain-aware S2 composition

**Files:** Create `apps/host/lib/src/brain/s2_responder.dart` and `apps/host/test/brain_s2_responder_test.dart`; extend the existing M07 traceability record.

**Interfaces:** `DomainRegistryResolver = Future<DomainPackRegistry> Function(AiId, IncomingMessage)`; `S2Generation.respond(AiId ai, IncomingMessage message, {required DomainInjection domain}) -> Stream<String>`; `DomainAwareS2Responder({required DomainRegistryResolver domains, required S2Generation generation}) implements S2Responder`.

- [x] Write tests for a matching card delivered as separate ephemeral context, unknown-domain passthrough, and known-domain refusal without generation.
- [x] Run the focused test and observe absent feature failure, then a throwing skeleton's behavior failures.
- [x] Implement request-local lookup, 500-code-point cap, local unfamiliar response, and stream delegation (cancellation-aware controller after a RED pending-lookup regression exposed `async*` handoff behavior).
- [x] Add coverage for Unicode/oversized registry, sequential/concurrent AI isolation, error propagation/cancellation, and actual-router S1/S2 ordering/denied-group gating.
- [ ] Run focused brain tests, host analysis and repository `tool/check.ps1`; retain actual evidence and failures.
- [ ] Independently review, fix actionable findings, update traceability and commit/push a ticket PR. Keep it draft while checks/review are incomplete; no auto-merge.

## Self-review

The increment implements only FR-47's S2 domain-consumption seam. Existing domain matching selects one first-matching pack, not multi-domain retrieval. Trusted composition still owns current ACLs, model budget/tokenizer, memory authorization, persona and transport delivery. Supplying an ephemeral value cannot guarantee that a future generation adapter will not persist it; this contract and limitation must remain explicit. Execution proceeds natively under the existing continuation authorization, not a new product-design decision.
