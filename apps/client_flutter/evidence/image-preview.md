# Received image preview — application comparison

| Capture | Production revision | Result for the same synced image message |
| --- | --- | --- |
| [Before](image-preview-before-6174d6a.png) | `6174d6a59a70bb2aba143b9ff7989095b2162082` | The bubble shows only `report.png`; there is no way to open it. |
| [After](image-preview-after.png) | `6dd0e5663d91a133aa70132235ffd981836fbc08` | The same bubble offers **查看图片**; one explicit tap fetched the image once and the production dialog displayed it, then closed with no further request. |

Both unedited images are production `WhaleChatApp` with `ClientRuntime` on Windows Flutter 3.50.0, 390 × 844, light theme, DPR 1 and identical fonts, using the same synthetic authenticated account, one selected conversation and one canonical synced image message. The loopback host serves the real message-scoped route with a tiny valid PNG; this is a harness render, not device, native or live-host acceptance.

The driver asserts an empty outbox, no non-GET request, and no content request before the tap. After the tap it asserts exactly one message-scoped content request, a verified digest and size, and the dialog rendering the image. Neither capture renders raw chat text or an absolute path. Both tests passed; PNGs passed full pixel decoding, opacity, dimension and SHA-256 checks. Subjective visual approval was unavailable on the text-only model.

Behavioral coverage lives in the host route tests (member, anonymous, non-member, joined-late, recalled, text, cross-conversation, forged edit, deleted blob, oversize, malformed ids, headers) and the client API/runtime/widget tests. Known limits: no document or video viewing, no save/download channel, no pre-join or admin access, and no device verification.
