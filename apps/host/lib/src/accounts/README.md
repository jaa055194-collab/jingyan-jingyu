# M02 accounts

Production host authentication is now `AccountsDomain` + `DbAuthenticator` over `SqlAccountsStore`; the legacy static issuer is no longer assembled or exported. Existing framework test callers must use real account bootstrap/login and device revocation instead of `host.auth.issue(Principal)`.

## Initialize the single administrator

On Windows, prepare the Dart dependency cache, set `JINGYU_DATA_DIR`, `JINGYU_ADMIN_NAME` and `JINGYU_ADMIN_PASSWORD` in the process environment, then run from `apps/host`:

```powershell
dart run bin/init_accounts.dart
```

The script opens the same database as the server, does not listen on a port, prints only the account ID, and exits nonzero if an administrator already exists. Remove the administrator-password environment variable after initialization. Log in using that returned account ID. A unique partial index prevents two administrators even under concurrent initialization. The sole administrator cannot be disabled.

## HTTP payloads

Paths are shared protocol `Routes` constants.

- `POST /api/v1/auth/login`: `{accountId, password, deviceName}` -> `{deviceId, accessToken, refreshToken}`.
- `POST /api/v1/auth/invites/redeem`: `{code, displayName, password}` -> `{accountId}`. Then log in normally.
- `POST /api/v1/auth/refresh`: `{refreshToken}` -> replacement credentials; both old credentials stop working.
- `GET /api/v1/auth/devices`: authenticated current-account device metadata array. Rows contain `id`, `deviceName`, and UTC `lastUsedAt`. Only the device matching the validated bearer and request principal receives `current: true`; other rows omit `current`. No token, credential digest, or account ID is returned.
- `POST /api/v1/auth/devices/{deviceId}/revoke`: authenticated current-account device revocation.
- `GET /api/v1/accounts/me/ai`: current human operator's AI metadata array (`accountId`, `displayName`, `disabled`). Logically removed AI are omitted from this active management list.
- `POST /api/v1/accounts/me/ai`: current human operator `{displayName}` -> `{accountId}`. Creation grants no credentials, profile, persona, model, friendship or direct message.
- `DELETE /api/v1/accounts/me/ai/{accountId}`: current human operator only, exactly no body and no query -> `{removed: true}`. This is logical removal, not physical deletion: it sets the AI account to disabled and durably removed from the owner's management list while retaining the account, `ai_operator` reference and all existing conversations/history. Repeated removal succeeds without changing the removal timestamp or duplicating audit; administrators receive the same not-found result for another owner's AI.
- `POST /api/v1/admin/invites`: administrator `{expiresAt: ISO8601, maxUses?: 1}` -> one-time `{code}`.
- `GET /api/v1/admin/invites`: administrator metadata list with exactly `id`, `expiresAt`, `maxUses`, `usedCount`, `revokedAt`. Timestamps are UTC epoch milliseconds (`revokedAt` nullable); expired/exhausted/revoked records remain listed. Plaintext codes and digests are never returned here.
- `POST /api/v1/admin/invites/{inviteId}/revoke`: administrator-only, no body -> `{revoked: true}`. The path uses the metadata ID, not the secret redemption code. Existing repeated-revoke behavior is preserved (success with a refreshed revocation timestamp); counts and unrelated invitations are unchanged. Revocation committed before an in-flight redemption's final transaction prevents that registration, not registrations already completed.
- `GET /api/v1/admin/accounts`: administrator metadata allowlist only.
- `POST /api/v1/admin/accounts`: administrator `{displayName,password}` -> `{accountId}`. Cannot create another administrator.
- `POST /api/v1/admin/accounts/{accountId}/reset-password`: administrator-only, exactly `{newPassword: string}` -> `{reset: true}`. Uses the existing reset facade: human targets only, 12–1024 characters, clears target lockout and invalidates all target access/refresh sessions. Disabled accounts remain disabled. Resetting the administrator itself succeeds but requires a new login afterwards. These are existing domain semantics, not new recovery policies. No password/hash/session material is returned.
- `POST /api/v1/admin/accounts/{accountId}/disable`: administrator-only, no body -> `{disabled: true}`. Delegates to the existing disable facade: disables a human or AI and revokes that target's devices/refresh credentials. The single administrator is protected (409); repeated disable succeeds. It does not delete the account, change AI ownership, re-enable accounts or disable unrelated users.

Authenticated service facades (`domain.scope(bearer)`) expose AI creation/operator checks, disable/reset-password, invitations and devices. Each operation revalidates its bearer. Caller-provided principal IDs never grant service authority. AI account creation requires the acting human to be its operator; the administrator's separate disable power is operational account management.

## Security and storage

Migration100 creates `account`, `ai_operator`, `device`, `invite`, `refresh_token` and indexes. Migration101 adds `removed_ai_accounts`, an account-keyed marker with a UTC epoch-millisecond `removed_at`. The original `account` column layout is unchanged. The marker, disabled flag and metadata-only audit are committed in the same transaction. These migrations run after M01 starts and before requests are accepted; module startup records them in `schema_migrations`. SQL values are always bound. Invitations and access/refresh tokens are128-bit secure random base64url strings; only SHA-256 digests persist. Password hashes have independent128-bit salts and32-byte keys, encoded with version/algorithm/rounds.

PBKDF2-HMAC-SHA256 with600000 rounds is the M02 fallback: no usable pure Dart Argon2id dependency was available in the Windows offline cache and M02 permits only `crypto`. The verifier rejects malformed/weak encodings and excessive rounds before derivation. Two active worker isolates keep CPU work out of the request loop and account transactions. Account/credential/bearer/invite state is rechecked atomically after derivation so disable, password reset, revocation and lockout cannot be undone by in-flight operations.

Five consecutive bad passwords lock the account for15minutes. At most two registered devices remain; the third evicts least recently used and deletes both stored credential digests. Bearer authorization always reads current store state. Access expires after1hour; refresh after30days and rotates on use. Human passwords require12–1024characters; display/device names require1–100characters.

Rate limits default to30 admissions per minute independently by trusted socket IP, account ID and invite digest. Forwarded headers are ignored. A reverse proxy therefore shares its socket-IP budget unless a future explicitly trusted proxy integration is implemented. Limits are process-local; account lockout persists. Account transactions load full state, O(total account/device/invite rows), for the intended small circle. Administrator metadata filtering does not mean a host administrator is cryptographically unable to read data on their own machine.

## Offline verification

With dependencies already cached:

```powershell
dart pub get --offline
dart analyze --fatal-infos
dart test
```

Tests use injected clocks, temporary local SQLite databases and Windows system DLLs; no test calls a network service. Real600000-round hashing makes acceptance tests CPU intensive, so relevant test libraries allow ten minutes per test. Acceptance/storage contracts run unchanged against memory and SQLite. Real-file tests scan database/WAL/SHM bytes for generated credential plaintext and verify restart behavior. The full repository check remains `tool/check.ps1`.
