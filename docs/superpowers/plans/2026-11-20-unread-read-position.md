# Unread Counts and Read Position Plan

**Goal:** Each conversation shows how many messages arrived since the user last read it, and opening a conversation marks it read locally and reports that position to the existing host ack route. Nothing is marked read without an explicit open, and no unread state is invented when it is unknown.

**Baseline:** main `e7fdf7d968ca5b358529dffc4321205acf02aff2` (after merged #148/#149/#150).

## Current state

- The host already exposes `POST /conversations/{conversationId}/ack` with `{seq}` and clamps to the head; `message_acks` is keyed by `(conversation, device)`.
- The client never calls it: there is no ack request anywhere under `apps/client_flutter/lib/net`.
- `ClientShellController` persists per-conversation sync cursors and cached messages but has no "last read" position, and `ShellConversation.unread` is always 0.

## Interfaces

Client only; reuse the existing host route, no host or protocol change.

- `ClientShellController`: add a persisted `readSeq` map (defaults to the restored cursor when absent is wrong — see below), `int readSeqFor(String id)`, `Future<void> markRead(String id, int seq, {void Function()? checkActive})`. `markRead` advances only forward, never past the cached head, writes through the existing shared snapshot writer once (no schema change; it is another top-level key inside the existing `shell` section), and publishes memory only after the checkpoint succeeds. A failed write keeps the previous position.
- `ShellConversation.unread`: computed by the runtime as the number of cached canonical messages in that conversation with `seq > readSeqFor(id)` and `seq >= firstVisibleSeq`. Unknown/absent cursor with no cached messages shows 0 rather than a guess. Outbox and dropped rows never count.
- `ClientRuntime`: when the user selects a conversation (explicit action) and the session is authenticated, unlocked, online and the conversation is the current selection, send one ack for the visible head after the local `markRead` succeeds, using `Routes.messageAck`; a failure is silent (no retry loop) and never blocks reading. Switching away, locking or logging out before the request completes discards the result.
- No background polling, no WebSocket, no server-computed unread, no push notifications.

## Tests

1. Shell controller: `markRead` advances only forward, clamps to head, persists once, survives restart, a failed checkpoint keeps the old value, and it is rejected while another operation is cancelled by `checkActive`.
2. Runtime: unread counts derive from cached messages above the read position; opening a conversation marks read and sends exactly one ack with the visible head; ack failure does not surface an error or retry; lock/logout/conversation switch during the ack does not write or publish.
3. Widget: the conversation list shows the count and clears after opening; a conversation with no cached messages shows no badge.
4. Existing shell/runtime suites still pass.

## Limits

Local unread only: another device's reads are not reflected until it syncs its own cursor, and the host does not compute unread. No WebSocket, no cross-device read receipts, no notification integration. This is a partial AC-18 and does not claim it.
