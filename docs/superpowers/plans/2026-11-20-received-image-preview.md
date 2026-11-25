# Received Image Preview Plan

**Goal:** A chat member can explicitly open an image attachment that was sent in a message they are allowed to see. Nothing is fetched automatically, nothing is written to disk, and no new transport or dependency is introduced.

**Baseline:** main `058dbf3275ecfec721edf08537782a802aabae41` (after merged #147; #148 is a separate in-flight PR touching only lifecycle files). Source authority: #131 R2 "附件在聊天内真能选、发、看", v4.2 FR-62 subset, AC-20/AC-32 not claimed.

## Findings this slice must respect

- The host has no byte-serving route at all: `GET /attachments/{id}` returns metadata only, `rel_path` is used only by delete, and `HostResponse`/`HostConnection` are JSON-only.
- `getAttachment` authorizes by conversation membership only, so a member who joined later can read metadata of pre-join attachments, and a recall leaves the row readable. A byte route must therefore be **message-scoped**, not id-scoped.
- `_edit` accepts an arbitrary body without re-running `assertSendable`, so a message could reference another member's attachment id. The content route must require `attachment.owner_account_id == message.senderId`.
- `width/height` are never populated and uploads allow 128 MiB, so bytes and decoded pixels must be bounded, and only raster image MIME types are allowed (no SVG).
- Chat currently renders only `SelectableText(message.text)`; there is no attachment UI and no content API.

## Interfaces

Host (module `messages`):

- `Routes.messageAttachment = '$prefix/conversations/{conversationId}/messages/{messageId}/attachment'` (GET, authenticated).
- `MessageStore.read({required String conversationId, required String messageId}) -> Future<Result<StoredMessage>>` in the interface, `InMemoryMessageStore`, and `SqliteMessageStore`; missing/cross-conversation is `notFound`.
- `AttachmentService.readImageContent({required String attachmentId, required String conversationId, required String senderId, int maxBytes = 8 MiB}) -> Future<Result<AttachmentImageContent>>` with `{mime, size, sha256, bytes}`. Rejects: unknown id, `conversation_id` mismatch, owner != sender, MIME not in `image/png|jpeg|gif|webp|bmp`, declared size over cap, missing blob, actual length != declared. Never returns a path or `extractedText`.
- Handler order: validate ids → `canRead` → `firstVisibleSeq` non-null and `message.seq >= floor` → `store.read` → reject missing/recalled/non-image → validate `body['attachmentId']` → `readImageContent` → JSON `{mime, size, sha256, dataBase64}` with `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`. All authorization/missing failures are a uniform 404; malformed ids are 400.

Client:

- `ShellMessage` gains `attachmentId`, `attachmentKind`, `attachmentName` (all nullable, default null), populated by the runtime projection **only for canonical synced messages**, never for outbox/dropped rows.
- `AttachmentApi.readMessageImage({required String conversationId, required String messageId}) -> Future<MessageImage>` validates: strict JSON keys, base64 decode length equals `size`, `size <= 8 MiB`, SHA-256 of decoded bytes equals `sha256`, MIME in the raster allowlist, and no `extractedText`/path fields.
- `ShellViewModel.openImageAttachment(String messageId) -> Future<MessageImage?>` (default null) with a runtime implementation that rechecks authenticated/unlocked/online/selected conversation/generation before and after the fetch and returns null instead of throwing on a stale context.
- `ChatPane` renders an image message as a filename tile with an explicit **查看图片** action; tapping fetches and opens a modal showing `Image.memory` with bounded `cacheWidth`/`cacheHeight` and an `errorBuilder`; closing evicts the image cache entry. Lock/logout/conversation switch during the fetch discards the result. No disk write, no auto-fetch on sync.

## Tests

Host (real SQLite/AES/temp media): owner and post-message member 200 with exact bytes; joined-late member 404; non-member/anonymous 404/401; recalled 404; text message 404; attachment from another conversation 404; attachment owner != sender (forged edit) 404; deleted blob 404 not 500; oversize and non-image MIME rejected; response has no `extractedText`, owner id or path; headers set. `MessageStore.read` contract in both stores.

Client: API strict parsing/cap/MIME/SHA mismatch/404 mapping/401 renewal; runtime exposes refs only for canonical messages, no request before tap, stale lock/switch discards, no file writes; widget tile + dialog + honest failure, no auto-fetch.

## Ownership

- Host: `packages/jingyu_protocol/lib/src/routes.dart`, `apps/host/lib/src/messages/{message_store.dart,sqlite_message_store.dart,attachments.dart,messages_module.dart}`, host tests.
- Client: `apps/client_flutter/lib/net/attachment_api.dart`, `lib/app/{runtime.dart,shell_view_model.dart}`, `lib/features/chat/chat_pane.dart`, client tests.
- Lead: integrate, run full Flutter/root checks, both debug builds, matched production Before/After, independent review, focused PR. No teammate commits or remote operations.

## Limits

Base64 JSON transport is deliberately bounded to one 8 MiB image and is not a general file/download channel. No document open/save, no video/audio playback, no pre-join access, no admin content access, no device/native acceptance. FR-62 "可看" is only partially covered (images in a message the viewer may read).
