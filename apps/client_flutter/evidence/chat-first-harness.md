# Chat before optional world setup — widget-harness evidence

## Scope and limits

This increment permits an authenticated, unlocked account to choose **稍后设置，先进入聊天** before character/room setup. It does not create an avatar/room, mark world onboarding complete, add AI replies, or release the existing PR #8 merge hold.

These PNGs are **headless Flutter widget-test renders of actual application widgets**, driven by a synthetic UI model. They are not native application screenshots, not live-host acceptance, and not generated/retouched images. Native exact-baseline capture is missing. The available model cannot inspect images; human/image-capable visual review remains required. This evidence does not make the UI increment ready for acceptance.

## Revisions and matched scenario

- Before application source: exact PR #8 head `7c5405f465a84fa67f1e31b392baa97bb18a5fdf`, separate detached checkout; only the evidence test was added.
- After: the same base plus the four app-local source changes in this increment. Source hashes below identify the uncommitted snapshot.
- Both: authenticated synthetic new-account success, character step (2/3), no error/focus, light theme, 1280 × 960 logical and PNG pixels, DPR 1, Flutter 3.50 / Dart 3.14.
- Same resolved dependency lock in both runs (`vector_math 2.4.4`, `material_ui 1.11.0`). System Microsoft YaHei font bytes were loaded only by the test harness; no system font is redistributed.
- The third image shows the chat shell reached by the new explicit defer action. It is a follow-on state, not a same-state before comparison.

| Render | PNG SHA-256 |
|---|---|
| [Before: authenticated character step](chat-first-before-7c5405f-step2.png) | `F0699F539211AC5BC47E4D1D6D18B2D0F0D66F081FD05907D520E0672DB3F7F9` |
| [After: same character step](chat-first-after-step2.png) | `AB8BDA650FBB0B7C1779624784F6DFC03B8C8E888A2097425AC702EB17AB61BC` |
| [After: reachable chat shell](chat-first-after-chat.png) | `805E955E19C1C160158F9A99430A52C1988D73A3818EA52E1E7DEAB10073B083` |

## Reproduction

Copy `test/chat_first_evidence_test.dart` unchanged into the baseline checkout; its UI-model import uses the original baseline test model. Use an identical dependency lock in both checkouts.

```powershell
# Before: exact baseline application widgets
flutter test test/chat_first_evidence_test.dart --update-goldens --dart-define=CAPTURE_CHAT_FIRST=true --dart-define=CHAT_FIRST_BASELINE=true --reporter expanded
# After: changed application widgets
flutter test test/chat_first_evidence_test.dart --update-goldens --dart-define=CAPTURE_CHAT_FIRST=true --reporter expanded
```

The evidence test is opt-in; normal test runs skip image generation. No native client was launched on the owner's profile.

## Source identity (rendered intermediate snapshot)

The headless after PNGs above were rendered before the final review corrections (optional-route lock/logout shielding, restored-onboarding identity reset, terminal refresh rejection and short-height scrolling). They are retained as intermediate flow evidence, **not exact final-source render evidence**. The final native-isolated capture is a separate pending task; do not relabel these images as that capture.

Final reviewed source hashes:
- `lib/app/runtime.dart`: `5C8720E8C072CC8477A6C6B67F093CEC823D3F1AA56D8F699853C15E7A4FC356`
- `lib/app/shell_app.dart`: `D4EB4B138796EFEB0CC4E4404C1E0DD27BD449662CA73A89434C9D40CD130AD5`
- `lib/app/shell_view_model.dart`: `7D16535D2ABE76F3CD1AEFD7933A9730B6BF40FA6ED81A273D38EB60A26FCFF3`
- `lib/features/onboarding/onboarding_screen.dart`: `FD12D9F9D452F70EF05D69E7492F2B578E98D9C3381EF2439E7768141C86D8CD`

The table below records the earlier source actually used for these PNGs, not the final reviewed source:

| App-local source | SHA-256 |
|---|---|
| `lib/app/runtime.dart` | `7173F456B0336C3F4E6FFDCCA500FEFAEE0680312A2349D71CB1A30D194C85B6` |
| `lib/app/shell_app.dart` | `F7E8D7481F57B65C2552630B1379CC0084D68A38598ACE0162EA191DBEC50A49` |
| `lib/app/shell_view_model.dart` | `7D16535D2ABE76F3CD1AEFD7933A9730B6BF40FA6ED81A273D38EB60A26FCFF3` |
| `lib/features/onboarding/onboarding_screen.dart` | `068536D19F0070BB94F53BDCA8A2A18DA10EE8E7E539FD7A930D7E7ACF042C72` |

## Behavioral verification notes

Initial implementation preceded its new regression test; no red-first claim is made. The scoped production files were backed up outside the repository, temporarily restored to the baseline, and the baseline-compatible regression failed because the defer action was absent. Restoring the implementation made that same test pass. Additional lock, unauthenticated-gate and credential-untouched tests failed before their respective corrections.

The choice is now stored in the existing host/account/device snapshot, not protected credential JSON. World completion remains false. Restored sessions, identity isolation, lock denial and no-session denial have dedicated runtime tests. Existing token-rotation and credential-write behavior was not changed; a known terminal refresh 401 now removes authenticated chat-entry eligibility while transient transport failure retains cached-session behavior. An existing retry test raced the initial background flush; it now waits for the runtime's completion notification before testing manual retries. New fixture tests likewise wait for background refresh completion before deleting temporary snapshots. Three Important review findings were reproduced as failing tests and corrected: retained optional setup routes shield account data through lock/logout/recovery, restored setup resets to credential entry on identity loss, and terminal rejected refresh cannot persist a defer choice. A 375×350 viewport at 1.5 font scale reproduced a 58px World-tab overflow and passed after adding a scroll container.
