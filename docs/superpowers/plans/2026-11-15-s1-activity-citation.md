# S1 activity-citation responder implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the M07 S1 fast brain answer a status question with the AI's own recent activity — citing real `activity_log` ids — only when such a record exists (B-1 rule 5), and never fabricate one.

**Architecture:** Add an `ActivityS1Responder` decorator over the existing `S1Responder` port. On a status-query message it asks an injected trusted activity source for the AI's recent activities (newest first); if a valid record exists it replies with a short templated line and carries the record id in `activityRefs`; otherwise it delegates to a fallback. Padding always delegates.

**Tech Stack:** Dart 3.9+, existing `jingyu_core`; no new dependencies.

**Spec:** `docs/modules/M07-brain.md` rule 2 and `docs/architecture/02-decisions.md` B-1 rules 5–6; AC-33 ("S1 回复里提到的生活事件都能在 activity_log 找到；没有记录时不提").

## Global constraints

- An S1 life-event mention is allowed only with a real activity id from the injected source; no record → no claim.
- S1 makes no user/world factual assertion or promise; `activityRefs` carries ids; `source=s1` via the existing router.
- No router/framework/package interface change, no persistence, no network, no default-host wiring.
- PR #46–#48 stay draft; never mark a PR ready before the owner confirms.

## Review focus

- Status query with no activity must not mention any event (the classic "没有记录不提浇花").
- User-supplied text must not be turned into a life-event claim.
- Padding stays neutral and never does an activity lookup.
- Empty/blank activity ids or summaries are ignored.
- Router carries `activityRefs` onto the outgoing piece; simple path skips S2.

## Task 1: ActivityS1Responder + tests

**Files:** Create `apps/host/lib/src/brain/activity_s1_responder.dart` and `apps/host/test/brain_activity_s1_responder_test.dart`; extend traceability.

**Interfaces:** `S1Activity({required String id, required String summary})`; `typedef S1ActivityLookup = Future<List<S1Activity>> Function(AiId ai)`; `ActivityS1Responder({required S1ActivityLookup activities, S1Responder? fallback}) implements S1Responder`.

- [x] Write failing tests: status query with activity cites id+summary; no activity → fallback, no claim; non-query → fallback without lookup; padding neutral with no lookup; user-quoted event not claimed; blank id/summary skipped; real-router simple path S2 calls=0 and activityRefs carried.
- [x] Observe absent-file then throwing-skeleton failures.
- [x] Implement the decorator (whole-phrase status match; lookup fail-soft; freshness note).
- [x] Run focused + existing brain tests, host analyze, then exact-head CI.
- [x] Independent review, fix findings (quoted-phrase guard, fail-soft, blank-then-valid, reachability doc+test), update traceability, commit, push, draft PR.

## Self-review

This provides the S1 side of B-1 rule 5 using a trusted activity source; it does not produce `activity_log` records (M06 life engine owns that), scheduler, or default-host assembly. No full AC-33 acceptance claim.
