# Explicit one-message mention → rules-only curated S1 greeting

**Evidence label: actual app + capture-only native isolation patch; automated native tester.** This demonstrates a small, **rules-only curated S1 greeting—not model chat, general AI conversation or provider integration**. The response comes from the production curated rule catalog and is stored under a canonical AI account by the real host.

## Actual Windows comparison

| Scene | PNG | SHA256 |
|---|---|---|
| Before: same selected group and empty composer, no mention action | [Before group composer](<group-after-actual-native-message.png>) | `907651F06A4A4BDCC8406C318480EFDD2F746ED898BCB5A4A36DCF777A68EB2C` |
| After: same group/composer with explicit mention action | [After composer](<mention-after-actual-native-composer.png>) | `8B472DFB352A5AB25B890AEF8A4CFFA07F2142BB421DC203DE77D558644D655E` |
| After: confirm one known AI ID for this message | [Mention confirmation](<mention-after-actual-native-dialog.png>) | `8B0A82434AFB21D2160198E1E8243C984B390851DC57669777FB43926B368FF3` |
| After: actual human greeting and canonical S1 reply | [Rules-only reply](<mention-after-actual-native-reply.png>) | `D806A074732C25195216D3873E76F11561831DF894AA1EE92583DEB8FD2A97D9` |

Matched comparison uses the same synthetic group, existing prior human message, empty composer, light theme, **1280×960 logical**, **2560×1920 physical**, **DPI192 / DPR2.0**. A two-phase barrier resizes the real HWND, pumps actual Flutter frames, asserts actual View dimensions, then captures its client surface via GetDC/BitBlt. Dialog and reply are supplementary workflow evidence.

## Real execution and assertions

The local SDK integration entrypoint calls actual production `main()` and restores the synthetic session through actual native DPAPI/Credential Manager. It selects the real group, enters `你好` in the real composer, opens **提及 AI 并发送**, enters a known synthetic canonical AI account ID and confirms **once**. There is no direct private runtime-state mutation, mocked UI/network/native channel, fabricated authentication or injected reply.

The frozen production host was configured only through public authenticated APIs:
- Own AI creation and canonical profile registration, then group membership.
- Explicit social level **L1**.
- Explicit integer daily budget100, all five layer limits0, `chatFast` capability limit100 and other capability limits0; timezone offset **+480 minutes**. This deliberately enables the curated rules-degradation path without any model/provider.
- Group daily cap10, one reply per round, autonomous interjection off, hosting off, interval30seconds and unmuted status.

The UI sends the single message through the existing durable outbox. UI refresh/sync then displays `你好呀`. Independent second-human public HTTP sync asserts:
- Exactly one human `你好` message with `mentionAccountIds` containing only the selected AI account.
- Exactly one canonical AI-sender reply, after the human sequence, with body `{"text":"你好呀","source":"s1","activityRefs":[]}`.
- The reply is visible in the client and pending queue is0.

**Fresh native integration verification:**1test passed, exit0; Windows build127.0s, test43s. One earlier test-only attempt failed before sending because the harness omitted a frame pump after composer entry; one approved minimal harness synchronization correction was applied. No production changes or extra business-message send were made for that correction.

## Source identity

- Before production group source: committed `6b85f004fa2fb92a8f5a460387bd80341feb8072` production-source snapshot described in the group comparison; not an unmodified released binary.
- After client capture tree starts exact `fbc4b9d261db929861bbeb4227edea1ea1e1b210` plus three-file mention diff SHA256 `B4253BD9DAB1AEB9ED567255365833D874ACB5D579EC13D38EF1C42659250487`. The three executed production Dart files were checked by Git blob identity against final committed client revision **`8752948855627b5d5b63698938d6eb9309e9f506`**:

| Production file | SHA256 | Git blob SHA-1 |
|---|---|---|
| runtime.dart | `5C5CB660A497CDA2648BBBB7A0B24299F3D883CF156487A0BD268B8F20092292` | `91e7e4c2201be268eb5fc09a146f9db1a7077007` |
| shell_view_model.dart | `6196E24905095ED5FAEC54CA300D21014993E4577E87E78D6C4140D66496E885` | `eb99beffe97c9036e7108cbef014512be83dfec3` |
| chat_pane.dart | `CCE36235CDC34EC67C6D21B8AE00870BE608CF95CC8B0F6F8DED1C160411545F` | `518798e138c6bc9c8488158fd9b6a052680bcfe0` |

- Host: exact **`47a19b0c05aaecb2ee151204e7ba6e2c67180209`**, production identical to greeting commit `8bc8aefd2718287733cbaf91a622c42c871c4dd2` (test-only base merge); no capture modifications to host production code.
- Same native isolation patch before/after: instrumented `platform_integration.cpp` SHA256 `01A04A40FD43B5E06205C7F94CDFC2A02A6C4A002775A702F2DEA3206B62DEB0`; actual `Shell_NotifyIconW(NIM_ADD)` and returned bool retained, fatal tray failure handled by the production failsoft change. Application data/credentials/shortcut/AUMID target a unique synthetic namespace; fixed hotkey and autostart side effects are disabled. The before/after native source matches byte-for-byte.
- Final capture-only SDK UI driver SHA256 `97992AFB61A354F68245AD7DF9B4CD14551AF7D4531C46FA7996AC37B5F1362F`. SDK dev dependency and test entrypoint are instrumentation; these are not exact unmodified released binaries.

## Limitations and safety

**No image-capable visual inspection was available to the model.** Native metadata, actual integration assertions and Windows OCR validate viewport/state/text; independent visual review is still required. No claim is made that clipping or visual defects have been ruled out.

This verifies one explicitly admitted curated greeting, not arbitrary prompts, autonomous replies, model quality, paid providers or complete AI chat. The UI warning correctly states that host policy decides whether to reply and does not guarantee a model response.

No owner native application data or credentials were read/exported/deleted. Only isolated synthetic accounts/state and loopback host APIs were used. Private fixtures, credentials, diagnostics, runtime metadata and databases are excluded from this public evidence set. Capture-only isolation means exact-unmodified Windows integration readiness is not claimed.
