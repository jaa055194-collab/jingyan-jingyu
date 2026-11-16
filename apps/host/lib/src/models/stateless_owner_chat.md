# Bounded stateless owner-text facade (internal slice)

`StatelessOwnerChat` is an internal trusted capability, not HTTP, an observer,
message dispatch, permission/consent, or a replacement for `ContextualChat`.
It does not read history/memory/group messages, persist input/output, mutate
persona, configure providers, read local config files, or implement retries.

## Composition / caller contract

Construct with `db`, `cipher`, `clock`, and `chat: runtime.chat`, or use
`StatelessOwnerChat.fromRuntime(db: ..., cipher: ..., clock: ..., runtime: ...)`.
The function-port constructor is for trusted dependency injection, not user input.
No runtime means no facade: upstream must fail closed, not fall back to another
model/provider. Production ModelRuntime retains binding/URL/budget/usage gates.

Call `chat` with required `ownerId`, `ai`, `conversationId`, `requestId`, `system`,
`input`, `expectedProviderId`, `expectedModel`, `maxTokens`. It returns existing
`Result<ChatCompletion>` without any assembly/body diagnostics in errors.

Caller must authenticate the owner, supply a **canonical direct conversation ID**,
and enforce current friendship/block/visibility/consent/dispatch policy. This
helper does not grant permission from an ID or replace those live checks.
It rechecks active human owner + active AI/operator/profile identity using the
existing PersonaService and canonical `direct_conversations` owner/AI pair SQL.
Missing/foreign identity, scope, or persona is notFound, not a default persona.
No social implementation imports. These sequential checks are not an atomic
transaction with external provider dispatch, nor a claim of race-free live ACL.

The current saved P0/P1/P2 layers are read on each call. Exactly two turns:

1. `system`: supplied system text + `\n\nSaved persona (JSON):\n` + complete
   `jsonEncode(persona.layers.toJson())`.
2. `user`: exactly one supplied owner input, untrimmed and untruncated.

No prior assistant turns, history, summaries, memory hits, group payloads, or
caller-selected budget/context are accepted. Fixed B2 deep chat, private kind,
initiator = owner, scopeKey = canonical direct ID. Explicit provider/model pinning
is always forwarded; Runtime rejects binding changes. Persona lock is not a read
prohibition; no model output is written into persona.

## Engineering limits (not specification thresholds)

Configurable defaults for **this slice only**:

| Constructor option | Default | Definition |
| --- | ---: | --- |
| maxInputBytes | 4096 | UTF8 bytes of both complete turn contents, including separator/persona JSON |
| maxEncodedRequestBytes | 8192 | UTF8 bytes of JSON request shape: model/messages/stream=false/max_tokens; includes JSON escaping/structure |
| maxOutputBytes | 8192 | UTF8 bytes of normalized completion text |
| maxAllowedTokens | 2048 | caller maxTokens must be explicit, positive and <= this policy ceiling |

`2048` is the default engineering policy, **not a hardcoded or specification
maximum**. Trusted composition may lower or raise `maxAllowedTokens` explicitly.
Raising it permits larger provider output requests and potentially higher cost,
latency and resource use; the output-byte guard still runs only after usage has
been incurred. Review that tradeoff alongside model/provider settings and runtime
budgets. Constructor policy must never come from arbitrary HTTP/model content;
individual callers must still supply an explicit `maxTokens` within that policy.

Invalid caps, empty text/pinning, malformed IDs, malformed UTF16 (unpaired
surrogates in system/input/pinning/persona/completion), input/encoded overflow
fail closed. No silent UTF8 replacement and no clipping/truncation. The two input
caps are independent; control characters/quotes/backslashes can expand JSON.
The encoded bound is the current OpenAI-compatible body shape, not HTTP headers,
provider-ID metadata, or a generic future adapter's wire-format promise.

These are **not** a tokenizer, model context-window estimate, guaranteed token
cost, or a strict monetary budget reservation. `maxTokens` is a provider request
parameter; existing runtime usage gates/settlement remain authoritative.

The output check happens **after** Runtime returns a normalized completion and
settles provider usage. Oversized/malformed output returns safe modelUnavailable,
without body, refund/rollback or retry. A provider call may already have consumed
cost; upstream must not automatically resend on this result. Existing pending
unknown usage/reconciliation semantics and replay conflict remain unchanged.
Non-200 responses keep existing adapter/runtime safe mappings; no claim to detect
specific provider context-limit errors or new error code is added.

## Offline verification

`test/stateless_owner_chat_test.dart`: real in-memory SQLite encrypted persona +
canonical direct fixture, fake function port, exact turns/current persona/pins,
UTF8 and escaped-body boundaries, invalid/no-call, isolation/disabled/transfer,
output bounds, safe single-call failures.
`test/stateless_owner_chat_runtime_test.dart`: real SQLite bindings/budget/ledger,
synthetic in-memory credential and injected fake provider transport (no outbound
network or user key/config), pin mismatch, budget hard-stop, post-settlement output
overflow, non-200 pending usage and no retry. ContextualChat tests remain unchanged.

Windows harness note: default kernel test compiler failed launching its relative
SDK dartaotruntime path (ENOENT) in the deep worktree. Use the supported source
compiler, which runs the same production/test Dart code:

```powershell
& '<absolute dart.exe>' pub get --offline
& '<absolute dart.exe>' analyze lib/src/models/stateless_owner_chat.dart test/stateless_owner_chat_test.dart test/stateless_owner_chat_runtime_test.dart
& '<absolute dart.exe>' test --compiler source test/stateless_owner_chat_test.dart test/stateless_owner_chat_runtime_test.dart test/contextual_chat_test.dart -r expanded
```
