# Local VRM first-frame feasibility

**#131, task-9, baseline `e5c89f3`.** The [developer smoke test](<../../tool/vrm-preview/smoke.test.mjs>) loaded an original VRM 1.0 GLB, drew a nonblank frame in Edge WebGL2, read it back from the canvas, and disposed of the model and context. The rig is [synthetic test data](<../../tool/vrm-preview/synthetic-fixture.mjs>), **not a production avatar asset**. See the [fixture license and dependency notices](<../../tool/vrm-preview/THIRD_PARTY_NOTICES.md>).

## Reproduce

Prerequisites on Windows: Node.js 22+ with npm and an installed Microsoft Edge that permits headless WebGL2 with ANGLE SwiftShader. The tool uses that Edge, not an existing browser profile, GUI, or downloadable Playwright browser. The first command that loads packages needs the npm registry, or an already-populated cache for offline installation.

From the repository root in PowerShell:

```powershell
Set-Location tool/vrm-preview
$env:npm_config_update_notifier = 'false'
npm.cmd ci --registry=https://registry.npmjs.org --ignore-scripts --no-audit --no-fund --cache .cache/npm
npm.cmd test --offline --cache .cache/npm
```

A subsequent `npm.cmd ci` with `--offline` was also verified with the populated cache. The [lockfile](<../../tool/vrm-preview/package-lock.json>) pins Three.js `0.180.0` (MIT), `@pixiv/three-vrm` `3.4.3` (MIT), and Playwright Core `1.56.1` (Apache-2.0, test driver only). No install scripts or browser downloads are needed. If Edge cannot launch or create a WebGL2 context, the test fails instead of falling back to a placeholder. Test output gives the actual browser/renderer and pixel measurements; the screenshot is regenerated at `.cache/first-frame.png` within the tool.

The test binds an ephemeral server to `127.0.0.1` with an exact file/fixture allowlist. The generated GLB is self-contained. The browser context blocks every page resource outside the exact loopback origin and allowlist, blocks service workers, and checks for blocked requests, policy violations, and uncaught errors. The server sets a restrictive resource policy; the [preview](<../../tool/vrm-preview/preview.mjs>) rejects redirects and GLB sidecars. No CDN, app server, external renderer, or external asset is needed at runtime. This check covers page resources, not a system-wide browser/network audit.

## Measured evidence

| Item | Observed on 2026-11-20 (Asia/Shanghai) |
| --- | --- |
| Software | Windows 11 Pro x64 build `26200`; Node `22.19.0`, npm `10.9.3`, headless Edge `157.0.4341.60` |
| Hardware and WebGL | Intel Core i7-8650U (4 cores, 8 threads); Windows enumerated Intel UHD Graphics 620 and NVIDIA GeForce GTX 1060. WebGL 2.0 (OpenGL ES 3.0 Chromium) used ANGLE Vulkan 1.3 SwiftShader (Subzero), **software rendering**, not either physical GPU. |
| Scene | One original VRM 1.0 humanoid with a skinned mesh and 15 bones, no textures; GLB `8,860` bytes, SHA-256 `8ae0dd9b171244c2191f1d8aefd02dac49e5e360bc67dc976c6b74802abb0722`. |
| Frame | Viewport 640 x 480 CSS pixels at device scale 1; drawing buffer and capture 320 x 240. `9,668` pixels with nonzero alpha; bounds `[79,18,240,216]` (left, bottom, right, top in WebGL coordinates); head RGBA `[61,156,244,255]`, torso `[248,135,38,255]`, clear corner `[0,0,0,0]`; `gl.getError()` was `0`. |
| Lifecycle | Local GLB fetched successfully, `VRMLoaderPlugin` constructed the humanoid, `vrm.update(0)` ran before rendering. Repeated teardown disposed geometry and material once each and released the WebGL context. Eight page requests on the success path (document, six local JS modules, GLB); none outside the allowlist. |
| RED then GREEN | Before adding the renderer, the browser loaded the harness and the first-frame assertion failed because `/preview.mjs` was absent. After implementation, all 7 cases passed: first frame and disposal, HTTP 404, malformed GLB, plain glTF, a valid but fully transparent VRM rig, a remote URL, and a GLB with an external buffer. |

[Captured Edge frame](<../../tool/vrm-preview/evidence/synthetic-first-frame-edge.png>) (SHA-256 `fb6e25ea6031d6404e971b5c4e0d29e10a3aaea48c823b974a08e8985c8a44e6`). The check reads WebGL pixels directly; the screenshot is supporting evidence, not the pass condition.

The baseline repository check (`tool/check.ps1`) also ran. All five Dart analyzers reported no issues. Their test suites could not load in this deep Windows worktree: `test_core` called `frontend_server_client`, which failed to spawn `dartaotruntime.exe` via the relative SDK path (Win32 file not found despite the executable and AOT snapshot existing). This is separate from the browser run; no Dart test or Flutter client test is claimed as passing here.

## Scope and remaining work

This is a renderer feasibility input for [M10](<../modules/M10-world.md>) and [FR-38/39 in v4.2](<../../鲸言鲸语-需求规格-v4.2.md#L282-L294>), not product acceptance. The current rules are per device: each device keeps its own Live2D model and mapping, with no account-level synchronization; a device lacking either uses VRM and does not fetch another device's model. This tool does not implement that selection or fallback, bind avatar cues, switch at sentence boundaries, or touch the parallel Live2D investigation (#128).

There are no changes to Flutter, application UI, Android WebView, Windows WebView2 or native code; no SDK/Core, model from a person or template, or npm dependency is bundled in the application. There is no importer for arbitrary files, animation loop, transfer of model data between devices, or performance benchmark. AC-25/26 and NFR-04 remain unverified by this work. Production work would need separately licensed asset selection, a bounded local-loading path in the target containers, tests of switching/rollback with audio, and real device and scene-load measurements.
