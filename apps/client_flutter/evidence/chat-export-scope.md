# Chat-history export scope — application comparison

| Capture | Production revision | Export result summary |
| --- | --- | --- |
| [Before](chat-export-before-84410bd.png) | `84410bdaae5c658f0ccf1cccee01b25736dabed9` | A successful package summary does not explain its partial coverage. |
| [After](chat-export-after.png) | `091c7ccac2a0167b935d30123bf9b92c9397e8eb` | The same summary explicitly says chat history only, excludes persona/memories/attachment content, and is not a full account backup. |

Both PNGs are unedited production `BackupQuotaScreen` renders in a Windows Flutter 3.50.0 harness. They use the same light theme, 390 × 844 viewport, DPR 1, fonts, synthetic partial bundle, and actual `LifecycleApi`/`HostConnection` parser against a loopback fixture. The result notice is bottom-aligned in the scroll view in each run; the additional warning makes the notice taller and shifts the preceding visible content.

Each test asserts three read GETs and one export POST only after the explicit button tap, with no import or other write. Raw chat text is never rendered. Both tests passed, and the promoted PNGs passed full decoding, opacity, dimension and SHA-256 checks. This is not native device acceptance or a restore exercise.

Host-side behavior is independently covered by [the authenticated default-host regression](../../../apps/host/test/default_host_chat_export_test.dart) and [source/limit regressions](../../../apps/host/test/chat_history_export_source_test.dart): actual current-account chat suffixes, final batch membership check, denied histories, checksums, and safe failures. The capture fixture does not substitute for those tests.
