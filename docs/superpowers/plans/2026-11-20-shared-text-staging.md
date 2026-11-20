# Android Shared-Text Staging Plan

**Goal:** Existing Android system-share deliveries no longer disappear on cold start or overwrite whichever conversation happens to be selected. Shared text is staged privately in memory, explicitly assigned to an empty visible conversation draft, then sent only by the ordinary separate Send action.

**Baseline:** main `84410bdaae5c658f0ccf1cccee01b25736dabed9`, no dependency on chat-export branch. Source authority: #131 B; v4.2 FR-09/13, AC-16/32. No Android device operation tonight.

## Constraints and task contracts

- Keep native bridge, host, routes, deps and upload unchanged. Consume current initialize.pendingShare and warm shareReceived through one typed intake installed before asynchronous initialization. URI import remains unsupported; never open URL/content URI, stringify nontext or use subject as content.
- Supported exposed payload: map, nonblank String `text`, MIME absent/null/text/plain, `uris` absent/null/empty List only. Reject text >64KiB UTF-8 as a bounded intake limit with generic error, never truncate. Unknown keys can be ignored. Do not claim original Intent had no attachments (native already filters URIs).
- First pending supported share wins until use/discard. Store only in memory, separate from draft/outbox/settings/snapshots/logs. No preview while locked/guest/switching. Clear on logout/session replacement/terminal auth reject/dispose. Intake during initial restoration can wait for the initial authenticated session, but not later guest login.
- UI contract (source-compatible ShellViewModel defaults): `ShellIncomingShare? get incomingSharedText => null; Object? get shareInteractionContext => null; Future<bool> useSharedTextInDraft(String conversationId, {required Object interactionContext}) async => false; Future<void> discardSharedText() async {}`. `ShellIncomingShare` has `text` (bounded preview in UI), `notice` (generic error/pending collision) and stable identity token? Prefer context separate, no native fields shown.
- Runtime confirmation requires exact pending identity+account generation+lock epoch+selected target in current visible list, authenticated/unlocked/not busy/not switching. No default target. Refuse if shell.draftFor(target) nonempty or current visible draft nonempty; keep old draft and pending share. A successful guarded snapshot save clears pending and publishes selected target/draft, but never enqueue/flush/send/consent. Add optional `checkActive` to client-kit saveDraft, stage memory and publish only after shared-section checkpoint succeeds (legacy calls compatible).
- UI: one modest Material pending panel with plain bounded text preview, `选择会话`, `丢弃分享`; target dialog lists visible conversations, no preselection and explicit `加入草稿` confirmation showing current account+target. Lock, session/token change or navigation invalidates/hides old content and refuses confirmation. Cancel/back preserves pending and writes nothing. UI mobile/wide existing style, text send untouched.

## Ownership

Task A runtime+kit: `apps/client_flutter/lib/app/runtime.dart`, `packages/jingyu_client_kit/lib/src/shell_controller.dart`, new `runtime_share_intake_test.dart`, existing shell tests. Read typed UI contract from teammate; no native/host.
Task B UI: `shell_view_model.dart`, `shell_app.dart` and new `share_target_confirmation_test.dart` (or extract a tiny feature panel only if clearer). No runtime writes.
Lead integrates, verifies source constraints/traceability, full Flutter/root, short-path builds, independent review and matched real app captures, then focused PR/CI. Keep cancel, occupied draft, malformed/URI-only, cold+warm parity/startup delivery, old-dialog/new-share, lock+account queued save tests.

## Limits

Memory staging can be lost on process death. App lock is not disk encryption. Only explicit confirmed text enters existing JSON draft storage/backups. Existing unrelated outbox activity can still flush on startup/unlock; assertions are zero new share-derived sends, not zero network traffic. No native system-share device acceptance, binary share, notification, or complete AC-16 claim.
