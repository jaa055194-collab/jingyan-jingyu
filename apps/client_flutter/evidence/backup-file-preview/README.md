# Windows local export-package preview

| Frame | Production revision | PNG / SHA-256 |
| --- | --- | --- |
| Before: lifecycle page without the local preview action | `d916736a7a94fce09d0ee92476571509169ce99a` | [Before](before.png) · `600EEB8FA3122BC0410487354E536EB3BA2A35BF9190B9BAA400A22D08749D5F` |
| After: same lifecycle page with the idle local preview action | `16079b450bf2a631dc4575f32082ec37e602f723` | [After](after.png) · `1520B9F7271995971A7AF4AE75AE7C164240D9FC9F5C734B692760F60E648680` |

## Matched scenario

The same [capture driver](../backup_file_preview_capture_test.dart) renders the production `WhaleChatApp` with a `ClientRuntime` shell fixture. It taps 设置, opens the existing 配额与生命周期状态 route, and captures its initial scroll position. The authenticated fixture remains unlocked, with app lock disabled. The two frames use the same synthetic quota, object counts, and cleanup response. They show the action before any file is selected: the driver asserts the same three existing host reads and no host writes in both frames. Neither frame displays a real backup or a native picker dialog.

- Windows Flutter widget renderer; 1280×960 logical and physical pixels, DPR 1, light Material theme, font scale 1.0.
- SimHei test font SHA-256 `9B1959DB3B3ABEB7EFDAEC26EDF7DFE871A6039DE8D614AF7248575207BE629E`; SDK MaterialIcons SHA-256 `D9865B671A09D683D13A863089D8825E0F61A37696CE5D7D448BC8023AA62453`.
- Same generated dependency lock SHA-256 `C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937`; driver SHA-256 `40B41C77A43282563E6CE42040914CA922CBBE8DF7749353AC7954512B9C46A7`.
- Before was rendered before production edits, with the base production tree verified pristine. After was rendered from the production source later committed as `16079b4`. Both driver runs passed. PNGs are unedited; a 1-in-4 horizontal pixel sample found changes in rows 552–959 only.

## Reproduce

Run `flutter pub get --offline` in `apps/client_flutter` at each revision, then place the same driver under `evidence/` if it is not already present. From the app folder on Windows:

```powershell
flutter test --no-pub --concurrency=1 evidence/backup_file_preview_capture_test.dart `
  '--dart-define=CAPTURE_PATH=<absolute PNG path>' `
  '--dart-define=CAPTURE_CJK_FONT=<absolute SimHei TTF path>' `
  '--dart-define=CAPTURE_ICON_FONT=<absolute SDK MaterialIcons OTF path>'
```

For After, add `--dart-define=CAPTURE_EXPECT_PREVIEW=true`.

## Verification and boundaries

- 59 focused tests passed: 21 real-file validator cases, 11 production-route tests, and 27 adjacent export, save, import, lifecycle, and native bridge tests. Scoped Flutter analysis found no issues. No full client suite was run for this slice.
- The real-runtime lifecycle regression first failed with app lock disabled while the enabled-lock case passed. After the fix, an inactive event with an unchanged, unlocked session and disabled app lock permits preview; an enabled lock during the same operation discards it even if unlock occurs before picker completion. The lifecycle events were injected into the real runtime callback; the native method channel was mocked.
- No native modal was launched in this verification. If a Windows system picker produces a lifecycle transition that really locks an enabled app lock, that selection cannot complete: the user must unlock and reopen the lifecycle route. There is no lock bypass. This is not proof about focus behavior of the native picker on a deployed Windows installation. Android is intentionally out of scope.
- Preview matches the declared owner to the current account, validates only the v1 envelope, manifest, and file integrity, and publishes no paths or contents. It does not validate that every payload can be imported. Checksums are not provenance or authentication. Preview does not extract files, save a copy, send data to the host, import, decrypt, or restore. This is partial FR-65/AC-29 evidence only.
