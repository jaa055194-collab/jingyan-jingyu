# CR-03 stored report details (#131 task-8)

From `动态`, the signed-in reader can expand a generated weekly or annual report and collapse it in place. The row stays identified by its AI and period. Missed, deferred, and generated-without-body rows remain noninteractive. The details present the host's stored window, UTC generation time, counts, topics, daily mood values, letter, provenance, and annual fields. Missing optional content is labeled as such; stored zero counts remain zero.

Opening a report needs no extra request. It uses the body attached to that exact row in the existing authenticated list response. The client checks the body kind and period against the enclosing row and separates same-period AIs. Account, lock, logout, and session changes invalidate expanded content and in-flight list refreshes. The user must reopen `动态` to load again after invalidation. No changes to host authorization, scheduling, providers, budgets, sharing, or export are included.

## Matched application comparison

Both images render the production `WhaleChatApp` after selecting `动态` from its normal shell, before touching any report. The same synthetic authenticated account and in-process connection return one complete weekly report, one complete annual report, one missed row, one deferred row, and one generated row with no body. The radio fixture is empty. No live credentials, private content, production state, or Settings entry is used.

| Capture | Production revision | Result |
| --- | --- | --- |
| [Before list](<cr03-task8-before-e5c89f3-list-light-1280x960.png>) | `e5c89f335904c1540c26f33b61dd7cda6e2f1f90` | Static summary rows with no detail disclosure. |
| [After list](<cr03-task8-after-55de085-list-light-1280x960.png>) | `55de08502db4a891a77cc953cf42616dda1d6643` | Generated rows with stored bodies have disclosure arrows, AI identity is visible, and the missing body is labeled separately. |

Follow-on After captures at the same revision and viewport, separate from the matched pair: [expanded weekly](<cr03-task8-after-55de085-weekly-light-1280x960.png>) and [expanded annual](<cr03-task8-after-55de085-annual-light-1280x960.png>). The driver checks visible letter content, the weekly source-scope section and the annual busiest day. In both revisions, no creative request occurs from Chat and there are exactly two reads after opening `动态`: the existing reports and radio list GETs. The follow-on stages assert this count does not increase on expand or collapse.

| PNG | SHA-256 |
| --- | --- |
| [Before list](<cr03-task8-before-e5c89f3-list-light-1280x960.png>) | `2EE0928FE478B439487D4070CA05BF518FFC8116ABD491899B9479B24C7FF608` |
| [After list](<cr03-task8-after-55de085-list-light-1280x960.png>) | `E5AE1C0297A40A1893E00B6B785D9D8752110FC084D6F35CAB40B424B664EFD4` |
| [Weekly detail](<cr03-task8-after-55de085-weekly-light-1280x960.png>) | `C7D12110C26A38512382BE6CC140FC4177630FFB8801253908ADA7A3DBA6B628` |
| [Annual detail](<cr03-task8-after-55de085-annual-light-1280x960.png>) | `7F640731AC7D4318022296D7B51AF4792887C6AD358973295C1124B46B1DF4CE` |

All four unedited PNGs passed a full Windows `System.Drawing.Bitmap` pixel decode, dimensions and nonblank checks. The matched list frames differ in 54,221 of 1,228,800 pixels.

## Reproduce

Both captures ran on Windows through the same [capture driver](<cr03_task8_report_detail_capture_test.dart>) (SHA-256 `2B220EC7BD50C115D45ECACDEF5AB7B495A335DDC3A25B1BED67B07D42EBD5BB`), rendering the real shell/creative widgets and DTO adapter with `RenderRepaintBoundary.toImage`. Viewport is **1280 × 960 logical and physical pixels**, DPR 1, light Material theme, font scale 1.0. The fixture and all fonts are the same on both sides. No production source was changed in the disposable baseline worktree; only the identical evidence driver was copied into it.

- Flutter **3.50.0** stable, framework `ab2912035e`, Dart **3.14.0**.
- Offline-resolved `pubspec.lock` SHA-256 **`C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937`** on both revisions (`material_ui 1.11.1`, `vector_math 2.4.4`); no dependency changes.
- Windows SimHei (`C:\Windows\Fonts\simhei.ttf`, loaded as the harness `Ahem` face), SHA-256 `9B1959DB3B3ABEB7EFDAEC26EDF7DFE871A6039DE8D614AF7248575207BE629E`.
- Flutter SDK `bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf`, SHA-256 `D9865B671A09D683D13A863089D8825E0F61A37696CE5D7D448BC8023AA62453`.

Use a checkout of the code or evidence commit for After. From its repository root, create a separate detached baseline at `e5c89f335904c1540c26f33b61dd7cda6e2f1f90` and place a byte-identical copy of the driver under its Flutter `evidence/` directory. From each revision's `apps/client_flutter` directory (set `$output` to a new absolute PNG path):

```powershell
flutter pub get --offline
$font = Join-Path $env:WINDIR 'Fonts\simhei.ttf'
$sdk = Split-Path (Split-Path (Get-Command flutter).Source -Parent) -Parent
$icons = Join-Path $sdk 'bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf'
flutter test --no-pub --reporter expanded evidence/cr03_task8_report_detail_capture_test.dart `
  "--dart-define=CR03_CAPTURE_PATH=$output" `
  "--dart-define=CAPTURE_CJK_FONT=$font" `
  "--dart-define=CAPTURE_ICON_FONT=$icons"
```

For After only, add `--dart-define=CR03_CAPTURE_WEEKLY=<absolute weekly PNG>` and `--dart-define=CR03_CAPTURE_ANNUAL=<absolute annual PNG>` to the same command. Both capture tests passed with exit 0.

## Checks and limits

- Tests-first run on `e5c89f3` with the new tests but no implementation: **16 passed, 18 expected failures**. Observed missing disclosures at every viewport, missing-body state and identity, acceptance of mismatched nested payloads, and stale results or follow-on reads after session changes.
- Focused `flutter test --no-pub test/creative_api_test.dart test/creative_screen_test.dart test/shell_creative_wiring_test.dart test/honest_copy_test.dart`: **38 passed**. Shell coverage includes 375, 768, and 1280 logical px, session interruption while details are open, and delayed list results. The adapter tests use loopback HTTP; the widget/capture tests inject only synthetic session state and transport responses.
- Targeted `flutter analyze --no-pub` on the creative source, adapter, shell, three changed tests and capture driver: **no issues**. Full suite is left to the integration lead.
- These are actual production Flutter widget renders, not native-window or device captures, and not live-host authorization, Android acceptance, or complete CR-03/AC-27 validation. The worker cannot inspect image inputs; human visual review, dark theme and device accessibility acceptance were not performed. Assertions and pixel checks do not substitute for those checks.
