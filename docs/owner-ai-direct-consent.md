# Explicit owner–AI direct consent (social slice)

Base: verified origin/main `2df3df271a5bb3e169a2862fcca3e085b912d52b`.

## Boundary

Only the authenticated **current active human operator** may explicitly open or
revoke the direct conversation with their own active AI. Admin is not delegation.
`aiProfileId` and `aiAccountId` are distinct canonical identities. Only the fixed
human and AI account are pair members. No friendship/request is created or changed.

`scope=ownerTextOnly` explicitly permits reactive replies to newly accepted owner text in this exact private pair. Opening only creates the pair and consent: it does not send content, start a worker or enable a provider. The integrated observer uses rules-first routing: exact curated simple input gets local S1; complex/unsure input may use the owner's explicitly configured model only when the trusted model worker, persona, binding and budget are available. Simple unsupported input stays silent. No group, history, memory, third-party source or attachment is assembled into a model prompt. A plain owner text can of course contain pasted information; the host does not claim to identify its authorship.

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

The default host uses a tagged-only checked append: current grant, canonical pair, collision exclusion, message insertion and accepted-at consent-revision stamp share one SQLite transaction. If revoke commits first, a subsequent tagged append is denied. Legacy untagged human/group posting remains governed by the existing boundary. Only fresh exact owner text receives a source stamp; retries cannot retroactively approve old input or replace its revision.

A reply attempt claims `(source message, AI profile)` permanently before work; grant revision is a fence, not a retry key. The observer reloads unedited/unrecalled canonical text, rejects extra metadata and checks the accepted-at stamp. Model calls run outside transactions; final publication rechecks source, identity, current binding and the exact grant revision, then appends the AI reply and completes status in one transaction. Revoke/transfer/edit/recall or re-open during generation discards the stale result. An already transmitted prompt cannot be unsent; the final check prevents publication, not historical network transmission. Runtime settles actual usage even for discarded or oversized output.

## Internal same-transaction port

`OwnerAiDirectConsent.resolveInTx(Tx, {required String ownerAccountId,
required String conversationId}) -> Future<OwnerAiDirectGrant?>` returns an
immutable ownerAccountId / aiProfileId / aiAccountId / conversationId / revision
snapshot only for the canonical active, current-owner, enabled, unblocked pair.
It is **not** a future permission token. The dispatcher resolves it again in its final append transaction and fences the captured revision. A revision is a final fence, not a replay/idempotency key.

## Status and failure semantics

`GET /api/v1/conversations/{conversationId}/messages/{messageId}/owner-reply` returns only owner-visible metadata: `notAttempted`, `pending`, `completed`, `failed` or `discarded`, plus safe IDs/failure enum where present. It never returns source text or provider prose. Original active owners retain status history after consent/profile changes. `notAttempted` means no ledger row, not eligibility or a promise of generation.

Delivery is best-effort, at-most-one attempt per source/profile, not a durable retry queue. Provider errors leave safe failed status and preserve the runtime's unknown-usage reconciliation; crashes can strand pending attempts. No automatic retry or completion cache exists. The client may sync the accepted input even when no reply is generated. Input/output byte caps are engineering resource limits, not exact tokenizer/model-context or strict cost guarantees. This bounded path does not replace ContextualChat or claim full FR-46/48 acceptance.

The new attempt and source-stamp ledgers contain metadata only. Existing enabled trusted creative generators remain unrelated; default creative generation stays disabled.
