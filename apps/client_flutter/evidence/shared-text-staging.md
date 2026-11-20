# Shared-text staging — application comparison

| Capture | Production revision | Result after the same native text share |
| --- | --- | --- |
| [Before](shared-text-before-84410bd.png) | `84410bdaae5c658f0ccf1cccee01b25736dabed9` | The arriving `sharedReceived` text replaces the saved `原有草稿`. |
| [After](shared-text-after.png) | `e5df467eb07034eab4542703f9c7f381e323f931` | `原有草稿` remains in the composer and on disk; a pending-share panel offers explicit **选择会话** or **丢弃分享**. |

Both unedited images are production `WhaleChatApp` with `ClientRuntime`, Windows Flutter 3.50.0, 390 × 844, light theme, DPR 1, identical fonts, synthetic authenticated account and saved draft. The native bridge and host are replaced by a fixture; this is not Android system-share, live-host, or device acceptance.

Each driver emits the exact warm `shareReceived` map and asserts no host mutation, message, outbox item, confirmation or send. The After driver additionally reads the composer and account file to verify the original draft survived, and the panel exposes the shared preview. Both tests passed. PNGs passed full pixel decoding, opacity, dimension and SHA-256 checks. Subjective visual approval was unavailable on the text-only model.

Runtime regressions additionally cover cold `pendingShare`, delivery during startup, malformed/URI-only content, first-pending-wins, guest/login isolation, logout during restore, lock invalidation and concurrent draft edits. See [the runtime tests](../test/runtime_share_intake_test.dart), [the explicit-target tests](../test/share_target_confirmation_test.dart) and [the guarded draft checks](../../../packages/jingyu_client_kit/test/shell_controller_test.dart).

Known limits: pending content is memory-only and is lost on process death; binary share is unsupported; app lock is not disk encryption; a share save that has already started cannot be rolled back by a later lock, although it is not published as a new selection. Android Intent handling was not exercised on hardware.