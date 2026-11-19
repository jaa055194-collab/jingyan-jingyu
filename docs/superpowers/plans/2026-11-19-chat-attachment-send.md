# Chat Attachment Send Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed-in member can choose one local image or file in the chat, explicitly upload it to the current conversation, and send the resulting attachment message with the normal retryable outbox path.

**Architecture:** Reuse the existing tested `AttachmentUploadApi` and `AttachmentSendFlow`; add file-backed content and a native picker at the outer shell. Add an owner-only abort route so a failed or cancelled client upload does not consume the host's three pending slots indefinitely. The existing message route already validates an attachment reference and the outbox already owns delivery.

**Tech Stack:** Dart/Flutter, Windows C++ MethodChannel, Android Kotlin MethodChannel/Activity result, existing host HTTP/SQLite attachment service.

**Spec:** [#131 workstream B](2026-11-18-project-delivery.md#L54), [v4.2 FR-13](../../../鲸言鲸语-需求规格-v4.2.md#L138-L147) and [FR-62](../../../鲸言鲸语-需求规格-v4.2.md#L579-L584), existing [attachment plan](2026-11-14-attachments-favorite-blind-index-local-index.md). Baseline: `main` `4d08323` plus merged #141/#143/#144.

## Global Constraints

- Android and Windows only; do not add a third-party dependency. The `crypto` package is already used by `jingyu_client_kit`; add the same version as a direct app dependency for local SHA-256.
- Sending remains explicit: the picker stages only a sanitized basename in memory; upload requires a separate **发送附件** tap in the same still-authorized chat. Cancelling sends nothing. The message is queued only after host completion. No model dispatch, no automatic replay of an uncertain stage, no text/attachment substitution.
- Keep existing routes, host attachment bytes/size/hash rules and outbox semantics. Never expose local file paths, file bytes, extracted text or upload IDs in UI/logs/errors. UI changes require matched real application Before/After captures at identical state and viewport.

## Review Focus

- A user cancels the picker or changes account/conversation/lock while it is open: no upload, message or queued write for the stale target. Test runtime with a gated picker and account/session invalidation.
- Upload fails after initiation: abort the owned pending upload, preserve the selected file and no chat message. Test the host abort route and the runtime cleanup path.
- The host completes but enqueueing fails: no silent loss or duplicate; delete the unreferenced completed attachment when possible and leave the composer recoverable. Test the checkpoint failure.
- Large files, empty files and unsupported image extensions: reject before any HTTP or send; a valid trailing chunk must preserve hash and size. Test file source and API flow.
- A user chooses the same file twice: two explicit sends must remain distinct attachments/messages, never dedupe by file name or bytes. Test two sequential flows.

### Task 1 — Make pending upload abort owner-scoped and recoverable

**Files:** `packages/jingyu_protocol/lib/src/routes.dart`, `apps/host/lib/src/messages/{attachments.dart,attachments_module.dart}`, `apps/host/test/attachments_test.dart`.

**Interface:** `AttachmentService.abortUpload({required String ownerAccountId, required String uploadId}) -> Future<Result<void>>` and authenticated `DELETE /api/v1/attachments/uploads/{uploadId}`. Only the owner can abort a pending upload; mark it `aborted`, delete its chunk rows, and remove the `.part` file. Missing/foreign returns 404; already aborted returns success; completed returns conflict. Serialize with chunk/complete via the existing owner/upload queue.

- [x] Test owner abort after partial chunks: pending slot freed, rows/part gone, subsequent chunk/complete conflict, foreign abort non-mutating; rerun the attachment suites.

### Task 2 — Add a platform picker and file-backed content

**Files:** `apps/client_flutter/lib/platform/native_platform.dart`, `apps/client_flutter/lib/attachments/attachment_content.dart`, `apps/client_flutter/windows/runner/{platform_integration.cpp,platform_integration.h}`, `apps/client_flutter/android/app/src/main/kotlin/com/jingyu/client_flutter/MainActivity.kt`, `apps/client_flutter/pubspec.yaml`, `apps/client_flutter/test/attachment_content_test.dart`.

**Interfaces:** `NativePlatform.pickAttachment(String kind) -> Future<PickedAttachment?>` exposes the local path, sanitized metadata and cache-copy ownership only inside the outer platform adapter. Windows opens the native file dialog; Android opens `ACTION_OPEN_DOCUMENT` and copies the selected content URI into a private cache file off the UI thread. `FileAttachmentContent.load(...)` returns an `AttachmentContentSource` with canonical MIME, exact size, lowercase SHA-256 and a fresh bounded file stream. Reject empty/over-128MiB/unsupported images before HTTP.

- [x] Test MIME mapping, empty handling, digest of known bytes and actual file stream. Build both platform targets after native additions; never run on a device.

### Task 3 — Wire explicit picker → upload → outbox send in chat runtime

**Files:** `apps/client_flutter/lib/app/{runtime.dart,shell_view_model.dart}`, `apps/client_flutter/lib/net/{attachment_upload_api.dart,attachment_api.dart,attachment_send_flow.dart}`, `apps/client_flutter/lib/features/chat/chat_pane.dart`, `apps/client_flutter/test/runtime_attachment_send_test.dart`, `apps/client_flutter/test/ui_test.dart`, `docs/requirements-traceability.md`.

**Interfaces:** `AttachmentUploadApi.abort(String uploadId)` matches Task 1; `AttachmentSendFlow.upload` receives a `FileAttachmentContent` and optional active-state callback. Runtime `attachFile(String kind)` opens the picker only for the still-current authenticated conversation and stages its basename; an explicit `sendSelectedAttachment()` rechecks account, session, conversation, consent, connectivity and lock, then loads/hashes, uploads all advertised chunks, aborts pending on failure, queues exactly one `MessageKind.image|file` with `{'attachmentId': id, 'name': basename}` through the guarded durable checkpoint and flushes. `discardSelectedAttachment()` cleans the cache copy; text drafts remain untouched.

- [x] With a loopback host and mocked native picker, assert cancel sends nothing; valid file uses chunks, attachment reference, one canonical message, no path leaked; changed conversation during picker does nothing; upload failure aborts and leaves no message; enqueue failure cleans up and does not retry. Run targeted Flutter tests.
- [ ] Run Flutter analysis/full suite, root `tool/check.ps1`, builds; capture matched production app Before (attach unavailable) / After (attachment sent) at same viewport/theme; independent review. Record REQ-R2-02/FR-62 evidence without claiming Android device acceptance.

## Release boundary

This slice demonstrates selecting, uploading and explicit sending in the app using synthetic data. It does not add drag/drop, multi-file selection, image previews, Android device proof, real media playback, cross-process upload recovery, or physical deletion guarantees for aborted parts beyond best-effort. Do not call full FR-62 or R2 complete.
