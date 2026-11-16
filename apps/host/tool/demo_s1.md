# Isolated synthetic rules-S1 HTTP demo

This is **curated rules S1**, NOT provider/model chat, NOT the completed product.
No provider is configured or contacted. No production module or Flutter UI is changed.

## Run (PowerShell / Windows)

Work directory: this worktree's `apps/host`.

```powershell
$dart = 'C:\Users\hu888\AppData\Local\Programs\Flutter\flutter\bin\cache\dart-sdk\bin\dart.exe'
& $dart pub get --offline
& $dart analyze tool/demo_s1.dart test/demo_s1_test.dart
& $dart test test/demo_s1_test.dart -r expanded
# Fresh isolated temp directory, loopback port, exit after verification:
& $dart run tool/demo_s1.dart --port 18788
# Same verification, then leave the restarted HTTP host available to a client:
& $dart run tool/demo_s1.dart --port 18788 --keep
# Optional explicit EMPTY data directory, never a production data directory:
& $dart run tool/demo_s1.dart --data-dir 'C:\Temp\jingyu-s1-review' --port 18788 --keep
```

Each automatic run creates a fresh `jingyu-demo-s1-*` system-temp directory.
Explicit `--data-dir` accepts empty directories or a directory carrying this tool's
`demo_s1.synthetic` marker. Unrelated nonempty directories are refused. The marker
is a wrong-directory guard, not an adversarial security boundary. Data is retained
for review; the tool does not delete it. Tests delete only their own temp directories.
Production storage/DPAPI is used, so this is a Windows/local-user demo.

The command prints JSON evidence but **no credentials by default**. Only `--keep`
prints the synthetic login passphrase for manual client login. A fresh dataDir
gets 32 cryptographically random bytes encoded as base64url; credentials are saved
only to `dataDir/demo_s1.fixture.local.json` and loaded again on reuse. Keep this
local file outside Git and do not share it or evidence containing credentials.
The local fixture file is plaintext synthetic-only data, not a production secret
store. No bearer tokens are printed. Existing demo databases without the local
credential config (including earlier fixed-passphrase demos) are refused; use a
fresh directory rather than silently rotating the login password.

`--keep` keeps the **restarted** host listening until Ctrl+C. Port 0 chooses an
OS-assigned port; the final `originAfterRestart` is authoritative because restart
can change it. Runtime evidence may contain local paths: do not commit raw output,
job IDs or host-specific evidence. Do not use synthetic credentials for real accounts.

## What the tool really does

1. Boots unmodified `buildHost` with an isolated `dataDir`, loopback-only HTTP.
2. Seeds synthetic active human `demo_human` (also AI operator), AI `demo_ai`,
   `demo_profile`, group `demo_group`, membership, group mention/pacing gates,
   explicit L1, explicit timezone and positive `chatFast` budget. Other capability
   budgets are zero. No provider or model worker is enabled.
3. Generates random local fixture credentials and a real production PBKDF2 hash;
   calls **HTTP** `/api/v1/auth/login` (reuse loads the same local credentials).
4. Calls HTTP `/api/v1/conversations`, confirms `demo_group` is visible.
5. POSTs `/api/v1/conversations/demo_group/messages` with canonical text `你好`,
   `mentionAccountIds: [demo_ai]`, and stable idempotency key `demo-s1-hello-v1`.
6. HTTP sync confirms exactly the human input plus one canonical AI `你好呀`,
   `source=s1`, and captures its messageId.
7. Closes HTTP listener and host, checks that `Host.shutdown()` returns no errors
   (a nonempty error list fails the demo), opens the **same** database/key again,
   logs in through HTTP again, syncs, and confirms the same messageId/text and count=2.

No static token insertion, fake authenticator, fake S1 server, production gate
changes, or artificial model claims. The fixture DML is tool-only and follows
`group_rules_host_test.dart`. A repeated run on its marked directory reuses the
same clientMsgId rather than generating duplicate messages.

## Client connection

Point an existing native Flutter client at the printed loopback origin (for
example `http://127.0.0.1:18788`). Login account: `demo_human`; passphrase: printed
by the tool. The persisted group is `demo_group`. This does not add UI mention
support: a fresh S1 response requires an actual `mentionAccountIds` payload and
obeys the existing >=30s pacing/day-cap gates. Unknown/complex text may stay silent.
The exact proven path is HTTP login/list/send/sync/restart, not Flutter end-to-end.

## Tests / scope

`test/demo_s1_test.dart` exercises the real tool against production host HTTP and
SQLite, checks persistence across host restart and full DemoS1 close/open reuse,
confirms the local random credential is reused for HTTP login without printing it,
and verifies non-demo-directory refusal without altering the unrelated file.
Only the tool, this guide, and `test/demo_s1_test.dart` are added; the standard host test suite discovers the regression. No raw evidence is retained.
No commit/push/PR or changes to PR58 draft / PR8 hold are performed by this tool.
