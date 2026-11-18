# Owner AI chat shortcut — Flutter render comparison

| Scene | Revision | Production shell capture |
| --- | --- | --- |
| Settings, already-authorized AI row, before | `32ac64f54358bf8e7837a566ea225bf966322c38` | [Before PNG](owner-chat-before-32ac64f.png) |
| Same Settings row, after | `4770984e4a1c31b3b2e09012e6d68198000351a0` | [After PNG](owner-chat-after-4770984.png) |
| After explicitly tapping the shortcut | `4770984e4a1c31b3b2e09012e6d68198000351a0` | [Opened chat PNG](owner-chat-after-4770984-open.png) |

The PNGs are unedited renders of the production `WhaleChatApp` widget tree, not mockups. Both Settings captures use the same unlocked synthetic owner, ready/enabled consent, canonical direct ID, Settings scroll anchor, and light theme. The capture area is the entire app's `RepaintBoundary` at 390×844 pixels (DPR 1), without an OS title bar. Both runs used the same Windows CJK and Material icon test fonts and dependency lock (SHA-256 `1BD53182D4767917EF2291C46EF18CFB85C4EAE15B357F5F5246FE43AB7390FC`). The driver asserts that the authorized row appears in both runs, only After has the shortcut, and an explicit click opens the expected composer without a consent mutation or message send. PNGs were re-rendered at the listed revisions and are byte-identical to the previously recorded respective scenes. They do not show the transient busy state; the dual-AI widget regression tests that state separately.

## Reproduce

1. Use isolated worktrees at the listed revisions. From this evidence revision, copy [the driver](owner-chat-capture.dart.txt) into each app's `test/owner_chat_capture_test.dart`. In the Before worktree only, copy [the baseline fixture template](owner-chat-before-fixture.dart.txt) to `test/owner_chat_entry_test.dart`, the import path expected by the driver. This fixture uses only APIs available at `32ac64f`; do not copy the newer regression test into Before. For After use the [fixture already tracked at `4770984`](../test/owner_chat_entry_test.dart) without replacement. Run only the capture test in these worktrees.
2. Resolve both apps with the same Flutter SDK and lockfile (`flutter pub get --offline`). Use Windows `simhei.ttf` and the Flutter SDK's `bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf`.
3. In each isolated `apps/client_flutter` directory run the following, setting `$out` to an absolute PNG path prefix, `$after` to the literal `false` for Before or `true` for After, `$cjkFont` to the Windows font path and `$iconFont` to the SDK font path:

```powershell
flutter test --no-pub test/owner_chat_capture_test.dart --dart-define="CAPTURE_PATH=$out" --dart-define="CAPTURE_AFTER=$after" --dart-define="CAPTURE_CJK_FONT=$cjkFont" --dart-define="CAPTURE_ICON_FONT=$iconFont" --reporter expanded
```

The test writes `$out.png` and, for After, `$out-open.png`. The driver assertions and dimension/nonblank checks passed. This is not native-device acceptance, actual host or live-model validation, or independent visual approval. No real account data or credentials were used.

PNG SHA-256:
- Before: `2F9D97B4B439DBDE3758E290F8C30840505B6342F0820BBD59FC4B03326AF264`
- After: `9E186E1CB7993C69913FDF8524ADE261A80436BFF3D609687DC6CC5E185A5067`
- Opened chat: `182DCA3400F8D4C85993C19C503F26418C9759D4C309A22ED767E19C94EA0340`

The shortcut makes two authorization/visibility GETs with renewal disabled. It does not register profiles, mutate consent or messages, rotate authentication, sync message bodies, or drain the outbox. Existing host GET authentication may touch the device's `lastUsedAt`. The reads are not atomic with a later send, which the host still authorizes independently. If cached Settings consent looks enabled after remote revocation, the live check still refuses entry; no automatic refresh or registration is triggered.
