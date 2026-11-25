# Joined history sync — member view comparison

| Capture | Production revision | Same late-joining member opening the group |
| --- | --- | --- |
| [Before](joined-history-before-4d08323.png) | `4d083233100797db5030a5a1931f7220842f7814` | The group opens but is shown offline, without the member's first visible message. |
| [After](joined-history-after.png) | `e6e47e860b7ddb737d7d0c9983d8143a41296a9e` | The group stays online and displays the message sent after joining. |

Both unedited PNGs come from the production `WhaleChatApp` and `ClientRuntime` in a Windows Flutter 3.50.0 Skia test run, at 390 × 844, DPR 1 and light theme with matching fonts. Both fixtures use a fresh local account snapshot and the same synthetic member and group. The host supplies only seq 3 in response to the first sync at cursor 0; the updated reply also confirms the visibility floor (seq 3) while the baseline does not have that field. No message sent before joining is in either response. The test taps the group in the real shell and checks status, the visible message, the stored cursor, and that neither run attempts a send.

Both captures passed the app assertions, PNG decoding and digest checks. No app layout, live host credentials, or device acceptance is involved. The [runtime regressions](../test/runtime_joined_group_sync_test.dart) cover additional pages, restart, and late responses during lock/unlock.
