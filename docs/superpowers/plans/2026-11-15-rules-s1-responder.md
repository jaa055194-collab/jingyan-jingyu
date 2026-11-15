# Rules-only S1 Responder Implementation Plan

> **For agentic workers:** Execute the checked steps natively and obtain an independent whole-diff review before delivery.

**Goal:** Supply the existing brain router with a concrete offline S1 responder for greetings, acknowledgements and safe conversational follow-ups.

**Architecture:** Implement only `S1Responder` in `apps/host/lib/src/brain/s1_responder.dart`. Use a small curated, anchored template set; unmatched text gets a neutral follow-up rather than a fabricated fact. Padding is independent of message content. No model, activity-log, memory, transport or default-host wiring is added.

**Tech Stack:** Dart 3.9+, existing core and test dependencies; no new dependencies.

**Spec:** `docs/modules/M07-brain.md` rules 2–3; `docs/architecture/02-decisions.md` B-1/B-5; v4.2 FR-46 simple transactions and rule-only fallback (read 2026-11-15).

## Global Constraints

- Do not change `packages/*`, host assembly, existing responder signatures or module responsibilities.
- S1 must not assert facts about the user/external world, make promises or invent its own life events.
- Output remains `source=s1` through the existing router; no memory or history write path exists in this responder.
- No third-party dependencies; no direct clock/network/storage use.
- Full host module, real models, budget enforcement, activity citation, meme retrieval and UI are explicitly outside this increment.

## Review Focus

- Embedded or quoted greetings must not turn a factual request into a greeting; test exact/anchored matching.
- Unicode emoji and punctuation must not break matching or exceed the 30-code-point short-response budget; test consumer output.
- Padding must not echo private input or arbitrary strings; test malicious/factual input.
- No activity record means no watering-plants or other claimed event; test a life-event question and empty references.
- Real router must keep simple responses out of S2 while questions/unsure still reach S2 and group denial suppresses output; integration tests.

## Task 1: Concrete rules responder and router composition

**Files:** Create `apps/host/lib/src/brain/s1_responder.dart`; create `apps/host/test/brain_s1_responder_test.dart`; create `apps/host/lib/src/brain/requirements-traceability.md`.

**Interfaces:** `class RulesS1Responder implements S1Responder`; `const RulesS1Responder()`; `Future<S1Reply> replyTo(AiId ai, IncomingMessage message, {required bool padding})`. Existing ports are unchanged.

- [x] Write tests for greetings (`你好`, case-insensitive standalone `Hello!`), acknowledgement (`收到`), emoji (`👍`), neutral fallback for unknown/embedded/factual input, neutral padding, empty activity references and <=30-code-point output. Assertions exercise replies, not template source text.
- [x] Run `dart test test/brain_s1_responder_test.dart` in host and observe missing responder failure before implementation.
- [x] Implement curated anchored templates, input trimming, a neutral fallback and content-independent padding. Do not interpolate user input.
- [x] Test real `RulesFirstBrainRouter` composition: greeting only S1; question padding then S2; padding disabled only S2; unsure reaches S2; denied group gets no output.
- [x] Run focused tests, host tests, and repository `tool/check.ps1`: all five packages analyzed without issues; tests passed (core 20, protocol 9, host kit 10, client kit 133, host 717). Final two quoted-input tests also passed in the separate 29-test focused run.
- [x] Obtain independent read-only review and resolve valid findings (final review: no blockers; explicit quoted-greeting cases added).

After verification, commit and create a review-ready PR with limitations and requirement mapping. A human merges.
