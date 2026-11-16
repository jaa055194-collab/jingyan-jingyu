# Explicit owner–AI direct consent (social slice)

Base: verified origin/main `2df3df271a5bb3e169a2862fcca3e085b912d52b`.

## Boundary

Only the authenticated **current active human operator** may explicitly open or
revoke the direct conversation with their own active AI. Admin is not delegation.
`aiProfileId` and `aiAccountId` are distinct canonical identities. Only the fixed
human and AI account are pair members. No friendship/request is created or changed.

`scope=ownerTextOnly` declares a consent boundary for future text-only dispatch.
**This slice does not invoke a model, start a worker, enable a provider, or produce
an AI reply.** Opening creates a canonical direct pair plus explicit consent; it
is not a message/model request. Existing message APIs retain their behavior.

## HTTP contract

`Routes.ownerAiDirectConsent`:
`/api/v1/ai-profiles/{aiId}/direct-conversation`, where `aiId` is the **profile** ID.

- `GET`: no body/query; read-only metadata. Never-opened returns revision 0,
  enabled false, conversationId null **without writing a row**.
- `POST`: explicit open; JSON exactly `{"expectedRevision": <nonnegative int>}`.
- `DELETE`: explicit revoke; same exact JSON shape. Never-opened revoke is a
  default-off no-op (revision 0; no pair/grant created).
- All successful responses:
  - scope: string, always `ownerTextOnly`
  - aiProfileId: string
  - aiAccountId: string (resolved from canonical profile mapping)
  - conversationId: string or null
  - enabled: boolean
  - revision: integer
- 401: bearer invalid/revoked, or cached principal account/device mismatch.
- 404: inactive/foreign/nonhuman identity, unknown profile, blocked open.
- 409: stale expectedRevision.
- 400: invalid ID/revision, extra fields, query/body not allowed.

Consent and canonical pair creation share one transaction. No client-selected
owner/account IDs are accepted. Open/revoke audit attempts contain only revision/enabled metadata, not
text/content/credentials. Audit is post-commit, best-effort and non-atomic; an
audit failure preserves the truthful successful consent response and does not
claim a persisted audit entry.

## Revocation/history

Migration 307 adds a durable tag/grant row with enabled default 0 and revision.
Tagged revoked rows **never fall back** to the legacy friendship permission path.
Both canonical members can post only while the grant resolves enabled and all
current identity/block checks hold. The original active human retains read-only
history after revoke/transfer/block; the AI needs a current enabled grant to read
or pin that history. A new owner is not a member of the former owner's pair.
Private list/get/history and preferences use the same tagged read rule.
Human–human legacy paths are unchanged.

Triggers persistently revoke enabled grants on operator update/delete, account
disable/kind change, and block insert/update. Returning the AI, re-enabling the
account, or removing the block does not restore consent; a fresh explicit CAS
open is required. Triggers touch only the new consent table, not HH friendships.
Migration ordering is numeric: 307 supplies social schema; 505 installs profile
identity invalidation after AI identity migration 501 (including upgrade of an
existing database whose highest version is already 120x). Profile id/account
remap or deletion persists a revoke; restoring the mapping never restores the
grant. The tag deliberately has no profile FK/cascade so deleting a profile
cannot erase the tag and fall back to legacy friendship. Original human history
remains readable. Runtime resolution checks the canonical mapping on each use.

This slice changes social membership checks, not the existing messages append
transaction. A revoke returning before a **new** send request prevents that send;
an already-in-flight request may have passed canPost before revoke and finish its
append (C-5 permits up to one minute). No strict canPost/append linearization is
claimed here. Future checked append/final reply must use the same-Tx revision
fence; messages and dispatch are not expanded by this slice.

## Internal same-transaction port

`OwnerAiDirectConsent.resolveInTx(Tx, {required String ownerAccountId,
required String conversationId}) -> Future<OwnerAiDirectGrant?>` returns an
immutable ownerAccountId / aiProfileId / aiAccountId / conversationId / revision
snapshot only for the canonical active, current-owner, enabled, unblocked pair.
It is **not** a future permission token. Future dispatch must resolve again in its
final append transaction and fence the captured revision. A revision is a final
fence, not a replay/idempotency key. No dispatcher is implemented here.
