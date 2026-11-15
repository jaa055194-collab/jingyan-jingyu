# Outbox Single-Flight Flush Implementation Plan

> Authorized overnight native execution and TDD; new branch from main after existing local full check finishes. Do not change prior PRs.

**Goal:** Prevent overlapping Outbox.flush calls from duplicate submitting/removing another queued item, supporting FR10/14 ordered reliable retries.

**Architecture:** Keep public signature and sequential loop policy. Add per-instance in-flight Future<FlushReport>; publish it before invoking any submit/drop callback. Joiners receive same flight/report/error and do not launch own callbacks or retry. First call owns submit/onDropped for the flight. Reset guard on completion/throw so later flush can proceed. No persistence, authentication or protocol change.

**Repro:** On old code, one gated head + two overlapping flush calls submit the same item twice; both Ok makes one remove empty index and throw. Worse, complete first call then enqueue B before stale second A success: stale removal discards unsent B. Server clientMsgId idempotence does not protect local queue corruption.

## Tests first
- Two overlapping flushes call submit for head exactly once, both receive same sent/remaining report, attempts increments once.
- Enqueue B while head pending; active first flight submits A then B exactly once, order preserved.
- Shared transient failure retains head/attempt count and no second submit callback; explicit next flush retries.
- Permanent failure invokes first onDropped once and continues; joiner's callbacks unused.
- Synchronous reentry from submit/onDropped returns active flight without invoking second callback; no deadlock if callback does not await its own outer result (document restriction).
- Submit throws sync/async: all joined callers observe same error, head retained, subsequent flush works. Dropped callback throw: already dropped item stays dropped, following item retained and later flushed.
- Empty flight resets and independent outbox instances don't block one another.
- Existing client suite preserved; new deterministic completer tests observe RED before production change; full repo+independent review/finalheadCI before ready.

## Scope
No mutable-body/restore redesign, no changes to permanent/transient failure mapping, no account/persistence/draft/Flutter integration. Reentrant callback must not await the same flight it is completing; that self-await is unsupported, not a new model/execution policy.
