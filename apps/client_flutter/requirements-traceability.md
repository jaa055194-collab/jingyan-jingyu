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

## Explicit own-AI private consent (2026-11-17 increment)

- Baseline: PR58 `0f63126`; host contract is merged PR66/main `9da4c1f`. This increment retains the incomplete draft and PR8 merge hold.
- Settings loads a canonical owner/account/profile tuple, then authoritative consent state; it never infers profile ID from account ID or grants on refresh. Grant/revoke requires an explicit revision-bound confirmation. Unknown/uncertain is not off; 409 reloads only; uncertain writes are not replayed.
- Runtime-issued interaction epochs are invalidated on lock, logout, session replacement and disposal. A lock/unlock cycle cannot revive an old confirmation; post-notify guards stop synchronous reentrant locking before HTTP dispatch. Mutation requests disable automatic 401 replay. Requests already transmitted cannot be unsent; late state is discarded and requires a fresh read.
- Dialogs preserve existing Material layout and hide details after captured owner/session/AI-row changes, including changes while awaiting a response. The operation's own epoch consumption does not falsely invalidate its success.
- Fresh automated evidence at source `9030e25`: Flutter analyzer clean; full suite **307 passed / 1 opt-in evidence test skipped**; focused API/runtime/Settings **84 passed**. Independent reviews and final delayed-response/row-snapshot regressions found no remaining material issue in this increment.
- Actual matched Windows Before `0f63126` / After `9030e25` now exist at light/1.0/1280×960 with the same synthetic database/owner/AI. Actual UI cancel leaves off/rev0; confirm opens rev1; revoke leaves off/rev2 with canonical conversation retained. Independent HTTP verification confirms readable empty history and no providers/messages. See `evidence/README.md` and its labelled captures. Earlier private-harness callback/UTF8-copy failures were diagnosed; no production change was needed for final capture.
- Exact `9030e25` production Windows debug build passed (83.2 seconds), without launching the ordinary native client or using production session storage. Capture source/binary isolation and metadata checks passed, but image-capable/human visual review remains unavailable. Automated widget widths and captured pixels do not prove contrast or full-shell acceptance. No live provider inference, Android or full-product readiness claim; PR58 remains an incomplete draft.

## Owner-AI prerequisite read metadata (task-40, 2026-11-17)

Baseline `1f5e16e57843bd3a23feb8e80ea47cb72738c78d`; read contracts inspected in host PersonaModule, BindingMatrix/config_routes, BudgetConfiguration/budget_routes and ProviderRegistry/ModelsModule. This is a client read adapter only, not product or model readiness acceptance.

| ID | Source / approved scope | Observable acceptance | Implementation / test | State / gap |
|---|---|---|---|---|
| M11-011 | task-40: explicit resolved identity, GET only | Every item first GETs current canonical profile/account/owner; mismatch/identity404 stops before target read | owner_ai_readiness_api.dart / owner_ai_readiness_api_test.dart | Implemented; verification recorded in handoff |
| M11-012 | task-40: exact persona/binding/budget/provider metadata | Strict identity/schema/types; complete nonnegative budget maps and sums; actual host key-mask contract, no raw key; missing/unconfigured/unknown distinguished | Same targeted loopback tests | Implemented; no UI/runtime integration |
| M11-013 | task-40: honest configuration-only status | No model/discovery/outbound/write/usage/history requests; persona text excluded from status/error/log | GET-only request assertions and safe status tests | Implemented; not model ready, budget admitted or worker available |

Fresh targeted verification: `flutter test --no-pub test/owner_ai_readiness_api_test.dart` **33 passed / 0 failed**; `flutter analyze --no-pub` **No issues found** (Windows, Dart3.14, task-40 baseline1f5e16e). Review deltas have separate RED/GREEN evidence: host-valid multiline persona values now permit TAB/LF/CR while keys still reject all controls; identity/target TLS handshake and certificate failures are normalized to unknown without exposing exception details. Lead integration subsequently passed the complete Flutter suite **340 passed / 1 opt-in evidence test skipped** and the full Flutter analyzer. No UI/runtime or real provider acceptance is claimed for this read-only adapter.

Identity and item GETs form a non-atomic observation, not a durable ownership assertion. A target persona404 may also follow transfer/revoke between reads and only means no card was retrieved. A valid zero-token budget or disabled provider is still configuration metadata, never execution permission. Provider URL parsing is metadata validation only and does not replace host UrlGuard or perform DNS.

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

## Latest message on conversation open

| ID | Scope | Observable acceptance | Evidence | Status / gap |
|---|---|---|---|---|
| M11-014 | Open any AI direct, friend direct, or group conversation at the latest message after upgrading Android | Opening or reopening starts at the latest row; rows remain chronological and older messages are still reachable. The installed update retains the existing session and cached history without a server update. | [Widget regression](test/chat_history_opening_test.dart); [Before](evidence/chat-history-opening-before.png) from `c0208b7` and [After](evidence/chat-history-opening-after.png) from the 1.0.1 (2) upgrade. Same Android 16 emulator, 1080 × 2160, light theme, synthetic 501-message AI history, no scroll before capture. | Verified in the widget tests and on the emulator: AI chat opened at 501 instead of 001; group and friend chats opened at 030; scrolling back and reopening worked. No physical-device or production-history testing. |

Only the Flutter history viewport changes: the host, sync order, and history storage are unchanged. The upgrade test installed the new APK over the previous package without clearing data. It reused the session and the fixture delivered zero new rows after restart.

## Remaining integration

1. Complete character/room host contracts and RoomGenerator persistence; do not mark onboarding complete before then.
2. Wire WebSocket events and native notifications/pet/missed-call/cold-start binary shares.
3. Complete actual attachment upload, final full-shell visual comparison and human/image-capable visual review.
4. Run real-host offline-three-message and real-device AC-16/18/30/32 acceptance.

Environment: Windows11, Flutter3.50/Dart3.14, Android SDK36/JDK21, VS2022 BuildTools. Short `J:` build path avoids MSBuild MAX_PATH. Gradle proxy is process-only; no credentials/config committed. No Android device attached.

## Android own-AI private chat and settings increment

Scope: Android-only new entry points; existing host-mediated chats and the Windows client remain on their prior paths. Source base: `87de5f3`; native baseline APK attempts used `8b47f314` and `87de5f3`. “Host offline” means the Jingyu host is unreachable while the model endpoint is still reachable; it does not mean on-device inference or no network.

| ID | Acceptance | Implementation and verification | Boundary |
|---|---|---|---|
| M11-Android-AI-01 | A previously configured phone can reopen one owned AI after a cold start, retain its current model/persona and local exchanges, and contact the configured HTTPS model with the phone's own key. | Private chat controller, Android Keystore vault and one-shot model adapter. Controller restart/lock tests and adapter transport tests; native Android build is separate from device acceptance. | Android app-level cold restart with the model reachable while the host is down is not yet device-verified. First setup requires the host. |
| M11-Android-AI-02 | After enabling synchronization, Android exchanges reach the host once and can be read by another authenticated Android device for the same owner and AI. | `android-private-chat` transport and encrypted owner-scoped history, covered by controller, HTTP adapter and disposable SQLite host tests. | Separate from legacy conversations. Sync sends exchange text, not keys or settings. No host model is invoked by a sync. |
| M11-Android-AI-03 | The user can distinguish the configured model, API address and persona, and view or edit saved persona and supported behavior controls. | Android AI directory, direct-chat secondary menu and per-AI setting screen. Widget/API tests cover scope, exact model/provider pairing, persona revision and multiline values, reply preferences and social-level invalidation. | The saved persona and last-read behavior summary can be viewed offline. Editing persona and behavior settings still uses the host; offline status does not enable local scheduled or proactive behavior. |
| M11-Android-AI-04 | Confirmed owner-only removal stops the AI and removes it from the roster without deleting or corrupting existing history. | Durable logical removal with a metadata-only audit; host tests cover ownership, restart, repeat and retention. Android requires explicit confirmation. | Logical removal, not permanent data erasure. |

Native comparison is incomplete: baseline and changed APK builds are not evidence of matching Before/After screens. The existing API 36 emulator and a fresh isolated API 36 emulator repeatedly reported Android system input-dispatch ANRs before reaching authenticated Settings. No onboarding screen, synthetic mockup or widget-only capture substitutes for the missing comparison.
