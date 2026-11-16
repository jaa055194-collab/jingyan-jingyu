# M11 implementation and acceptance record

Source: Issue #5, `docs/modules/M11-client-shell.md`, v4.2 FR-09/11/13/18/61. Owner authorized host/clientkit contract extensions in Issue #5 on 2026-11-13. Latest composition includes main through `cf3adfd` (including the bounded-inflate #42 security fix).

**INCOMPLETE DRAFT. Not a usable client release.** PR #8 must not merge by default: the owner explicitly requires notification and agreement before any proposed merge (2026-11-15). No auto-merge is authorized.

| ID | Requirement | Implementation / evidence | Status and gap |
|---|---|---|---|
| M11-001 | Required flutter create and four path packages | Android/Windows shell; pubspec paths | Implemented |
| M11-002 | Outbox / SyncCursor / durable drafts | Client controllers and snapshot tests; original client IDs retained on 401, refresh, retry and storage failure | Automated verified; actual-host offline-three-message AC-18 run not performed |
| M11-003 | Plugin identity and capabilities | Admin-only host metadata reports explicit trusted admin+device identity; ordinary authenticated clients default to false after403. Capability-checked read/model callbacks | Unit verified; host callbacks/plugin installation UI still not integrated. #42 forged-header bounds tests pass; no installation UI added |
| M11-004 | Onboarding + RoomGenerator | New/existing account form, host redeem/login/refresh adapter, protected native session, selectable account recovery ID | Login is integrated and tested with real loopback HTTP fixtures. Character/room persistence and RoomGenerator completion still unavailable; no success mock |
| M11-005 | AC-16 Windows OS integration | Explicit AUMID shortcut/process, tray, shortcut, opt-in autostart, toast, static pet, secure native PIN/session | Windows debug builds verified; full interactive notification/pet/call bindings not accepted |
| M11-006 | AC-16 Android OS integration | Foreground service, share metadata, PIN/biometric, Keystore session,30s call timeout hooks | Debug APK built historically; final build result recorded in PR. No attached device, headless engine, complete binary share/upload or call overlay acceptance |
| M11-007 | AC-30 app lock/privacy | Legacy device-wide appLock/preferences whitelist migration; native PIN presence fails closed; logout/disposal generation guards | Automated verified; actual locked-notification behavior unverified |
| M11-008 | AC-32 AI attachment consent/drafts | Per-identity/conversation consent + durable drafts; UI consent gate | Unit verified; attachment upload not connected |
| M11-009 | analyze/test/build | Full Flutter analyzer clean;133 Flutter tests pass. Clientkit analyzer clean/144 tests pass. Windows debug154.1s and APK debug269s pass. Full repository check failed one unchanged host TLS concurrency test (expected16 sockets/actual17); isolated rerun passed | Repository suite is not green; no complete product acceptance claim |
| M11-010 | Actual Before/After | Real Windows captures at1280x960 logical, light initial onboarding; baseline6b06a3b and changed source hashes in evidence/README.md | Captures prove this credential increment only. Original whole-shell comparison remains absent. Image model inspection unavailable; OCR is not visual review |

## Identity and token invariants

- Password/invitation are never stored in ordinary snapshots. Tokens pass only through native protected session storage.
- Host origin + authenticated account + device map to separate random snapshot files through an index. Existing legacy messages/outbox are preserved but never attached to a new account.
- Device-wide settings migrate only whitelisted lock/presentation fields, not private message data.
- Secure-store success precedes publication of new identity or rotated tokens. Destination snapshot parsing precedes a session switch.
- Logout invalidates in-flight login/refresh generations, closes both transports, unloads plugins, and orders protected clearing after earlier writes. Dispose prevents live activation; a valid already-in-flight protected save may finish for next launch.
- A401 is retried after at most one single-flight refresh. If authentication remains unavailable, the outbox retains its original message ID. A transient secure-store failure retains the rotated pair in memory for a later persistence attempt on the same device, rather than reusing an invalidated refresh token.

## Approved temporary chat-first workflow

The owner approved deferring unavailable character/room setup: after real host authentication, an unlocked user can explicitly enter the existing chat shell. This is a local app flow increment atop PR #8, not a merge/release of that held draft. Character/room screens remain accessible from the World tab and still report unavailable host contracts honestly; `onboarded` is never set by deferral.

The separate `chatEntered` choice is persisted only in the existing host/account/device snapshot. It does not rewrite credentials or change token rotation. New widget/runtime regressions cover the defer route, optional return to setup, unauthenticated and locked denial, credential nonmutation, restart, and identity isolation. See [actual native comparison](evidence/public-comparison.md): matched before/after Windows HWND captures use the real app/public authentication and identical capture-only native state isolation. Baseline is7c5405f; changed four-file patch6231F493 is a source subset ofb53655d, not its entire tree. Capture-only tray/hotkey/autostart are disabled and model image input was unavailable, so native integration acceptance and independent visual inspection remain incomplete. Earlier [harness evidence](evidence/chat-first-harness.md) is explicitly intermediate and not final visual evidence.

## Ordinary group-chat client increment

Authenticated online users can create a named group from the conversation list, select the server-confirmed group, and separately add a known account ID when the host's canonical group metadata identifies the current owner. Existing outbox/send/sync and draft persistence are reused. Unconfirmed creation is not automatically replayed; explicit refresh recovers the authoritative list and clears obsolete recovery guidance after success. Dialog input is hidden after lock/logout. No account enumeration, friendship grant, or AI-consent shortcut is introduced.

Final focused group/mapping/authentication tests:36 passed. Lead full Flutter suite:181 passed,1 evidence-generation skipped; final Flutter analysis clean. Independent source-review follow-up found no remaining actionable blocker after the refresh-recovery regression. Actual default-host two-human helper smoke passed creation, membership, duplicate-clientMsgId deduplication, exact text sync and durable host restart; this is not the UI acceptance result. Actual native group UI integration passed: real create dialog, server-confirmed selection, add-member action and composer/send reached a second synthetic human's real public-API list/sync with exact text and queue0. [Matched native group comparison](evidence/public-group-comparison.md) identifies source6b85f00 and capture isolation; before/after tray instrumentation differs and is disclosed. Android debug APK built successfully (442.3s), source/lock remained unchanged; no Android device acceptance. Model image input was unavailable, so independent visual inspection remains pending. No automatic AI reply is delivered by this increment.

## Explicit one-message AI mention and local rules greeting

The group composer now offers explicit confirmation for one known AI account ID on that message only. It persists `{text, mentionAccountIds:[id]}` through the existing outbox; ordinary subsequent sends stay text-only. Failed local checkpoints reconcile the original retained client message ID, refuse replacing another unresolved mention, and preserve newer per-conversation draft revisions. No persistent intent ledger or exactly-once crash recovery is claimed.

Lead final Flutter suite at8752948:196 passed,1 evidence-generation skipped; analyzer clean. Final Android debug build96.3s and uninstrumented production Windows debug79.2s passed with unchanged source/lock. Fresh independent source follow-up found no remaining blocker after checkpoint/revision regressions. Actual native UI against host47a19b0 passed: real user enters你好, confirms knownAIID once, canonicalAI reply你好呀 is persisted with source=s1/activityRefs=[], client displays it and a second human's public sync verifies exact body/sequence; pending queue0. [Actual matched comparison](evidence/public-mention-s1-comparison.md) records source8752948/host47a, same native isolation, viewport and limitations.

This is an explicitly admitted **curated rules-only S1 greeting**, not model chat or general AI conversation. Host configuration must explicitly provide current socialL1+, canonical membership/history, budget/timezone and group admission. No provider/model call, private-AI friendship bypass, memory capture or external group-content export occurs. Image-capable visual inspection and Android device acceptance remain unavailable.

## Tray-unavailable startup fallback

Windows native initialization now reports the actual `tray:false` capability instead of aborting the entire client solely because the notification-area icon could not be created. Real registration is still attempted; other native initialization failures are unchanged. A separate actual native integration kept `Shell_NotifyIconW` intact, observed its false result, and verified real DPAPI session restoration with ready/authenticated true and no startup error. This is not full tray/hotkey/autostart or AC-16 acceptance.

## Remaining integration

1. Complete character/room host contracts and RoomGenerator persistence; do not mark onboarding complete before then.
2. Wire WebSocket events and native notifications/pet/missed-call/cold-start binary shares.
3. Complete actual attachment upload, final full-shell visual comparison and human/image-capable visual review.
4. Run real-host offline-three-message and real-device AC-16/18/30/32 acceptance.

Environment: Windows11, Flutter3.50/Dart3.14, Android SDK36/JDK21, VS2022 BuildTools. Short `J:` build path avoids MSBuild MAX_PATH. Gradle proxy is process-only; no credentials/config committed. No Android device attached.
