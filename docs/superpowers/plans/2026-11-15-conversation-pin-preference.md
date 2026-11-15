# Conversation Pin Preference Implementation Plan

> Authorized overnight native execution, TDD and independent review. Steps use checkbox tracking. Earlier PR branches remain unchanged.

**Goal:** Persist each account's own conversation pin flag as a backend subset of FR-18, without choosing UI sorting/mute/folder behavior.

**Architecture:** New independent M04 Migration306 and owner-scoped ConversationPreferences service. One supplied SQL transaction checks current active account, unique persisted group/direct kind and current membership before reading/upserting account+conversation preference. Route uses existing live bearer account/device pattern; no nested MembershipCheck calls.

**Tech Stack:** Dart, SQLite Database/Tx, current FriendshipService.activeKindInTx, Router/Pipeline.

**Spec:** v4.2 FR-18:164–167. This is conversation pin preference, not FR15 message pins or complete conversation UI.

## Global constraints
- GET/PUT `/api/v1/conversations/{conversationId}/preferences`; only current principal's preference, no admin or operator delegation. PUT exact `{pinned:bool}`; no query fields. GET absent row returns `{pinned:false}` without writing.
- Migration306 table account_id FK/account+conversation PK/pinned boolCHECK; no polymorphic conversation FK. Existing305 reserved for pending announcement PR16, no dependency on it.
- Current active actor (AI internally only with canonical active operator) and exactly one group/direct entity. Group current membership; direct fixed participant follows read—not posting—membership, including blocked conversations. Unknown/nonmember/ambiguous/inactive returns404.
- Preferences retained but inaccessible after leave/disable; if same canonical conversation membership returns, same stored flag is readable. No modifying old membership handlers/cleanup policies. PUT idempotent last committed write wins.
- Existing lists and ordering/metadata untouched. No mute/folder/theme, notification, client/UI, audit-body/provider changes. HTTP bearer refresh/revocation outside service Tx follows existing boundaries, not a stronger atomic session-commit guarantee.

## Review focus
- Both account and conversation bind every preference query; groupowner/admin can't read another person's flag, human operator can't set AI flag via payload.
- Ambiguous group/direct IDs deny all actors, even when a person belongs to only one kind.
- GET no row no insert; bad strict inputs no writes; failure rolls back; SQLite restart preserves flag.
- Direct block doesn't revoke read preference, but disabled actor/invalid AI operator fails closed.
- Membership and read/write sameTx with no nested public DB access; no existing list reordering.

## Task 1: pin preference persistence and HTTP
**Files:** create social/conversation_preferences.dart, conversation_preferences_migration.dart, conversation_preferences_routes.dart; tests conversation_preferences_test.dart and preference_host_test.dart. Modify SocialModule, defaultModules, Routes, migration expectation, status/traceability.
**Interfaces:** `ConversationPreferences({required Database database})`; `Future<Result<Map<String,Object?>>> get({required String accountId,required String conversationId})`; `set({required String accountId,required String conversationId,required bool pinned})` same return. `mountConversationPreferenceRoutes(Router,{required Database db,required AccountsDomain accounts})`.
- [x] Literal default-host GET test observes404 vs401 RED.
- [x] RealSQLite service/HTTP tests defaultfalse/idempotence/isolation/bothkinds/block/ambiguous/leave/rejoin/disabled/AI/restart/invalidinput/auth, existing DB upgrade and authenticated default-host/list-unchanged smoke.
- [x] Implement local supplied-Tx membership SQL + activeKindInTx, strict routes, independent306/default registration.
- [x] Focused20 and host analysis passed; independent static review noCritical/Important. Corrected migration-test false-positive (duplicate PK) to invalid-value UPDATE, rerun before publication.
- [ ] Full repository check, explicitagent/treeverified separatePR, final-headCI before ready.
