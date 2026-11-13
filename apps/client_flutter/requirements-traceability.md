# M11 implementation and acceptance record

Source: Issue #5, `docs/modules/M11-client-shell.md`, v4.2 FR-09/11/13/18/61. Owner authorized host/clientkit contract extensions in Issue #5 on 2026-11-13. Baseline `3c81587bed34707432b321bf25605b2ce8e22cbc`. This revision is rebased onto `main` `ad55b4c…` after the serial review stack (#18 → #24 … → #31) merged.

**Status: INCOMPLETE DRAFT. Not a usable client release.**

| ID | Requirement | Implementation / evidence | Status and gap |
|---|---|---|---|
| M11-001 | Required flutter create and four path packages | Generated Android/Windows shell; pubspec paths | Implemented |
| M11-002 | Outbox and SyncCursor, durable drafts | `jingyu_client_kit` 130 tests (main's `ClientSession` + M11 `shell_controller`); Flutter storage tests | Unit behavior verified; real-host AC-18 offline 3-message run still not performed |
| M11-003 | Plugin identity and capabilities | `isHostMachine` from trusted admin account+device (`JINGYU_HOST_ACCOUNT_ID`/`JINGYU_HOST_DEVICE_ID`), admin-only `/host`; capability-checked `readConversation`/`modelInvoke` callbacks; clientkit tests | Contract verified; runtime plugin capability callbacks not yet bound to host |
| M11-004 | Onboarding + RoomGenerator | Injected kit `OnboardingHost`; widget wizard | Host now has `auth/invites/redeem` + `auth/login`, but onboarding form lacks display-name/password/device fields, so connect still fails closed. No world/`space_layout` route exists, so room persistence cannot complete |
| M11-005 | AC-16 Windows tray/startup/hotkey/AUMID/toast/pet | Native C++ (AUMID shortcut, tray, shortcut, autostart, toast, static pet, DPAPI/PBKDF2 PIN+session) | Built earlier; not re-built after this rebase. Interactive OS behaviour and runtime notification/pet bindings unverified |
| M11-006 | AC-16 Android FGS/share/call fallback | Native Kotlin (FGS, share, PBKDF2 PIN, Keystore session, 30s idempotent call timeout) | Built earlier; not re-built after rebase. No device; cold-start binary share and binary attachment upload incomplete |
| M11-007 | AC-30 app lock + notification body privacy | Kit `NativeLockAuth`; native PIN/session storage; widget lock tests | Unit verified; real locked-notification lifecycle unverified |
| M11-008 | AC-32 first AI image/file consent; drafts | Conversation consent tests + widget dialog; durable drafts | Unit verified; actual upload unavailable |
| M11-009 | analyze/test/build | Flutter `analyze` clean; `flutter test` 20 passed + conversation-mapping 2 passed; clientkit 130 passed; `tool/check.ps1` green for unchanged packages | Windows/APK builds not re-run after rebase; host full suite not completed here (600k-round PBKDF2 makes it very slow) |
| M11-010 | Before/After real captures | Baseline scaffold Windows build exists but no usable capture; no actual After capture | **Both missing.** UI handoff incomplete |

## Remaining integration (concrete)

1. Add display-name/password/device-name to onboarding; call `auth/invites/redeem` then `auth/login`; store tokens through native secure storage.
2. Scope the local snapshot (outbox/drafts/cursor/consent) to the authenticated account/device before enabling connect.
3. Load conversations via `/conversations` + `/direct-conversations` (mapping helper added and unit-tested) and bind a WebSocket stream when the host provides the upgrade handler.
4. Add the world/room route, then complete the RoomGenerator step.
5. Bind native `notify`/`setPetState`/`setMissedCall` and cold-start shares.
6. Capture actual Before (generated scaffold) and After (implemented shell) on the same viewport, and run real-host + real-device AC-16/18/30/32.

## Verification environment

Windows 11; Flutter3.50/Dart3.14; Android SDK36/JDK21; VS2022 BuildTools. Builds use a short `J:` subst path to avoid MSBuild MAX_PATH. Gradle needs process-only proxy settings; no proxy credentials/config committed. No Android device attached.
