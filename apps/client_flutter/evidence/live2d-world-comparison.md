# World tab: local Live2D ZIP preparation — Flutter painter evidence

## Matched state

Both captures use the production `WhaleChatApp` and open the production `WorldScreen` via the **世界** navigation rail. The same synthetic model is authenticated, unlocked, ready, chat-entered, and not busy; world setup is complete, the online indicator is on, and there is no selected conversation, prior ZIP, or model asset. Application storage and native runtime initialization are not used; neither run contacts a host. The comparison is the idle, unscrolled World tab in the light theme at **1280×960 logical and PNG pixels**, DPR 1, text scale 1. The only tap is on the **世界** navigation entry; the ZIP picker is not invoked.

| Render | Source | PNG SHA-256 |
| --- | --- | --- |
| [Before](live2d-before-2c0a263-world-light-1280x960.png): existing World tab, no ZIP action | Detached, exact pre-change merge `2c0a26386021bda523d841912d83c02ac293b9ed` | `AA41CEB0D338FF405C02F6D568E700E6B5FDECFCA1A5802897FB4906154CB392` |
| [After](live2d-after-world-light-1280x960.png): same tab, enabled **选择 Live2D ZIP** action | Same merge `2c0a26386021bda523d841912d83c02ac293b9ed` plus the three production sources below | `108776E4D6EE6A9D88CDF7D064BD8DD509E3348ACE47CA0AA91E2AF70DCAF018` |

The Before checkout had no production changes. Its `WorldScreen` Git blob is `a26a00dd0fb0ec06f1a1a85ac77c6e5cf2d17c74`. The After checkout was also detached at the merge and used the following working-tree sources, copied byte-for-byte into that isolation checkout. No capture-only production patches were applied.

| After source | SHA-256 |
| --- | --- |
| [World screen](../lib/features/world/world_screen.dart) | `F3A2F7650FD3A96A4E6662A47869F9E0A1D1FE78B3C14C4CC378D94D2B3BC4B6` |
| [Import panel](../lib/features/world/live2d_import_panel.dart) | `DEEDD78CCD03FD69BAE8288959AAB3CDB24B396690DCBFCD1A3AFC87FD9A91D8` |
| [Local import entry](../lib/features/world/live2d_local_import.dart) | `BE6DB7922BE2C5B9490D44257F57F81411067DA29945DF83A1AD759515910BDB` |

Each PNG is direct `RenderRepaintBoundary.toImage()` output, not a native window screenshot, mock design, generated image, or retouch. The [opt-in capture driver](live2d_world_capture_test.dart) asserts World, the completed setup copy, the existing pending 3D copy and performance action, and phase-specific absence/presence of **选择 Live2D ZIP**. For After, it also verifies the action is visible and enabled without tapping it. This evidence covers the resting entry only, not native picker behavior, archive import, real model rendering, or host/device acceptance.

## Reproduction

Use Flutter 3.50.0 (framework `ab2912035e`, engine `371f77202a`) and Dart 3.14.0. In both checkouts, use the same client dependency lock (SHA-256 `1BD53182D4767917EF2291C46EF18CFB85C4EAE15B357F5F5246FE43AB7390FC`). Copy the unchanged capture driver to `apps/client_flutter/evidence/` in each checkout. From each checkout's client app in PowerShell:

```powershell
flutter pub get --offline
$phase = 'before'  # Use 'after' on the implemented source.
$png = Join-Path (Get-Location).Path "evidence/live2d-reproduced-$phase.png"
$cjk = Join-Path $env:WINDIR 'Fonts/simhei.ttf'
$flutterBin = Split-Path (Get-Command flutter).Source
$icons = Join-Path $flutterBin 'cache/artifacts/material_fonts/MaterialIcons-Regular.otf'
flutter test --no-pub evidence/live2d_world_capture_test.dart `
  --dart-define="CAPTURE_PHASE=$phase" --dart-define="CAPTURE_PATH=$png" `
  --dart-define="CAPTURE_CJK_FONT=$cjk" --dart-define="CAPTURE_ICON_FONT=$icons" `
  --reporter expanded
```

The evidence driver loads the system SimHei font (`9B1959DB3B3ABEB7EFDAEC26EDF7DFE871A6039DE8D614AF7248575207BE629E`) under both `Ahem` and `Roboto`, covering the test default and explicit Material text styles. It uses Flutter’s Material icon font (`D9865B671A09D683D13A863089D8825E0F61A37696CE5D7D448BC8023AA62453`). Font files are not redistributed. The capture test passed once per phase; a second Before run reproduced the PNG byte-for-byte. Windows Simplified Chinese OCR decoded both PNGs at 1280×960 and recognized **世界与形象**, setup status, **3D 渲染**, and the performance entry in both; it also recognized part of the new Live2D label and the no-upload copy in After. The capture test verified the full label exactly. OCR and driver assertions are not substitutes for human visual review; image input was unavailable in this worker session.
