# PurismCore feasibility result

This is a bounded runtime investigation, not a production selection or a Live2D delivery claim.

## Result

PurismCore v1.1.0 is an MIT-licensed candidate with released WASM v5/v6 cores and a Raylib WebGL2 sample viewer. The supplied model's MOC3 was tested locally (the model and the containing archive are deliberately not included here). Both released cores accepted its MOC3 consistency check, created a model, and completed one update with `updateError=0`.

Evidence: Core v5 reports MOC version 5, consistency 1, 509 parameters, 147 parts, 715 drawables, canvas 3749 x 7697. Core v6 reports the same model counts. Upstream commit/tag: `1069334965522df5d0b791e97f01e26b19c45456` (`v1.1.0`). Release Web ZIP SHA-256: `ee229d1b28c33a9f57f02c777f8633141042cd771e5e47bf4795ba345b3a0b39`.

## Limits and risk

Core parsing/update does not prove image correctness, Flutter WebView integration, animation, physics, masks at device scale, model swapping, performance, or legal conclusions about assets/formats. The upstream Raylib/WebGL2 viewer explicitly describes itself as incomplete: it lacks physics and a proper JSON parser, and its model3 parser only selects MOC/texture data. Its ZIP loader is not a security boundary for this application.

The provided model references five textures. Their IHDR sizes include an 8192 x 8192 atlas; decoded RGBA8 base textures total about 592 MiB before mipmaps, WASM/model copies and masks/offscreen buffers. Mobile WebView GPU limits and memory may make the unchanged texture unsuitable. Validate `MAX_TEXTURE_SIZE`, memory and sustained frame rate on representative Android hardware or obtain an approved downsampling policy.

The repository's pure-Dart `validateLive2DPackage` was also run against the supplied archive locally: it returned `ok=true`, resolved the model3/MOC3 references and five PNG textures, and measured 155,189,248 total texture pixels under its default 200M limit. That is a metadata/byte check only, not a render or device-memory test.

The supplied model notice separately asks for attribution and prohibits redistribution; some commercial product-inclusion cases ask users to contact the author. Do not bundle or redistribute this model. PurismCore's MIT runtime license does not establish model rights, Cubism SDK rights or trademark/format legal conclusions. Retain creator attribution when the user's local model is used. No Cubism SDK/Core binary was downloaded or bundled.

## Browser renderer diagnostic (not an app preview)

On the Windows development machine, a private loopback-only diagnostic staged the supplied model's MOC3 and five textures under generated names, with a minimal manifest. It reused the pinned upstream `Samples/Viewer/viewer.js` and `viewer.wasm` rather than the upstream ZIP picker or a new renderer. In headless Edge with SwiftShader, the upstream viewer updated its title to the loaded manifest and WebGL2 readback found 266,392 pixels differing from the background on an 866 × 623 canvas; the sampled GL error was 0 and `MAX_TEXTURE_SIZE` was 8192. The server was stopped after checking. Private inputs and captures are not included. This shows nonblank browser rendering for that sample; it does not establish visual fidelity, WebView security, native-device performance, motion, or correct fallback.

## Candidate integration, not implemented

A next prototype may adapt the upstream local WebGL2 viewer in a controlled WebView, subject to a separate safe importer, bounded JSON/archive parsing, texture dimension/pixel budget, no remote model URLs, local-only profile persistence, explicit mapping for mouth/blink/expressions/motions, and a narrow Flutter-JS bridge. The existing profile parser validates metadata only. The current repository has no model extraction, device persistence/UI, renderer, bridge, hot-switch, or verified VRM fallback.

## Verification method

The exact MOC3 was extracted privately to scratch and loaded via the published Core-v5 and Core-v6 WASM packages in Node 22.19.0. The test called the runtime version query, consistency check, `Moc.fromArrayBuffer`, `Model.fromMoc`, one `update`, checked last error, then released the model and MOC. This does not test the viewer or GPU renderer. Scratch scripts/archive/model are not part of the repository.

Upstream references:
- <https://github.com/SakuraMotion/PurismCore/tree/1069334965522df5d0b791e97f01e26b19c45456>
- <https://github.com/SakuraMotion/PurismCore/blob/1069334965522df5d0b791e97f01e26b19c45456/docs/VIEWER.md>
- <https://github.com/SakuraMotion/PurismCore/issues/3>
- <https://github.com/SakuraMotion/PurismCore/pull/4>
- <https://www.live2d.com/zh-CHS/sdk/license/>
- <https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html>
