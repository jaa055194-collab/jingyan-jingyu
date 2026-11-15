# Administrator Recorded Usage Summary Implementation Plan

> Authorized overnight native execution/TDD/independent review. New branch from main; earlier PRs unchanged.

**Goal:** Expose FR07 cumulative recorded-token statistics to current administrator without source rows/IDs/private content.

**Architecture:** New AdminUsageModule/read service registered in default host, exact GET `/api/v1/admin/usage` noquery. Same Tx checks real current bearer hash, principal account/device, access expiry, refresh row existence, enabled humanadmin then projects existing usage_ledger columns. No schema/rollup/meterpolicy/runtime/provider calls. No dependency on unmerged adminaudit/ownerusage code.

**Spec:** v4.2 FR07:98–101 globalusage. Response basis allRecordedLedgerRows, recordedTokens decimalBigInt string, complete byLayer/byCapability decimalstringmaps, sourceUsageUnknown bool. All retained owner/AI/day/offset rows included (no currentownership filtering). Unknown rows do not contribute invented token values; known totals are incomplete when flagtrue.

## Constraints and risks
- Service selects only layer/capability/input_tokens/output_tokens/total_tokens/source_usage_unknown; noIDs/body/key/metadata/drilldown or calendar/defaulttimezone.
- Exact known totals require O(ledger rows and decimal digits) scan; Tx.query materializes rows O(N) memory and existing BEGIN IMMEDIATE serializes DB. This is explicitly NOT boundedexecution/latency, not complete billing/lifetimeever/allplatform usage. No LIMIT truncation pretending globaltotal.
- SameTx canonicalauth beforeledgerread, Access.admin plus exact principal identity/no forgedcachedisAdmin; structuralrefreshjoin no refresh-expiry requirement matches existing accessauth. Don't call AccountsDomain insideTx.
- No ledger/budget/audit/source writes; normalouterauth maytouchdevice+loadfullstate, not wholeGETreadonlyclaim.
- Validate stored canonical decimal counters/components/categories/status; malformed retained row =>safeinternal notpartialaggregate.

## Tasks
- [x] Defaulthost literalroute test observes404RED beforemodule.
- [x] RealSQLite tests empty/knownzero/unknownmixed/everyenum/BigInt/historicaldisabledtransferred/days/no-config/secretallowlist/no-write and liveauth/Tx-race.
- [x] Minimal reader/module/protocol/rootregistration, exactmodulelistexpectation; no schema.
- [x] New9+existingusage/budget23=32 passed, host analysis clean.
- [ ] Independent review and full repository/final-head verification.
- [ ] Explicitagent/treeverifiedseparatePR/finalheadCI before ready.
