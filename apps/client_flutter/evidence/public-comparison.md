# Chat-first: actual Windows app Before / After

**Evidence label: actual app + capture-only native isolation patch; automated native tester.** These are actual Windows Flutter HWND captures, not mock UI or headless widget renderings, and not exact unmodified released binaries.

## Comparison

| Scene | PNG | SHA256 |
|---|---|---|
| Before: authenticated setup step2 | [Before step2](<before-actual-native-step2.png>) | `5E4D349920D4C19BB9EF27D3DF896D151A0544DBA86A0FBA14E755E6345DEE0E` |
| After: matched authenticated step2 | [After step2](<after-actual-native-step2.png>) | `A9D8CA84DBC382B1005C15FAC043AF83C5E0703D8292D289E8D7C1F728C6BFD3` |
| After: explicit defer action opens chat | [After chat](<after-actual-native-chat.png>) | `989A7BEA1B866C0408953915B4018224E8070986BA8BB4AB56FA3F074A3B5478` |

The baseline requires character/room setup before chat. The changed step2 adds “稍后设置，先进入聊天”; activating that real button reaches the existing empty chat shell. The account shown is synthetic capture data.

## Source and instrumentation identity

- **Before production source:** `7c5405f465a84fa67f1e31b392baa97bb18a5fdf`.
- **After production source:** that baseline plus reviewed four-file chat-first patch SHA256 `6231F49348C6178E6AD1DFC91D5760B91F0C76C70915E0D659310F8214C0359D`. These four files are included in changed revision `b53655d0acde8eb912fa36eea7b995e592d5bea9`, but the capture tree is a **source subset, not the full exact b53655d tree**; separate typed-network helper changes were not copied.
- Both use identical native capture instrumentation. SHA256 per file:
  - `capture_isolation.h`: `8D7B7B9E382B66A8BCCE201FDB92BAEF6543DE84D55F37992E534D147529A7DB`
  - `platform_integration.cpp`: `97F3D87900C5F4A49B6908B33F702BE93570200A22F11E77BA14074FC33DF98C`
  - `pin_store.h`: `95AD699EBF7BA9563C5C14C656C0AE1B36289CA5B3EE01A7CC68E4744A68EDA9`
  - `pin_store.cpp`: `D18E880C2BD71CE126DF444C5E2046CA21AB277662A0D00011D86D5CC64F4D52`
- Both use identical SDK integration-test driver SHA256 `1FCAD164E613F66316493D83E7F3450338A8849D7808C65DB2768F3FBB0AF504`. The driver calls actual production `main()`, fills real form controls and invokes actual UI buttons. Production UI, runtime and authentication adapters were not rewritten for capture.

## Scenario and capture contract

- Real synthetic host/account/device login through production public HTTP authentication APIs; actual native method-channel DPAPI/Credential Manager session storage, no fake authentication state or mocked HTTP/native channels.
- Same synthetic saved account/device state for the matched before/after step2 comparison, light theme, native DPI192/DPR2.0.
- Actual client area **1280×960 logical**, PNG **2560×1920 physical**. Two-phase barrier: external native resize → real Flutter `pumpAndSettle` → actual View dimension assertions → HWND GetDC/BitBlt capture.
- After step2 is captured before the real defer-button action; after-chat uses the same window, theme/DPI and identity after that action.

## Verification and limitations

- **Baseline native integration:**1test passed, exit0; Windows build52.5s.
- **After native integration:**1test passed, exit0; Windows build48.8s.
- Source inspection/static checks confirmed all application-owned persistence, credential, shortcut and AUMID targets redirected to a unique synthetic capture namespace; native patch files match byte-for-byte between before/after.
- Capture-only tray, global hotkey and autostart integration are disabled; shortcut/data/credential/AUMID destinations are isolated. Actual native tray creation failed in this desktop before the capture bypass. Thus these images do **not** verify exact unmodified Windows startup or readiness of tray/hotkey/autostart integration.
- UI state and viewport were verified using native metadata, actual integration assertions and Windows OCR. **No image-capable visual inspection was available to the model**, so independent visual review is still required; no claim is made that clipping or visual defects have been ruled out.
- No owner native app state or credentials were read/exported/deleted. Only synthetic capture data was used. Private diagnostics, fixture scripts, runtime metadata and host data are not part of this public evidence set.
