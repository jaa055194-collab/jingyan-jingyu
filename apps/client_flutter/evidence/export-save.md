# Saving a verified chat export — application comparison

| Capture | Production revision | Result after the same explicit export |
| --- | --- | --- |
| [Before](export-save-before-058dbf3.png) | `058dbf3275ecfec721edf08537782a802aabae41` | The bundle stays in memory; there is no way to save it to a file. |
| [After](export-save-after.png) | `44d05b9a8d6b7990dd805df91fe5fc9166f9f039` | **保存到文件** becomes available after export. One explicit tap records the exact parsed envelope and shows only the filename/size plus a plaintext warning. |

Both unedited images are production `BackupQuotaScreen` with the real `LifecycleApi` and `HostConnection` against the same loopback chat-only bundle, Windows Flutter 3.50.0, 390 × 844, light theme, DPR 1 and identical fonts. The native save dialog is replaced by a narrow injected store in this harness; it is not system-dialog, OS-write or device acceptance.

Each test asserts three read GETs and exactly one export POST from the explicit tap, no import, and no rendered chat text. The After test additionally asserts one save tap carrying the exact `{ownerAccountId, files, manifest, sha256sums}` envelope and that neither the envelope nor an absolute path is rendered. Both tests passed; PNGs passed full pixel decoding, opacity, dimension and SHA-256 checks. Subjective visual approval was unavailable on the text-only model.

Behavioral regressions cover the 4 MiB refusal, exact round-trip, byte-exact bridge payload, cancellation, malformed platform results, and path-like/oversize inputs rejected before invoking the platform. See [bundle tests](../test/lifecycle_export_file_test.dart), [bridge tests](../test/native_platform_save_test.dart) and [screen tests](../test/backup_quota_actions_test.dart).

Known limits: the saved file is plaintext chat history outside app-lock protection; Windows and Android native dialogs and OS writes were not exercised on hardware; Android document-URI writes are not atomic; file-based import, durable host import, encrypted backup and restore drill remain open.
