import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';

enum FriendshipState {
  none,
  outgoingPending,
  incomingPending,
  friends,
  blocked,
}

/// One owner-scoped contact row. Read-only metadata from the same friendship
/// tables; no consent, conversation or message content is included.
class FriendContact {
  const FriendContact({
    required this.accountId,
    required this.displayName,
    required this.state,
  });
  final String accountId;
  final String displayName;
  final FriendshipState state;

  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'displayName': displayName,
    'state': state.name,
  };
}

/// Trusted internal capability. Supply the authenticated principal at construction,
/// never an actor from request JSON. There is no operator delegation for consent.
/// Human-to-AI requests can remain pending; AI permissions are not implemented.
class FriendshipService {
  FriendshipService({
    required AccountId actorId,
    required Database database,
    required Clock clock,
  }) : _actor = actorId.value,
       _db = database,
       _clock = clock;

  final String _actor;
  final Database _db;
  final Clock _clock;
  int get _now => _clock.now().toUtc().millisecondsSinceEpoch;

  static Future<String?> activeKindInTx(Tx tx, String account) async {
    final rows = await tx.query(
      '''
SELECT a.kind FROM account a WHERE a.id=? AND a.disabled=0
AND (a.kind='human' OR EXISTS (
  SELECT 1 FROM ai_operator o JOIN account h ON h.id=o.operator_id
  WHERE o.ai_id=a.id AND h.kind='human' AND h.disabled=0))
''',
      [account],
    );
    return rows.isEmpty ? null : rows.single['kind'] as String;
  }

  Future<Failure?> _check(Tx tx, String target) async {
    if (_actor == target) {
      return const Failure(FailureCode.invalidArgument, 'Cannot target self');
    }
    final actor = await activeKindInTx(tx, _actor);
    final other = await activeKindInTx(tx, target);
    if (actor == null || other == null) {
      return const Failure(FailureCode.notFound, 'Active account not found');
    }
    if (actor != 'human') {
      return const Failure(
        FailureCode.forbidden,
        'AI authorization unavailable',
      );
    }
    return null;
  }

  /// Each endpoint includes its operator for inherited blocks. A block against
  /// one AI never includes that AI's siblings or blocks against its human owner.
  static Future<bool> _blocked(Tx tx, String a, String b) async =>
      (await tx.query(
        '''
WITH left_ids(id) AS (SELECT ? UNION SELECT operator_id FROM ai_operator WHERE ai_id=?),
right_ids(id) AS (SELECT ? UNION SELECT operator_id FROM ai_operator WHERE ai_id=?)
SELECT 1 FROM account_blocks
WHERE (blocker IN (SELECT id FROM left_ids) AND target IN (SELECT id FROM right_ids))
   OR (blocker IN (SELECT id FROM right_ids) AND target IN (SELECT id FROM left_ids))
LIMIT 1
''',
        [a, a, b, b],
      )).isNotEmpty;

  /// Trusted same-transaction policy ports for private conversation composition.
  static Future<bool> isBlockedInTransaction(Tx tx, String a, String b) =>
      _blocked(tx, a, b);
  static Future<bool> friendsInTx(Tx tx, String a, String b) =>
      _friends(tx, a, b);

  static List<String> _pair(String a, String b) =>
      a.compareTo(b) < 0 ? [a, b] : [b, a];

  static Future<bool> _friends(Tx tx, String a, String b) async =>
      (await tx.query(
        'SELECT 1 FROM friendships WHERE account_low=? AND account_high=?',
        _pair(a, b),
      )).isNotEmpty;

  Future<Result<void>> request(AccountId target) => _db.transaction((tx) async {
    final other = target.value;
    final failure = await _check(tx, other);
    if (failure != null) return Err(failure);
    if (await _blocked(tx, _actor, other)) {
      return err(FailureCode.forbidden, 'Blocked');
    }
    if (await _friends(tx, _actor, other)) return const Ok(null);
    await tx.execute(
      '''
INSERT INTO friend_requests(sender,target,status,updated_at) VALUES (?,?,'pending',?)
ON CONFLICT(sender,target) DO UPDATE SET status='pending',updated_at=excluded.updated_at
WHERE friend_requests.status<>'pending'
''',
      [_actor, other, _now],
    );
    return const Ok(null);
  });

  Future<Result<void>> accept(AccountId sender) =>
      _respond(sender, accept: true);
  Future<Result<void>> deny(AccountId sender) =>
      _respond(sender, accept: false);

  Future<Result<void>> _respond(
    AccountId sender, {
    required bool accept,
  }) => _db.transaction((tx) async {
    final other = sender.value;
    final failure = await _check(tx, other);
    if (failure != null) return Err(failure);
    if (await _blocked(tx, _actor, other)) {
      return err(FailureCode.forbidden, 'Blocked');
    }
    final rows = await tx.query(
      'SELECT status FROM friend_requests WHERE sender=? AND target=?',
      [other, _actor],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'Request not found');
    final status = rows.single['status'];
    if (accept && status == 'accepted' && await _friends(tx, _actor, other)) {
      return const Ok(null);
    }
    if (!accept && status == 'denied') return const Ok(null);
    if (status != 'pending') {
      return err(FailureCode.conflict, 'Request is not pending');
    }
    await tx.execute(
      'UPDATE friend_requests SET status=?,updated_at=? WHERE sender=? AND target=?',
      [accept ? 'accepted' : 'denied', _now, other, _actor],
    );
    if (accept) {
      await tx.execute(
        'INSERT OR IGNORE INTO friendships(account_low,account_high,created_at) VALUES (?,?,?)',
        [..._pair(_actor, other), _now],
      );
      // A crossed application is covered by the explicit target consent.
      await tx.execute(
        "UPDATE friend_requests SET status='accepted',updated_at=? WHERE sender=? AND target=? AND status='pending'",
        [_now, _actor, other],
      );
    }
    return const Ok(null);
  });

  Future<Result<void>> block(AccountId target) => _db.transaction((tx) async {
    final failure = await _check(tx, target.value);
    if (failure != null) return Err(failure);
    await tx.execute(
      'INSERT OR IGNORE INTO account_blocks(blocker,target,created_at) VALUES (?,?,?)',
      [_actor, target.value, _now],
    );
    // FR-08: unblocking requires a fresh application. Invalidate direct AND
    // inherited consent in the same transaction; removing the block cannot revive it.
    for (final row in await tx.query(
      'SELECT account_low,account_high FROM friendships',
    )) {
      final a = row['account_low'] as String;
      final b = row['account_high'] as String;
      if (await _blocked(tx, a, b)) {
        await tx.execute(
          'DELETE FROM friendships WHERE account_low=? AND account_high=?',
          [a, b],
        );
      }
    }
    for (final row in await tx.query(
      'SELECT sender,target FROM friend_requests',
    )) {
      final a = row['sender'] as String;
      final b = row['target'] as String;
      if (await _blocked(tx, a, b)) {
        await tx.execute(
          'DELETE FROM friend_requests WHERE sender=? AND target=?',
          [a, b],
        );
      }
    }
    return const Ok(null);
  });

  Future<Result<void>> unblock(AccountId target) => _db.transaction((tx) async {
    final failure = await _check(tx, target.value);
    if (failure != null) return Err(failure);
    await tx.execute(
      'DELETE FROM account_blocks WHERE blocker=? AND target=?',
      [_actor, target.value],
    );
    return const Ok(null);
  });

  Future<Result<FriendshipState>> getState(AccountId target) =>
      _db.transaction((tx) async {
        // AI may inspect its own state; this read grants no consent capability.
        if (_actor == target.value) {
          return err(FailureCode.invalidArgument, 'Cannot target self');
        }
        if (await activeKindInTx(tx, _actor) == null ||
            await activeKindInTx(tx, target.value) == null) {
          return err(FailureCode.notFound, 'Active account not found');
        }
        if (await _blocked(tx, _actor, target.value)) {
          return const Ok(FriendshipState.blocked);
        }
        if (await _friends(tx, _actor, target.value)) {
          return const Ok(FriendshipState.friends);
        }
        final rows = await tx.query(
          '''
SELECT sender FROM friend_requests WHERE status='pending'
AND ((sender=? AND target=?) OR (sender=? AND target=?))
''',
          [_actor, target.value, target.value, _actor],
        );
        // An incoming request takes precedence if applications are crossed.
        if (rows.any((row) => row['sender'] == target.value)) {
          return const Ok(FriendshipState.incomingPending);
        }
        return Ok(
          rows.isEmpty ? FriendshipState.none : FriendshipState.outgoingPending,
        );
      });

  /// Owner-scoped, read-only contact list for the authenticated human.
  ///
  /// Reuses the same friendship/request/block tables. Returns active accounts
  /// only; incoming blocks (someone blocked the caller) are deliberately not
  /// disclosed. This grants no consent and changes no relationship state.
  Future<Result<List<FriendContact>>> listContacts() =>
      _db.transaction((tx) async {
        if (await activeKindInTx(tx, _actor) != 'human') {
          return err(FailureCode.notFound, 'Active human not found');
        }
        final rows = await tx.query(
          '''
SELECT other.id AS id, other.display_name AS displayName,
  CASE
    WHEN EXISTS(SELECT 1 FROM account_blocks b WHERE b.blocker=? AND b.target=other.id) THEN 'blocked'
    WHEN EXISTS(SELECT 1 FROM friendships f WHERE (f.account_low=? AND f.account_high=other.id) OR (f.account_low=other.id AND f.account_high=?)) THEN 'friends'
    WHEN EXISTS(SELECT 1 FROM friend_requests r WHERE r.sender=other.id AND r.target=? AND r.status='pending') THEN 'incomingPending'
    ELSE 'outgoingPending'
  END AS state
FROM account other
WHERE other.disabled=0 AND other.id<>?
AND (
  EXISTS(SELECT 1 FROM friendships f WHERE (f.account_low=? AND f.account_high=other.id) OR (f.account_low=other.id AND f.account_high=?))
  OR EXISTS(SELECT 1 FROM friend_requests r WHERE r.status='pending' AND ((r.sender=? AND r.target=other.id) OR (r.sender=other.id AND r.target=?)))
  OR EXISTS(SELECT 1 FROM account_blocks b WHERE b.blocker=? AND b.target=other.id)
)
ORDER BY state ASC, other.id ASC
''',
          [
            _actor,
            _actor,
            _actor,
            _actor,
            _actor,
            _actor,
            _actor,
            _actor,
            _actor,
            _actor,
          ],
        );
        final contacts = <FriendContact>[];
        for (final row in rows) {
          final state = switch (row['state']) {
            'blocked' => FriendshipState.blocked,
            'friends' => FriendshipState.friends,
            'incomingPending' => FriendshipState.incomingPending,
            'outgoingPending' => FriendshipState.outgoingPending,
            _ => FriendshipState.none,
          };
          if (state == FriendshipState.none) {
            return err(FailureCode.internal, 'Unexpected contact state');
          }
          contacts.add(
            FriendContact(
              accountId: row['id'] as String,
              displayName: row['displayName'] as String,
              state: state,
            ),
          );
        }
        return Ok(List<FriendContact>.unmodifiable(contacts));
      });

  /// Owner-scoped notifications for the authenticated account. Metadata only:
  /// `kind/title/status/createdAt/refId`; no private body, message or blob.
  /// Today the only source is incoming pending friend invitations
  /// (`friend_requests.target = actor`). System notices / consent prompts are
  /// intentionally absent rather than fabricated.
  Future<Result<List<Map<String, Object?>>>> listNotifications({
    int limit = 50,
  }) => _db.transaction((tx) async {
    if (await activeKindInTx(tx, _actor) != 'human') {
      return err(FailureCode.notFound, 'Active human not found');
    }
    if (limit < 1 || limit > 100) {
      return err(FailureCode.invalidArgument, 'invalid limit');
    }
    final rows = await tx.query(
      "SELECT sender, status, updated_at FROM friend_requests "
      "WHERE target = ? AND status = 'pending' "
      'ORDER BY updated_at DESC, sender ASC LIMIT ?',
      [_actor, limit],
    );
    final items = <Map<String, Object?>>[];
    for (final row in rows) {
      final at = DateTime.fromMillisecondsSinceEpoch(
        row['updated_at'] as int,
        isUtc: true,
      ).toIso8601String();
      items.add(<String, Object?>{
        'kind': 'friendRequest',
        'title': '好友邀请',
        'status': row['status'],
        'createdAt': at,
        'refId': row['sender'],
      });
    }
    return Ok(List<Map<String, Object?>>.unmodifiable(items));
  });

  /// Internal policy query, not a client-visible arbitrary-pair lookup.
  Future<bool> areFriends(AccountId a, AccountId b) => _db.transaction(
    (tx) async =>
        await activeKindInTx(tx, _actor) != null &&
        await activeKindInTx(tx, a.value) != null &&
        await activeKindInTx(tx, b.value) != null &&
        await _friends(tx, a.value, b.value) &&
        !await _blocked(tx, a.value, b.value),
  );

  /// Blocking persists even while accounts are disabled. This checks the actual
  /// relationship, independently of active-account eligibility for private actions.
  Future<bool> isBlocked(AccountId a, AccountId b) =>
      _db.transaction((tx) => _blocked(tx, a.value, b.value));
}
