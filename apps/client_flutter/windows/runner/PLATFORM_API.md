# Windows native channel

Channel: `jingyu/platform` (Flutter StandardMethodCodec).

| Method | Arguments | Result |
|---|---|---|
| initialize | none | `{platform: 'windows', aumid: 'com.jingyu.client', tray: bool, globalShortcut: bool, notifications: true}` |
| getDataDirectory | none | current user's LocalAppData/JingyuClient path |
| getLive2DPreviewDirectory | none | existing current-user LocalAppData/JingyuClient/live2d-preview cache directory path |
| pickLive2DZip | none | null on cancel, or `{path: String, temporary: false}` for an existing `.zip` file |
| configurePin | `{pin: String}` | null; 4–12 ASCII digits |
| hasPin | none | bool |
| unlockPin | `{pin: String}` | bool |
| removePin | none | null |
| unlockBiometric | none | false (Windows Hello is not implemented) |
| storeSession | `{json: String}` | null; 1–2200 UTF-8 bytes |
| readSession | none | String or null |
| clearSession | none | null |
| lock | none | null; hide pet and clear delivered toasts |
| logout | none | null; hide pet, clear session and delivered toasts; preserve PIN |
| notify | `{title: String, body: String, hideBody: bool}` | null; real Windows toast with explicit AUMID |
| setAutostart | `{enabled: bool}` | null; HKCU Run, opt-in only |
| setPetState | `{visible: bool, unreadCount: int, locked: bool, fullscreen: bool, inCall: bool, clickThrough: bool}` | null |
| showWindow / hideWindow / quit | none | null |

Native-to-Dart callback: `event` with `{type: 'show'|'lock'|'logout'|'shortcut'|'petClick'|'platformError'}`.
Dart owns authentication routing, account identity, call state, notification policies and pet preferences. Native WTS session lock and foreground fullscreen checks supplement Dart state. Unlocking the Windows session does not unlock the application.

Initialization creates an IShellLink Start Menu shortcut with IPropertyStore/PKEY_AppUserModel_ID `com.jingyu.client`, sets process AUMID, installs notification-area icon and attempts Ctrl+Alt+J. A conflicting shortcut is reported as `globalShortcut: false`. Notification capability means the native toast path exists; Windows/user notification policy can suppress delivery. No third-party dependency is used. Notification activation routing is not implemented.

PIN storage uses BCrypt random 32-byte salt, PBKDF2 using SHA-256 (600000 iterations), constant-time verifier comparison, user DPAPI encryption and Windows Credential Manager. Session JSON is also DPAPI-encrypted in Credential Manager. The app data directory uses the current user's inherited LocalAppData ACL. PIN changes and removal must be gated by Dart's unlocked settings screen.

The Live2D preview directory is created on demand under the current user's LocalAppData and uses inherited permissions. The ZIP picker selects a single existing filesystem file, does not read or copy it, and does not add it to Recent Documents. Dart owns capped stream reading and archive validation; `temporary: false` means the source file is not a disposable staging copy. Native errors do not include paths.

The pet is a static transparent topmost native shape, not an avatar renderer. Its only label is an unread count. It repaints on state/Windows paint events, with a 1Hz visibility check for fullscreen apps. Dragging snaps to the nearest screen edge; doubleclick hides pet/main window to tray. The tray context menu can toggle click-through so an otherwise noninteractive pet can be recovered.

## Native verification

From a Visual Studio x64 developer prompt, in this directory:

```
cl /nologo /EHsc /W4 /WX pin_store_test.cpp pin_store.cpp /Fe:pin_store_test.exe /link bcrypt.lib crypt32.lib advapi32.lib
pin_store_test.exe
```

Or build CMake target `jingyu_pin_store_test` after Flutter configures Windows. The test uses an isolated credential target and removes it. It tests absent state, correct/incorrect PIN, replacement, malformed PIN rejection and removal. Full runner build verifies Windows SDK/WinRT linkage. Desktop checks (toast delivery, shortcut property, tray, autostart and pet interaction) require a running interactive app and must be reported separately from compilation.
