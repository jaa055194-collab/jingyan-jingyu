# Group chat: actual Windows app comparison

**Evidence label: actual app + capture-only native isolation patch; automated native tester.** Actual Windows Flutter HWND surfaces, real production UI/runtime/public host APIs/native DPAPI session storage; not mocked UI, fake authentication state or an exact unmodified released binary.

## Images and hashes

| Scene | PNG | SHA256 |
|---|---|---|
| Before: empty chat without group creation | [Before empty chat](<after-actual-native-chat.png>) | `989A7BEA1B866C0408953915B4018224E8070986BA8BB4AB56FA3F074A3B5478` |
| After: matched empty chat with create/refresh actions | [After empty chat](<group-after-actual-native-empty.png>) | `483C687BBC971D5C69C3B834D748DEEC98276BEC2B16F86B48DFEF901105C267` |
| After: real named-group dialog | [Create dialog](<group-after-actual-native-dialog.png>) | `74C18C1BEF991771734E4BFB9A99E093FB3E095464631ECDB9939AE792B2344A` |
| After: selected server-created group and sent message | [Group message](<group-after-actual-native-message.png>) | `907651F06A4A4BDCC8406C318480EFDD2F746ED898BCB5A4A36DCF777A68EB2C` |

All use light theme, native DPI192/DPR2.0, actual rendered1280×960 logical client area, PNG2560×1920 physical. Two-phase external resize→Flutter `pumpAndSettle`→actual View dimension assertions→GetDC/BitBlt capture ensures the screenshot corresponds to the rendered viewport, not just window dimensions.

## Source identity

- Before is the prior chat-first capture: baseline `7c5405f465a84fa67f1e31b392baa97bb18a5fdf` plus four-file reviewed chat-first patch SHA256 `6231F49348C6178E6AD1DFC91D5760B91F0C76C70915E0D659310F8214C0359D`, a production-source subset included in `b53655d0acde8eb912fa36eea7b995e592d5bea9`, not that full exact tree.
- After starts exact `b53655d0acde8eb912fa36eea7b995e592d5bea9` plus six-file production group/tray-failsoft diff SHA256 `37A0BD50A9011298AFB55755DC8C49774052853E28F6B1FDA84812C20F82387C`. All five changed production Dart files were verified byte-for-byte by Git blob identity against committed revision `6b85f004fa2fb92a8f5a460387bd80341feb8072`; the native one-line failsoft semantics also match, with capture-only isolation/diagnostics added. Local tests/docs/SDK entrypoint are capture instrumentation, so this is not an exact unmodified binary.
- After native instrumented `platform_integration.cpp` SHA256 `01A04A40FD43B5E06205C7F94CDFC2A02A6C4A002775A702F2DEA3206B62DEB0` retains **actual** `Shell_NotifyIconW(NIM_ADD)` and its real returned bool. Native capture namespaces redirect all application data, credential, shortcut and AUMID resources; fixed global hotkey and startup writers remain disabled.
- Before native instrumentation SHA256 `97F3D87900C5F4A49B6908B33F702BE93570200A22F11E77BA14074FC33DF98C` bypassed unavailable tray creation. **The group comparison does not use identical tray instrumentation before/after**; this native difference is disclosed. The production UI comparison is source-identified, and no owner native state is used.
- Group SDK native UI driver SHA256 `5EB2A8B5AFC631ADE1B3D9382CF18FAD191D58678D3CECFC47BA658047D2F8FC`.

### Committed production Git blob identities (`6b85f004`)

These identify the committed production source, before capture instrumentation:

| Production file | Git blob SHA-1 |
|---|---|
| runtime.dart | `d2a8ab510e0411295f89b07faf1f845d02999295` |
| shell_view_model.dart | `479b4cb169176e0301af288b7275aa293a6692be` |
| conversation_mapping.dart | `be3c80b6a4bcadc365b0c1cd250bf5925f0c7ca3` |
| shell_app.dart | `9c5e4e074353d2599c778e21b252bf45c4778a61` |
| chat_pane.dart | `189da00e84922d3a1d0bcc606825ea14833c0a6c` |
| platform_integration.cpp | `1c7d30689577bb66eacbdeeda63fc79aa9fea7f6` |

The five Dart blobs equal the files executed in the capture tree. Native source has the separately hashed isolation/diagnostic changes described above; it is not the unmodified production blob.

## Real two-human verification

The driver calls real production `main()`, restores the existing synthetic account/device session through actual native DPAPI/Credential Manager and performs only real UI actions for the first human:

1. Click **创建群聊**, enter `Capture Group`, confirm creation.
2. Confirm the group is returned by the host and selected; click the real add-member action and enter one known second synthetic human account ID.
3. Enter `Real Windows UI capture message` in the real composer and click **发送** through the existing outbox/network path.
4. Separately log in the second synthetic human through the production public HTTP API. Its conversation list contains the created group; its sync result contains the exact UI-sent text. No token or credential is written into public evidence.

**Fresh actual Windows native integration result:**1test passed, exit0; Windows build294.9s, test49s. Assertions confirm UI creation/member addition/message send, second-human list membership, second-human exact-text sync and pending queue count0. Native diagnostics show actual `tray=false` without aborting initialization; this is not a forced result.

This validates a human group conversation path, **not AI-model chat**. No AI provider, paid service or fabricated AI reply was used.

## Limits and safety

- Actual UI state was verified by integration assertions, native metadata and Windows OCR. **This model had no image-capable visual inspection**, so independent visual review is required; no claim is made that visual clipping or other defects are absent.
- Capture isolation is local-only: application data/credential/AUMID/shortcut destinations are synthetic; fixed global hotkey/startup integration disabled. These captures do not accept exact-unmodified owner installation or readiness of Windows integrations.
- No owner native data or credentials were read/exported/deleted. The host and accounts are synthetic and loopback-only. Private diagnostics, fixture scripts, raw runtime metadata and databases are excluded from this public set.
