# 模型能力与预算诊断 — matched Flutter rendering

| State | Production code revision | PNG / SHA-256 |
| --- | --- | --- |
| Before: Settings, no model diagnostics entry | `e7fdf7d` (baseline `main`) | [Before](model-diagnostics-before-e7fdf7d.png) · `1B3366B4F80A1EE5EBB8E2252895C8C6900CA8B7A23FD25CFD86F584F44537E1` |
| After: the same Settings view, entry present | `eeabfa8` (branch head at capture) | [After](model-diagnostics-after-eeabfa8.png) · `0F903C4756188EF18120BC70A7681F3504900148B433CA38FD63694302102B2B` |
| After (follow-on state, **not** part of the pair): the opened diagnostics screen | `eeabfa8` | [Opened](model-diagnostics-after-eeabfa8-opened.png) · `5CFC9CC2FCFDC516304F55DB2265E7C1C6B0EE58306BA827901099F2C19E73FA` |

## Scenario

Both revisions rendered the production `WhaleChatApp` with a real `ClientRuntime`
(`ClientRuntime` from `lib/app/runtime.dart`), driven through the real UI: the
driver taps the app bar's 设置 action, then deterministically scrolls the settings
list so the pre-existing `open-ai-config` tile (「AI 运行配置体检」) sits at the top
of the viewport. That tile exists in **both** revisions, so the scroll offset is
identical and the only difference between the two images is the delivered entry
plus the rows it shifts down.

Viewport 1280×960, DPR 1, light theme (`ThemeMode.light`), font scale 1.0. Both
worktrees injected the same Windows CJK font (`simhei.ttf`) as `Ahem` and the
same Flutter `MaterialIcons-Regular.otf` as `MaterialIcons`.

The dependency lock matched exactly in both worktrees:
`C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937`
(`apps/client_flutter/pubspec.lock`).

The [capture driver](model_diagnostics_capture_test.dart) is byte-identical in
both runs (`058397967E9ADD1BF39FB9B4517EEB6AE4A469B557489568DAEDB7869242684C`).

## Verification of the pair

- All three PNGs are 1280×960, `Format32bppArgb`, and have distinct SHA-256.
- A pixel comparison of Before vs After over the full frame shows every pixel
  above `y=112` identical (the app bar and title row are untouched) and the only
  differing region is `y=112…577` — the entry itself and the rows it displaces.
- The After run additionally asserts `find.byKey(Key('open-model-diagnostics'))`
  is present, taps it, and asserts the diagnostics screen title renders; the
  Before run has no such assertion because the entry does not exist there.

## Honest limits

These are **production-widget renderer comparisons in the Flutter test
harness**, not device, native Windows/Android, or live-host acceptance.

- The `HostConnection` is a fixture: it is not a host, makes no network request,
  and serves only what the shell needs to leave the onboarding gate. It carries
  no saved session, real account data, provider configuration or credential.
- The rendered diagnostics screen shows its **unbound** state in the follow-on
  image because the fixture supplies no read loaders. The images therefore do
  **not** demonstrate real model discovery, real recorded usage, a real rolling
  trend or a real budget read; those are covered by the adapter and screen unit
  tests, not by this screenshot.
- No real provider is contacted, so this is not evidence of provider interop,
  model availability, budget admission, or an authorized reply.
- The Before image is a genuine render of `e7fdf7d` in a separate `git worktree`,
  never a mockup or an edited screenshot.

## Reproduce

Run `flutter pub get --offline` in `apps/client_flutter` of each worktree, copy
`evidence/model_diagnostics_capture_test.dart` into both, then:

```
flutter test --no-pub evidence/model_diagnostics_capture_test.dart \
  --dart-define=CAPTURE_PATH=<absolute PNG path> \
  --dart-define=CAPTURE_CJK_FONT=<SimHei TTF path> \
  --dart-define=CAPTURE_ICON_FONT=<Flutter MaterialIcons-Regular.otf path>
```

On the delivered revision also pass
`--dart-define=CAPTURE_DETAIL_PATH=<absolute opened-screen PNG path>`.

The driver lives outside the default `test/` directory, so ordinary test runs
neither require these fonts nor emit screenshots.
