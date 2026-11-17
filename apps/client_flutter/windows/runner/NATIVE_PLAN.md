# Windows M11 Native Adapter Implementation Plan

Goal: implement the jingyu/platform contract for FR-09/11 and AC-16/30 using Windows SDK APIs only.

Architecture: FlutterWindow owns a PlatformIntegration adapter. Windows handles shell integration and credential protection; Dart owns product state and lock routing.

Spec: docs/modules/M11-client-shell.md; 鲸言鲸语-需求规格-v4.2.md FR-09/11.

- [x] Add a native credential test covering absent PIN, correct/incorrect PIN, replacement and malformed input. Compile it before implementation to establish the missing implementation.
- [x] Add PinStore with BCrypt random salt, PBKDF2 SHA-256 (600000 iterations), DPAPI and Windows Credential Manager; never persist raw PIN.
- [x] Add adapter initialization: explicit process AUMID and IShellLink/IPropertyStore start-menu shortcut, tray, CtrlAltJ, opt-in HKCU Run.
- [x] Add actual WinRT toast, close-to-tray, lock/logout events and a layered pet window with count-only unread bubble, clickthrough, edge snap and fullscreen/session-lock hiding.
- [x] Compile the native runner and run credential tests. Report desktop interaction checks as unverified unless exercised.

Review focus: registration failure must surface; malformed channel arguments fail safely; secrets must never be saved raw; lock/fullscreen/calls hide pet; disposing unregisters OS resources.

No commits per assignment. Native scope stays under this windows directory.
