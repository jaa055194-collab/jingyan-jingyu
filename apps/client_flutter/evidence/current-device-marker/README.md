# #131 A — Identify the current device in Settings

This slice builds on #156 and the account/session boundary in FR-04/FR-05 (device-list and sign-off behavior in FR-06 and AC-02d/e). It changes only the existing device-list response: the row for the device authenticated by the caller's bearer and matching Principal has `current: true`; all other rows keep the original fields. No client-side inference, route, storage schema, or sign-off rule changed.

## Matched peer sign-off confirmation

| Capture | Production revision | Host response and visible result |
| --- | --- | --- |
| [Before](<before-d916736.png>) | `d916736a7a94fce09d0ee92476571509169ce99a` | The [host rows](<before-devices.json>) have no marker. The app explains that it cannot distinguish the current device. The peer's confirmation requires typing the peer name, with the submit button disabled until then. |
| [After](<after-6a5c225.png>) | `6a5c22598837e70c1617637a23535a90831c02db` | The [host rows](<after-devices.json>) add only `current: true` on `fixture-local`. Only that row displays **本机**. The same peer still requires explicit confirmation but no name input. The current device still requires typing its own name. |

![Before: no current marker; the peer requires name entry](<before-d916736.png>)

![After: the host marks the current device; the same peer requires explicit confirmation](<after-6a5c225.png>)

The [host generator](<../../../host/test/current_device_capture.dart>) ran the production `buildHost`, SQLite storage, authenticator, and HTTP adapter on each listed revision. Each run used a fresh disposable database, the same fixed UTC clock, two real HTTP logins to a synthetic account, and `GET /api/v1/auth/devices` with the laptop's bearer on an ephemeral loopback port. The generator checks the row identities against those logins, replaces only generated device IDs with the same two aliases, and orders the two rows by alias role for display. It neither manufactures nor strips `current`. Credentials and their digests are not included in the render inputs. The two normalized arrays are identical after removing the single added marker from the After copy for comparison.

The [widget driver](<../current_device_marker_capture_test.dart>) feeds these files into the real `WhaleChatApp`, `ClientRuntime`, `DeviceSessionsApi`, and existing Settings device screen, with the transport and signed-in account state supplied by the fixture. It opens the same peer confirmation before typing, asserts the correct marker and confirmation controls, and captures the unedited render. It then checks that the local-device confirmation is disabled for no name or the peer name and enabled only after the local name is entered. Each run issued exactly one fixture list read and no revoke. Both runs passed (one test each).

Capture conditions: Flutter 3.50.0 (`ab2912035e160d9cad6306df307576da6128ebdb`), Dart 3.14.0 on Windows, same light theme, 1280 × 960 logical pixels at DPR 1 and text scale 1, same fonts and dependencies, scroll position 0. Both rows and the whole confirmation panel are in view. Full-pixel decoding verified both PNGs are opaque and nonblank. There are 198,923 differing pixels within `(18,171)–(1260,688)`; the comparison does not substitute for human visual review.

| Artifact | SHA-256 |
| --- | --- |
| [Before rows](<before-devices.json>) | `808BD0C53D03DD00FDF2374584F4CB1CAA7E72F2C786FB88D90AE2F4BA0146DF` |
| [After rows](<after-devices.json>) | `55B1A5767214428032F0AC541E1525B3C5715DD24821250DFCF01E28E987923A` |
| [Before PNG](<before-d916736.png>) | `007F96E076546ECB5D4919585B98B4EAA6B13C24BB4518E02B5FF0D656874F59` |
| [After PNG](<after-6a5c225.png>) | `FBA0BA5C753214F6E59B9778DAC187268B6F85647DE41D685CBF3C6B714B607C` |
| [Host generator](<../../../host/test/current_device_capture.dart>) | `FE8614C00CEBAB78842F3EB227AC78D17133FC5125ABC8265BF783A7F7BBEC1E` |
| [Widget driver](<../current_device_marker_capture_test.dart>) | `26B2526951B93DD58ED0733E5E704D152B93A4F8BF5D96CCE7D9CDF253A248C3` |
| Host dependency lock (both revisions) | `93C1A81AF3DF2EDAF545C33480F8F5BE1EC47D76B0D626771704CE70FC66CE41` |
| Client dependency lock (both revisions) | `C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937` |
| SimHei TTF | `9B1959DB3B3ABEB7EFDAEC26EDF7DFE871A6039DE8D614AF7248575207BE629E` |
| Flutter Material Icons OTF | `D9865B671A09D683D13A863089D8825E0F61A37696CE5D7D448BC8023AA62453` |

## Reproduce and verify

Extract or check out the two production revisions separately. Use identical drivers, fonts and dependency locks. From each revision's `apps/host`:

```text
dart pub get --offline
dart run test/current_device_capture.dart <absolute path to generated rows.json>
```

From each revision's `apps/client_flutter`, render the rows produced by that revision's host. Add `--dart-define=CAPTURE_EXPECT_CURRENT=true` for After only; this defines the assertion, not the contents of the rows.

```text
flutter pub get --offline
flutter test --no-pub --reporter expanded evidence/current_device_marker_capture_test.dart --dart-define=CAPTURE_ROWS=<absolute rows.json path> --dart-define=CAPTURE_PATH=<absolute PNG path> --dart-define=CAPTURE_CJK_FONT=<SimHei TTF path> --dart-define=CAPTURE_ICON_FONT=<Flutter Material Icons OTF path>
```

- **RED:** The [new host regression](<../../../host/test/accounts_http_acceptance_test.dart#L309-L390>) failed on the unchanged route: two device rows, zero marked. The initial test-helper error (decoding the plain array as a map) was corrected before recording this behavioral RED.
- **GREEN:** 7 tests passed across the focused host HTTP acceptance and account routes suites. The regression switches between same-name, same-timestamp devices with distinct login tokens, verifies account isolation and exact metadata keys, revokes a peer through the existing route, and checks that missing, invalid and revoked bearers receive 401. Existing AC-02d/e HTTP eviction, revocation and refresh checks passed in the same run.
- **Client:** 46 existing device session API and screen tests passed. Scoped host and client analysis reported no issues. The client source change is documentation only; older hosts still get the stronger confirmation fallback.

```text
# apps/host
dart test --reporter expanded --concurrency=1 test/accounts_http_acceptance_test.dart test/accounts_routes_test.dart
dart analyze --fatal-infos lib/src/accounts/accounts_module.dart test/accounts_http_acceptance_test.dart test/current_device_capture.dart
# apps/client_flutter
flutter test --no-pub --reporter expanded --concurrency=1 test/device_sessions_api_test.dart test/device_sessions_screen_test.dart
dart analyze --fatal-infos lib/net/device_sessions_api.dart evidence/current_device_marker_capture_test.dart
```

These are production-host loopback results and desktop widget-harness renders, not a device or live-deployment acceptance run. The captures did not submit a sign-off; the separate host test verified revocation. No emulator or device was launched or installed. Image viewing was not available in the agent runtime; visual review beyond the pixel and widget checks and full integration suites remain separate.
