# Message Edit Attachment Integrity Plan

**Goal:** An edited message cannot introduce or keep a reference to an attachment the editor may not send, and attachment text extraction is only returned to the attachment's owner. This closes two documented gaps without changing the message format.

**Baseline:** main `6174d6a59a70bb2aba143b9ff7989095b2162082` (after merged #148; #149 is a separate in-flight PR touching messages/attachments, so this branch starts from main and will be rebased before publication if #149 lands first).

## Findings

- `MessagesModule._edit` passes an arbitrary body to `MessageStore.edit` with no attachment validation, so a sender can edit a text message into `{attachmentId: <someone else's id>}`. The message-scoped content route added in #149 rejects it because the attachment owner must equal the message sender, but the forged reference still renders a filename tile and leaves inconsistent data.
- `AttachmentService.getAttachment` returns decrypted `extractedText` to any conversation member who can read the attachment's conversation. That is content, not metadata, and it also ignores the history floor. The client deliberately drops it, but the host still discloses it.

## Interfaces

Host only:

- `MessagesModule._edit`: after the existing id/`canPost`/body-shape checks and before `_store.edit`, if the new body contains `attachmentId`, require it to be a `String` and call the existing `AttachmentService.assertSendable(ownerAccountId: principal.accountId, attachmentId: id, conversationId: conversationId)`; any failure is the existing uniform `notFound`. If `_attachments` is null and an `attachmentId` is present, return `internal` exactly as `_send` already does. A body without `attachmentId` keeps today's behavior, and an edit that removes a reference stays allowed.
- `AttachmentService.getAttachment`: add `bool includeExtractedText` (default `false`) and only decrypt/populate `extractedText` when the caller is the attachment's owner **and** the flag is true. Keep every other metadata field and the existing not-found behavior unchanged. `AttachmentsModule._get` passes `includeExtractedText: true` only for the owner path, so members keep metadata and owners keep text; do not add a new route.
- Do not change recall, delete, upload, sync, message payload or the client in this slice.

## Tests

Host, real SQLite/AES/temp media:

1. Edit a text message into a foreign `attachmentId` → `notFound`, stored body unchanged, no edit row.
2. Edit into a non-`String` `attachmentId` → `invalidArgument`, unchanged.
3. Edit into the editor's own attachment uploaded to the same conversation → success (keeps the useful path working).
4. Edit that removes the attachment reference → success.
5. Owner `GET /attachments/{id}` still returns `extractedText`; a member of the conversation gets the same metadata with no `extractedText` and no decryption error.
6. Existing message-edit and attachment suites still pass.

## Limits

No change to attachment upload/abort, message format, sync payload or the Flutter client. Owners keep their extracted text; other members keep metadata only. This does not add document preview, retention or admin content access, and does not claim AC-19 or AC-20.
