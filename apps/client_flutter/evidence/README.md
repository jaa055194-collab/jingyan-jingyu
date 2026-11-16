# M11 PR8 — real onboarding UI evidence

## Scope and current status

This evidence compares the **credential onboarding increment only**. The real baseline is PR revision `6b06a3b11216f917f2df16d63adb1c11ae5c6766`, whose application already contains the actual host-address/invite-only onboarding. It is not a mock, widget golden, or generated image.

The original M11 baseline `3c81587` did not contain this Flutter app. Therefore these images **do not establish the earlier whole-shell before/after comparison**; that earlier comparison remains absent.

- Baseline Windows debug build and actual client-window capture: complete.
- Both baseline and current Windows debug builds exited **0**, and both actual client-window PNGs are available below. No shared production/build files were changed.
- Model image inspection was attempted on both images using `read_image`, but this runtime returned: `model "group/group" does not declare image input`. Windows OCR independently recognized both actual onboarding screens; this is **not a substitute for human visual review**.

## Baseline image

![Actual baseline host/invite onboarding](<pr8-before-6b06a3b-onboarding-light-1280x960.png>)

| Property | Baseline |
|---|---|
| Revision | `6b06a3b11216f917f2df16d63adb1c11ae5c6766` (detached worktree) |
| State | Initial onboarding, step 1/3; empty fields; no validation/error; no host connection attempted |
| Theme | Light (Windows `AppsUseLightTheme=1`, app defaults to system theme) |
| Client viewport | 1280 × 960 logical pixels; **2560 × 1920 PNG pixels at 192 DPI (200%)** |
| Captured region | Client content only, excluding native title bar, window borders, taskbar and unrelated desktop |
| Capture location | Client origin `(33,78)` on physical 3240 × 2160 display |
| PNG SHA-256 | `0004540EF75E14EFB0F2C5DA9D2A8651D9DD3F93B8FABBAB5B130AAD06B830D3` |
| Executable SHA-256 | `6389DE216E48F98BB2C0DB39BEFA11DA27DEF0BB0402A29F62CBA98AE2BA3BB0` |
| Onboarding source SHA-256 | `D1FD66FD073C816321C2C8D4AE372EF57ED5CC009B870FE00610FB7093180A3F` |
| Dependency lock SHA-256 | `2DC2F124E1F14AF0F6A5D0651D3774ACE479F1460A98D3ACBC9CF522E6FC88C4` (identical to current) |
| Final capture time | `2026-11-15T17:59:32+08:00` |

Windows OCR recognized: `初次设置 · 1/3`, `连接你的宿主`, the host-provided address/invite explanation, `宿主地址`, `邀请码`, and `连接宿主`. OCR contains normal recognition inaccuracies; no account information or credentials were entered.

## Current credential UI image

![Actual current credential onboarding](<pr8-after-a6ea6679-dirty-onboarding-light-1280x960.png>)

| Property | Current working-tree snapshot |
|---|---|
| Identity | Base `a6ea6679f381fbfbf0ea6691919ca44e6c60b70d` **plus uncommitted credential changes**, identified by source hashes below |
| State | Initial onboarding, step 1/3; default **new account** choice; all fields empty; no focus, validation or host connection attempt |
| Theme and client | Same light theme, 1280 × 960 logical / 2560 × 1920 physical pixels, 192 DPI, origin `(33,78)` |
| Final capture time | `2026-11-15T17:58:37+08:00` |
| PNG SHA-256 | `BCD6AE3EFC732426FF583D36269BA74411311689852F866BE1ABDE9DC41E7804` |
| Executable SHA-256 | `14D0DF645C016B3A94859AD51F76127DEA08005BDAD5ADE08AA44346F61D3D15` |
| Dependency lock SHA-256 | `2DC2F124E1F14AF0F6A5D0651D3774ACE479F1460A98D3ACBC9CF522E6FC88C4` |

Windows OCR recognized the initial onboarding title, host address, new/existing account choice, invite, display name, 100-character helper text, device name, account password, the new-account 12–1024-character helper, and the connect action. This confirms the full initial credential form was rendered in the capture without scrolling. No credentials or private data were entered.

## Build and capture methodology

1. Verified the unique short destination `PRIVATE_BUILD_WORKTREE_PATH_1` did not exist, then ran `git worktree add --detach <destination> 6b06a3b` without checking out or changing the shared branch. Worktree Git identity matched the configured repository identity. No commits or GitHub operations were performed.
2. Waited for the lead's baseline-build permission. Used local Flutter **3.50.0**, framework `ab2912035e160d9cad6306df307576da6128ebdb`, Dart **3.14.0**. Ran `flutter build windows --debug` in the detached app directory; dependency resolution ran automatically; build exited **0** and produced `build\windows\x64\runner\Debug\client_flutter.exe`. Network proxy was set only in the build process (`HTTP_PROXY`/`HTTPS_PROXY=http://127.0.0.1:7890`, `NO_PROXY=localhost,127.0.0.1`). Resolved `material_ui` was **1.11.0**, matching the current working-tree lock.
3. Before launch, verified that the app-data directory did not exist and that the app's secure session credential did not exist. Only credential existence was checked; no secret was extracted, changed or deleted. No credentials/private fields were typed.
4. Started the actual executable with its own working directory using `Start-Process -PassThru`, redirecting stdout/stderr into scratch logs, in a **separate command** from capture. The real Flutter process remained responsive; its log reported the Dart VM service and Impeller backend.
5. The scratch PowerShell capture script loaded `System.Drawing` plus a C# `Add-Type` P/Invoke wrapper. It called `SetProcessDpiAwarenessContext(-4)` (PerMonitorV2), then searched visible top-level windows by the launched PID with `EnumWindows`/`GetWindowThreadProcessId`, bounded to **15 seconds**.
6. Used `GetWindowRect`/`GetClientRect` to compute non-client borders, then `ShowWindow`, `SetWindowPos` and `SetForegroundWindow` to place/resize the real app. Requested exact **2560 × 1920 physical client pixels**, equivalent to 1280 × 960 logical pixels at the measured **192 DPI**. Verified exact client dimensions, foreground HWND, DPI and that the client rectangle fit entirely on screen.
7. Called **`GetDC(appHwnd)`** (client DC, not desktop DC), created a `System.Drawing.Bitmap`, and copied only its verified client rectangle using **`gdi32.BitBlt(..., SRCCOPY)`**, then saved PNG. No `CopyFromScreen`, full-desktop screenshot, mock widget/golden, image generation, retouching or cropping of a desktop image was used.
8. Attempted `read_image` inspection for both PNGs (runtime capability failure noted above), then used bounded Windows Runtime OCR to check each was a rendered onboarding screen rather than a spinner/blank image. Kept the original full-resolution PNGs, recorded hashes, and stopped only each verified owned app process after capture. Current and baseline apps were launched/captured sequentially, not overlapping.

## Prior failure investigation and limitations

The prior attempt combined executable launch, `Add-Type` and full-desktop `CopyFromScreen` in one command and was killed without a capture; direct invocation had also returned after printing a VM-service message. There was no useful retained log, so **the precise cause of that prior hang is unproven**. This run separated launch/capture, used explicit output logs and a bounded HWND lookup, and successfully captured the still-running actual baseline app.

An initial display probe in a DPI-unaware process reported virtualized 1620 × 1080 / 96 DPI. The DPI-aware capture measured the actual 3240 × 2160 display and 192-DPI app. A preliminary smaller capture was kept only in scratch; this evidence uses the corrected 1280 × 960 logical viewport. No Windows display setting or app production source was changed.

These captures establish the initial light desktop onboarding surface only. They do not prove successful authentication, the later character/room flow, mobile rendering, accessibility, or all interactive/error states.

### Current snapshot preparation

After the lead released current source, a Git `HEAD` ZIP plus working-tree overlay was copied into `PRIVATE_BUILD_WORKTREE_PATH_2`. All **47** app and local-package `lib` files were then copied and SHA-256 compared against the actual working tree, including the Git-ignored new account snapshot source. This avoids both shared build-file writes and accidentally omitting ignored source. Current base `HEAD` is `a6ea6679f381fbfbf0ea6691919ca44e6c60b70d`, **plus uncommitted changes**, not a new committed revision.

- Current onboarding source SHA-256: `5D81D394FCEAD75D79C71F60D69300A628645AEF1156E9B23BF12009244746B9`.
- Current runtime source SHA-256 at final source copy: `9A2A77816D28110F5AC33053E889C07CB4CBE3834CBBCA07A978D30034A7CDAA`.
- Current account snapshot source SHA-256: `D72BEC1A1ECD21784C4D7019C16B3FAF7A25DF2366451922CCED21248418F94D`.
- Capture script SHA-256: `F85DFE7527EBBD58AE98FE6B47151E297A21B9B0D89CF7D8114A503C98EC04BB`.

The first current scratch build failed because a Git-only overlay omitted the ignored account snapshot file; copying all actual library files resolved that snapshot omission. Two preceding scratch archive attempts failed (Git `tar` interpreted a Windows drive as remote; native `tar` rejected non-ASCII documentation paths). ZIP extraction succeeded. These failures did not alter production source. Abandoned scratch paths were retained, not deleted.

For a controlled comparison the baseline was rebuilt successfully (exit **0**) and recaptured with the **identical current dependency lock** (`2DC2F124E1F14AF0F6A5D0651D3774ACE479F1460A98D3ACBC9CF522E6FC88C4`, including `vector_math 2.4.3`), copied only into the baseline scratch worktree. This removes the fresh baseline resolver's initial `vector_math 2.4.4` skew; the baseline Dart/runner source itself remains revision `6b06a3b`.

## Main-recovery Settings own-AI increment — actual local application comparison

These are actual Windows debug application captures from locally built executables, using the same synthetic host fixture, native capture-only isolation namespace, 1280×960 logical viewport (2560×1920 at 192 DPI), system light theme and `flutter test integration_test` driver. No credentials or private message text are shown; only synthetic account IDs/names are visible.

- **Before:** recovered client foundation `e96918c2cc027c83617fc20452275a6bca652355` on main `58b9de0`, before the own-AI Settings increment. Settings scrolled to its final existing controls; OCR has no `我的 AI` section (`myAi=0` in the driver). [actual Before image](<settings-before-main-recovery-e96918c.png>) — PNG SHA-256 `A2623A9403FBF2B6A78BCE705007E4E6B7559FC971D74BFFE3DC26A29E370B95`, executable SHA-256 `B001EA87AD831F0CB59532A601919DC08160862607439E035841A2FBB477E259`.
- **After (loaded list):** recovered final client `128ea5f705f00413350e1c7982fbbb506b3ff43e` after the own-AI Settings increment, same host/viewport/theme, `myAi=1` and the synthetic list containing `Capture Rules S1` and the previously UI-created `Capture Settings AI`. [actual After loaded image](<settings-after-main-recovery-128ea5f.png>) — PNG SHA-256 `2572128D7D043AE17AE2FFAC58E0F937B735B91EAA52D493C2DC2BD613EFAF78`, executable SHA-256 `F51A3178A5AC8BE08F9E76B8C7FDD956C97DEA15289CC89A7F9F966CB29A7446`.
- **After (created through the real UI):** the driver opened the real Create AI dialog, entered `Capture Settings AI`, pressed Create, and the actual app displayed the server-confirmed canonical ID and a new list row. [actual After created image](<settings-after-main-recovery-128ea5f-created.png>) — PNG SHA-256 `A222AB382D2BF43FCF22C2137E627C55005BF0EB3A6CFBA8FBAA517F3CE29878`.

The baseline image is the immediate pre-increment recovered client, not an application on original `main` (original main has no Flutter client at all). This comparison establishes the Settings own-AI list/create increment only. It does not prove automatic model replies, AI readiness, whole-shell main-baseline acceptance, Android device acceptance, or complete product acceptance. Image input was unavailable to the model; Windows OCR confirmed rendered text (`我的 AI`, `Capture Rules S1`, `Capture Settings AI`, created-account notice) and the driver asserted authenticated/online/list/create state, but human visual review remains required.
