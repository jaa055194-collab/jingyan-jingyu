# Queued Body Container Snapshot Implementation Plan

> Authorized overnight native execution with TDD and independent review; new branch from main. No prior PR branch edits.

**Goal:** Keep queued JSON message content stable across offline retries using the same clientMsgId (FR14 reliability).

**Architecture:** OutboxItem constructor privately recursively copies/freezes map/list containers. Capture at enqueue or normal restored item construction, preserving IDs, times, attempts and restore identity. No JSON roundtrip, new body schema, serialized storage, or dependency on pending PR28.

**Compatibility boundary:** Message protocol requires JSON object trees; map/list container mutation is the defect. Preserve scalar and arbitrary noncontainer leaves by identity (existing deferred encoder validation), do not invoke toJson/coerce/drop keys. No new grammar/size/key restrictions. Memoize copies by container identity so non-JSON cycles do not overflow construction; leave encoder rejection at the existing serialization boundary. Preserve shared aliases within the detached snapshot. Immutable container access may reject mutating callers; no in-repo production caller edits queued body, and stable queued snapshot is intended reliability contract.

## Tests
- Enqueue root/nested maps/list, mutate original aliases, queue and retry remain original.
- Attempt root/nested mutation through items and Submit must throw without altering queued content; attempts remains mutable.
- Transient failure, external mutation, retry gets same original body/clientMsgId.
- Construct OutboxItem for restore captures original then restore preserves item identity/attempts/queuedAt/IDs.
- Separate queued items from same source snapshot independently; preserve null/booleans/int/double/Unicode/nested empty values.
- Preserve custom noncontainer/toJson leaf identity, no serialization at constructor; don't claim immutable custom objects or cycle JSON support.
- Recursive map/list cycle construction stays finite/detached/readonly and still fails encoding; repeated aliases retain identity within the snapshot.
- Run deterministic RED before code, client suite/analyze, independent review/full repo/finalheadCI before ready.

## Scope
No persistence, UI, account auth, queue ordering/flush policy, readonly attempts or restore deduplication. Explicitly document JSON container snapshot contract and noncontainer/cycle limitations.
