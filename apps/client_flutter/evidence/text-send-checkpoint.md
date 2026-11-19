# Text send checkpoint — offline restart comparison

| Capture | Production revision | Restored chat after the same interrupted Send |
| --- | --- | --- |
| [Before](text-send-before-e43cde7.png) | `e43cde7a708030ebe89137d912b16952d2cbec22` | The composer has the original draft **and** a pending bubble for that text. |
| [After](text-send-after.png) | `e19c4335d28396ff19bf91aca43e6a1d1dfbad44` | The original draft remains editable; there is **no** pending bubble for the failed send. |

Both PNGs are unedited renders of the production `WhaleChatApp` and `ClientRuntime` on Windows (Flutter 3.50.0, Skia; light theme, 390 × 844, DPR 1, same CJK and icon fonts). The capture fixture used the same synthetic account, chat and input in both revisions. It allowed the actual Send tap to run, rejected the write that would clear the already-saved draft, then started a fresh runtime against the same local file. Read-only chat discovery was available on restart; message submission and sync were unavailable. Neither run delivered a message to the host.

The capture tests asserted the restored composer and pending count using the real app widgets, and the PNGs were independently decoded and checked. All differing pixels were within the message/queue area (x 81–373, y 140–429). This is not native device acceptance or subjective visual approval. The deliberate write failure uses the same persistence seam covered by the [runtime regressions](../test/runtime_text_send_test.dart).
