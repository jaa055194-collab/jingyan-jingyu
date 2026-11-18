# Owner AI chat shortcut — Flutter render comparison

| Scene | Revision | Production shell capture |
| --- | --- | --- |
| Settings, already-authorized AI row, before | `32ac64f54358bf8e7837a566ea225bf966322c38` | [Before PNG](owner-chat-before-32ac64f.png) |
| Same Settings row, after | `333fca6400c82d9fba0ea5e352568cdbb0ec444f` | [After PNG](owner-chat-after-333fca6.png) |
| After explicitly tapping the shortcut | `333fca6400c82d9fba0ea5e352568cdbb0ec444f` | [Opened chat PNG](owner-chat-after-333fca6-open.png) |

These are unedited Flutter painter captures of the real `WhaleChatApp` widget tree in isolated worktrees, not mockups. The paired Settings scene uses the same synthetic owner, the same ready/enabled consent and canonical direct conversation fixture, the same Settings scroll anchor, light theme, and 390×844 viewport at DPR 1. Both runs used the same Windows CJK and Material icon test fonts and dependency lock (SHA-256 `1BD53182D4767917EF2291C46EF18CFB85C4EAE15B357F5F5246FE43AB7390FC`). The driver checked that the authorized row appeared in both runs, that only After had the shortcut, and that tapping it opened the canonical chat composer without a consent mutation or message send. Separate loopback coverage exercises the runtime's read-only sync and outbox behavior.

PNG SHA-256:
- Before: `2F9D97B4B439DBDE3758E290F8C30840505B6342F0820BBD59FC4B03326AF264`
- After: `9E186E1CB7993C69913FDF8524ADE261A80436BFF3D609687DC6CC5E185A5067`
- Opened chat: `182DCA3400F8D4C85993C19C503F26418C9759D4C309A22ED767E19C94EA0340`

The driver assertions and PNG dimension/nonblank checks passed. This is not native-device acceptance, real-host or live-model validation, or manual visual approval. No real account data or credentials were used.
