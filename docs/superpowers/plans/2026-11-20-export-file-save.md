# Save Verified Chat Export to a Local File

**Goal:** After the existing authenticated chat-only export succeeds, the user can explicitly save that exact version-1 bundle as a local JSON file. Cancellation or save failure leaves all app/host state unchanged and never retries automatically.

**Baseline:** main `058dbf3275ecfec721edf08537782a802aabae41` (includes merged #147). Source authority: #131 workstream C first slice, v4.2 FR-65 / AC-29 subset, decisions A-12.

## Constraints

- Keep the host route, export format, import behavior, account scope and the UI's existing summary/import flow. Do not add a file-upload/import path in this slice; loading a file for import is separate.
- Save only after an explicit button tap. No auto-save on export, no background save, no overwrite without the operating system's own overwrite confirmation. Show a plaintext-file privacy warning. Never render bundle file bodies, local absolute paths, chat text, or credentials.
- The file is the exact package envelope `{ownerAccountId, files, manifest, sha256sums}` accepted as data; do not add local paths or metadata. Bound the bridge payload (4 MiB UTF-8) and reject larger bytes before invoking the platform. Cancellation is not an error.
- Windows and Android only. No third-party dependency. Native saves are user-chosen destinations; do not silently write inside app storage. Do not delete or truncate an existing destination on failure beyond the operating system's own write semantics. Do not weaken app lock/account isolation. No device acceptance is claimed.
- Use matched production UI Before/After evidence at the same post-export state; the save system dialog itself is native and not part of the Flutter capture.

## Interfaces

- `LifecycleExportBundle.exportFileContents()` returns the exact JSON envelope `{ownerAccountId, files, manifest, sha256sums}`, validates it round-trips through `fromJson`, and throws `FormatException` above 4 MiB UTF-8. No files are rendered by widgets.
- `BackupFileStore.save(bundle)` hides the platform. `NativeBackupFileStore` encodes the envelope and calls `NativePlatform.saveBackupFile` with `suggestedName`, `bytes` (`Uint8List`) and the 4 MiB bound. Native result is `{name, bytes}` or null for cancellation; Dart validates display name, written length, and returns only display metadata. Invalid results throw `FormatException`; absolute paths never reach callers.
- `BackupQuotaScreen(backupFiles: BackupFileStore?)`. Settings injects `NativeBackupFileStore(NativePlatform())` when a host connection exists; absent store leaves the save action disabled with honest text.
- Native method name is `saveBackupFile`; Windows `GetSaveFileNameW`, `.json` filter, overwrite prompt, byte-exact temp-write + `MoveFileExW`; Android `ACTION_CREATE_DOCUMENT`, `application/json`, `EXTRA_TITLE`, byte-exact write off the UI thread to the returned content URI. Both return display name and written byte count, never a Dart-visible path. Android document-URI writes are not atomic; failure must report an error and must not delete the user's chosen destination.
- The existing in-memory import action stays available but carries an explicit warning that the default host sink is not durable and does not survive restart; no new import path is added.

## Ownership

- Dart surface/UI/tests: `apps/client_flutter/lib/net/lifecycle_api.dart`, `lib/platform/native_platform.dart`, `lib/features/lifecycle/backup_quota_screen.dart`, `lib/features/settings/settings_screen.dart`, tests.
- Native Android: `android/app/src/main/kotlin/com/jingyu/client_flutter/MainActivity.kt`.
- Native Windows: `windows/runner/platform_integration.cpp` (and header only if needed).
- Native Android: `android/app/src/main/kotlin/com/jingyu/client_flutter/MainActivity.kt`.
- Lead integrates, runs focused/full checks, builds both platforms from clean short path, captures matched UI evidence, independent review, publishes focused PR. No teammate commits or remote operations.

## Tests

1. RED first for `exportFileContents`: exact round-trip, no extra fields, UTF-8/size boundary, malformed/no checksums refused.
2. MethodChannel mock: success returns basename only; cancellation returns null; malformed result and invalid names rejected; no raw `content` visible to UI.
3. Widget: save disabled before export; after explicit export and an injected real store contract it becomes available; success notice names basename and warns plaintext; cancellation/failure notices generic; absent store leaves it disabled with gap text; no send/import/mutation, no bundle content or absolute path rendered.
4. Existing lifecycle export/import tests and full Flutter suite; native Windows + Android debug builds. Save dialog is not exercised on hardware.

## Execution

- [x] RED: serialization/4 MiB cap, bridge validation and UI save tests fail before the save APIs exist.
- [x] Client bundle encoder, injected file store, explicit save action, honest cancel/failure notices and import durability warning; focused tests pass.
- [x] Windows/Android native save dialogs with byte-exact destination writes and no path returned to Dart (static compile checks pending final build).
- [x] Full Flutter suite (654 passed, one existing skip) and analysis clean; clean short-path repository checks passed (host 1,525 with 15 existing skips; all shared packages); Windows and Android debug builds passed from `6c91d25`.
- [x] Matched production captures committed; focused PR #148 published and bound; exact-head CI passed.
- [ ] Independent final review sign-off; then report ready for review (not complete AC-29).

## Limits

No native save-dialog/device acceptance; no Android system filesystem proof. A user-chosen file intentionally contains private chat plaintext and leaves app-lock protection; the warning must say so. No import-from-file, persistent import, encrypted backup or complete AC-29 in this slice.