# Chat attachment send — matched application captures

| Capture | Production revision | Result after the same attachment action |
| --- | --- | --- |
| [Before](chat-attachment-before-342fe23.png) | `342fe238f640c808e5ecec40af9a40b4004efad2` | Add File shows the unavailable banner; no picker call, upload, or message. |
| [After](chat-attachment-after.png) | `63494fc38d32159de1ff665c428dd9200de2c0ed` | Add File stages `report.pdf`. Tapping **发送附件** sends once. Refresh shows the canonical message and an empty outbox. |

Both unedited captures use the production `WhaleChatApp` and `ClientRuntime` rendered by Flutter 3.50.0 on Windows at 390 × 844, DPR 1, light theme and the same fonts. The two runs use the same synthetic account, conversation, initial consent, file and loopback fixture. The system picker result is injected in the test harness. Neither capture is a native system-picker, live-host, or device acceptance result.

The driver asserts no upload or message request before confirmation. After confirmation it asserts one initiation, one chunk, one completion and one message submission. It reads back the canonical chat message through sync and checks its visible filename. Both capture tests passed; the PNGs passed full pixel decoding, dimension and SHA-256 checks. See the [runtime regression tests](../test/runtime_attachment_send_test.dart) for cancellation and error cases.
