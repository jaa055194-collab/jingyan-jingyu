# Owner Group Name Update Implementation Plan

> Authorized native overnight execution, TDD and independent review; leave prior PR branches unchanged.

**Goal:** Allow the current active human group owner to update the existing group name (FR-22 backend slice).

**Architecture:** Add one ConversationService.setName method and PUT to existing group management routes. Preserve name storage/Conversation JSON/list behavior and create validation: raw Dart string length≤100, nonblank trim, store trim. No new migration/module/encryption/role model.

**Spec:** v4.2 FR-22:187–190 group names. Owner-only active-human restriction is the conservative adapter scope, not a quoted FR22 role rule.

## Constraints
- PUT `/api/v1/conversations/{conversationId}/name` exact `{name:string}`, no query/actor/owner/history/avatar parameters. Existing route helper revalidates live bearer and exact principal account/device.
- Service validates IDs/name then in one Tx checks existing group, owner==actor, activeKind=='human' explicitly and current membership; update name only. Same notFound for missing/nonowner/admin/removed/disabled/legacyAIowner. No admin/operator override.
- Response `{}` from Result<void> consistent with existing management APIs; member list reread reflects saved name. No notification/system message/WS/clientcache/UI promises.
- Success audit action group.name.set with actor/group only, no old/new name. Existing separate audit write is not atomic with rename; do not redesign it here or claim stronger session-revocation atomicity.

## Review Focus
- Legacy mapped active AI owner must still fail (activeKind!=null is too broad).
- Owner transfer/member removal/disabled account rechecked in sameTx as update.
- Raw100 boundary before trim, Unicode Dart length matches create; no name normalization expansion.
- Denied requests do not change state/audit; name-only mutation leaves owner/time/history/membership intact.
- Default authenticated host/reopen and social registration reorder prove real assembly, not only isolated router.

## Task 1
**Files:** modify social/conversation_service.dart, group_management_routes.dart, protocol/routes.dart, social_dependency_order_test.dart; create group_name_test.dart; status/traceability.
**Interface:** `Future<Result<void>> setName({required String actorId,required String conversationId,required String name})`.
- [x] Write literal-path route test, observe404 RED.
- [x] Add owner/nonowner/admin/legacyAI/transfer/remove/disable/strictbody/boundary/token/audit/restart/name-only tests plus Tx-only abort/rollback and direct disabled-service check.
- [x] Implement minimal service and handler/constants, no existing-interface behavior change.
- [x] Focused31 passed, host analysis clean; independent static security review noCritical/Important (no independent Dart run).
- [ ] Full repository check and final-headCI.
- [ ] Explicit-agent tree-matching newPR, final-headCI before ready.
