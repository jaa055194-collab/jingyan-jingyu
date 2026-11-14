import 'dart:convert';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';

import '../messages/messages_module.dart';
import '../storage/cipher.dart';
import '../storage/database.dart';

enum HistoryVisibility { all, joined }

class Conversation {
  const Conversation({
    required this.id,
    required this.ownerAccountId,
    required this.name,
    required this.historyVisibility,
    required this.createdAt,
  });

  final String id;
  final String ownerAccountId;
  final String name;
  final HistoryVisibility historyVisibility;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'ownerAccountId': ownerAccountId,
    'name': name,
    'kind': 'group',
    'historyVisibility': historyVisibility.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory Conversation._row(Map<String, Object?> row) => Conversation(
    id: row['id'] as String,
    ownerAccountId: row['owner_account_id'] as String,
    name: row['name'] as String,
    historyVisibility: HistoryVisibility.values.byName(
      row['history_visibility'] as String,
    ),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      row['created_at'] as int,
      isUtc: true,
    ),
  );
}

/// Trusted host capability: routes must supply the authenticated principal's
/// account ID, never an actor/owner ID accepted from request JSON.
///
/// Only groups are supported. Direct messages require a future friendship and
/// blocking service; this service deliberately has no direct-message creator.
class ConversationService implements HistoryMembershipCheck {
  ConversationService({
    required Database database,
    required this.clock,
    required Future<int> Function(Tx, String) headSeq,
    required Future<bool> Function(Tx, String) accountExists,
    ColumnCipher? cipher,
    String Function()? newId,
  }) : _database = database,
       _headSeq = headSeq,
       _accountExists = accountExists,
       _cipher = cipher,
       _newId = newId ?? _randomId;

  final Database _database;
  final Clock clock;
  // These capabilities must use the supplied Tx, never open nested transactions.
  final Future<int> Function(Tx, String) _headSeq;
  final Future<bool> Function(Tx, String) _accountExists;
  final ColumnCipher? _cipher;
  final String Function() _newId;
  static final Random _random = Random.secure();
  static String _randomId() => base64Url
      .encode(List.generate(18, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  bool _validId(String value) {
    try {
      validateId(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  Result<T> _invalid<T>() => err(FailureCode.invalidArgument, 'Invalid input');
  Result<T> _missing<T>() => err(FailureCode.notFound, 'Not found');

  Future<Result<Conversation>> createGroup({
    required String ownerAccountId,
    required String name,
    HistoryVisibility historyVisibility = HistoryVisibility.all,
  }) async {
    if (!_validId(ownerAccountId) || name.trim().isEmpty || name.length > 100) {
      return _invalid();
    }
    return _database.transaction((tx) async {
      if (!await _accountExists(tx, ownerAccountId)) return _missing();
      final id = validateId(_newId(), kind: 'conversation');
      final now = clock.now().toUtc();
      await tx.execute(
        'INSERT INTO social_conversations (id, owner_account_id, name, history_visibility, created_at) VALUES (?, ?, ?, ?, ?)',
        [
          id,
          ownerAccountId,
          name.trim(),
          historyVisibility.name,
          now.millisecondsSinceEpoch,
        ],
      );
      await tx.execute(
        'INSERT INTO social_members (conversation_id, account_id, joined_at, first_visible_seq) VALUES (?, ?, ?, ?)',
        [id, ownerAccountId, now.millisecondsSinceEpoch, 1],
      );
      return Ok(
        Conversation(
          id: id,
          ownerAccountId: ownerAccountId,
          name: name.trim(),
          historyVisibility: historyVisibility,
          createdAt: now,
        ),
      );
    });
  }

  Future<Result<List<Conversation>>> list(String accountId) async {
    if (!_validId(accountId)) return _invalid();
    return _database.transaction((tx) async {
      if (!await _accountExists(tx, accountId)) return _missing();
      final rows = await tx.query(
        'SELECT c.* FROM social_conversations c INNER JOIN social_members m ON m.conversation_id = c.id WHERE m.account_id = ? ORDER BY c.created_at, c.id',
        [accountId],
      );
      return Ok(rows.map(Conversation._row).toList(growable: false));
    });
  }

  Future<Result<void>> addMember({
    required String actorAccountId,
    required String conversationId,
    required String memberAccountId,
  }) async {
    if (!_validId(actorAccountId) ||
        !_validId(conversationId) ||
        !_validId(memberAccountId)) {
      return _invalid();
    }
    return _database.transaction((tx) async {
      final rows = await tx.query(
        'SELECT history_visibility FROM social_conversations WHERE id = ? AND owner_account_id = ?',
        [conversationId, actorAccountId],
      );
      if (rows.isEmpty ||
          !await _accountExists(tx, actorAccountId) ||
          !await _accountExists(tx, memberAccountId)) {
        return _missing();
      }
      final present = await tx.query(
        'SELECT 1 FROM social_members WHERE conversation_id = ? AND account_id = ?',
        [conversationId, memberAccountId],
      );
      if (present.isNotEmpty) return const Ok(null);
      // Snapshot head and insert membership in the SAME SQLite transaction.
      final first = rows.single['history_visibility'] == 'joined'
          ? (await _headSeq(tx, conversationId)) + 1
          : 1;
      await tx.execute(
        'INSERT INTO social_members (conversation_id, account_id, joined_at, first_visible_seq) VALUES (?, ?, ?, ?)',
        [
          conversationId,
          memberAccountId,
          clock.now().toUtc().millisecondsSinceEpoch,
          first,
        ],
      );
      return const Ok(null);
    });
  }

  /// Current human owner changes existing group metadata, never another actor.
  Future<Result<void>> setName({
    required String actorId,
    required String conversationId,
    required String name,
  }) async {
    if (!_validId(actorId) ||
        !_validId(conversationId) ||
        name.trim().isEmpty ||
        name.length > 100) {
      return _invalid();
    }
    return _database.transaction((tx) async {
      final rows = await tx.query(
        'SELECT owner_account_id FROM social_conversations WHERE id = ?',
        [conversationId],
      );
      if (rows.isEmpty ||
          rows.single['owner_account_id'] != actorId ||
          await _activeKind(tx, actorId) != 'human' ||
          !await _isMember(tx, conversationId, actorId)) {
        return _missing();
      }
      await tx.execute(
        'UPDATE social_conversations SET name = ? WHERE id = ?',
        [name.trim(), conversationId],
      );
      return const Ok(null);
    });
  }

  Future<Result<void>> transferOwnership({
    required String actorId,
    required String conversationId,
    required String newOwnerId,
  }) async {
    if (!_validId(actorId) ||
        !_validId(conversationId) ||
        !_validId(newOwnerId)) {
      return _invalid();
    }
    return _database.transaction((tx) async {
      final conversation = await tx.query(
        'SELECT owner_account_id FROM social_conversations WHERE id = ?',
        [conversationId],
      );
      if (conversation.isEmpty ||
          conversation.single['owner_account_id'] != actorId ||
          await _activeKind(tx, actorId) == null ||
          !(await _isMember(tx, conversationId, actorId))) {
        return _missing();
      }
      // A handoff recipient must be an active human who is already a member.
      if (await _activeKind(tx, newOwnerId) != 'human' ||
          !(await _isMember(tx, conversationId, newOwnerId))) {
        return _missing();
      }
      await tx.execute(
        'UPDATE social_conversations SET owner_account_id = ? WHERE id = ?',
        [newOwnerId, conversationId],
      );
      return const Ok(null);
    });
  }

  Future<Result<void>> leave({
    required String actorId,
    required String conversationId,
  }) async {
    if (!_validId(actorId) || !_validId(conversationId)) return _invalid();
    return _database.transaction((tx) async {
      final conversation = await tx.query(
        'SELECT owner_account_id FROM social_conversations WHERE id = ?',
        [conversationId],
      );
      if (conversation.isEmpty ||
          await _activeKind(tx, actorId) == null ||
          !(await _isMember(tx, conversationId, actorId))) {
        return _missing();
      }
      if (conversation.single['owner_account_id'] == actorId) {
        return err(FailureCode.forbidden, 'Transfer ownership before leaving');
      }
      await tx.execute(
        'DELETE FROM social_members WHERE conversation_id = ? AND account_id = ?',
        [conversationId, actorId],
      );
      return const Ok(null);
    });
  }

  Future<Result<void>> removeMember({
    required String actorId,
    required String conversationId,
    required String targetId,
  }) async {
    if (!_validId(actorId) ||
        !_validId(conversationId) ||
        !_validId(targetId)) {
      return _invalid();
    }
    return _database.transaction((tx) async {
      final conversation = await tx.query(
        'SELECT owner_account_id FROM social_conversations WHERE id = ?',
        [conversationId],
      );
      if (conversation.isEmpty ||
          conversation.single['owner_account_id'] != actorId ||
          await _activeKind(tx, actorId) == null ||
          !(await _isMember(tx, conversationId, actorId)) ||
          !(await _isMember(tx, conversationId, targetId))) {
        return _missing();
      }
      if (actorId == targetId) {
        return err(FailureCode.forbidden, 'Owner cannot remove itself');
      }
      await tx.execute(
        'DELETE FROM social_members WHERE conversation_id = ? AND account_id = ?',
        [conversationId, targetId],
      );
      return const Ok(null);
    });
  }

  Future<Result<void>> withdrawAi({
    required String operatorId,
    required String conversationId,
    required String aiAccountId,
  }) async {
    if (!_validId(operatorId) ||
        !_validId(conversationId) ||
        !_validId(aiAccountId)) {
      return _invalid();
    }
    return _database.transaction((tx) async {
      final authorized = await tx.query(
        '''
SELECT 1 FROM account operator
JOIN ai_operator mapping ON mapping.operator_id = operator.id
JOIN account ai ON ai.id = mapping.ai_id
JOIN social_members member ON member.account_id = ai.id
JOIN social_conversations conversation
  ON conversation.id = member.conversation_id
WHERE operator.id = ? AND operator.kind = 'human' AND operator.disabled = 0
  AND ai.id = ? AND ai.kind = 'ai' AND ai.disabled = 0
  AND conversation.id = ?
''',
        [operatorId, aiAccountId, conversationId],
      );
      if (authorized.isEmpty) return _missing();
      final owner = await tx.query(
        'SELECT owner_account_id FROM social_conversations WHERE id = ?',
        [conversationId],
      );
      if (owner.single['owner_account_id'] == aiAccountId) {
        return err(FailureCode.forbidden, 'Transfer ownership before leaving');
      }
      await tx.execute(
        'DELETE FROM social_members WHERE conversation_id = ? AND account_id = ?',
        [conversationId, aiAccountId],
      );
      return const Ok(null);
    });
  }

  /// 群主设置群公告（空/null 清空）。正文加密落库（AAD 绑定会话 id）。
  Future<Result<void>> setAnnouncement({
    required String actorId,
    required String conversationId,
    String? text,
  }) async {
    if (!_validId(actorId) || !_validId(conversationId)) return _invalid();
    final trimmed = text?.trim();
    if (trimmed != null && trimmed.length > 2000) return _invalid();
    final cipher = _cipher;
    if (cipher == null) {
      return err(FailureCode.internal, 'announcement storage unavailable');
    }
    return _database.transaction((tx) async {
      final rows = await tx.query(
        'SELECT owner_account_id FROM social_conversations WHERE id = ?',
        [conversationId],
      );
      if (rows.isEmpty ||
          rows.single['owner_account_id'] != actorId ||
          await _activeKind(tx, actorId) == null ||
          !(await _isMember(tx, conversationId, actorId))) {
        return _missing();
      }
      final sealed = (trimmed == null || trimmed.isEmpty)
          ? null
          : cipher.encrypt(
              trimmed,
              aad: 'conversation:announcement:$conversationId',
            );
      if (sealed == null) {
        await tx.execute(
          'DELETE FROM group_announcements WHERE conversation_id = ?',
          [conversationId],
        );
      } else {
        await tx.execute(
          'INSERT OR REPLACE INTO group_announcements(conversation_id, sealed, updated_at) VALUES (?, ?, ?)',
          [
            conversationId,
            sealed,
            clock.now().toUtc().millisecondsSinceEpoch,
          ],
        );
      }
      return const Ok<void>(null);
    });
  }

  /// 读取群公告；仅当前成员可见，未设置返回 null。
  Future<Result<String?>> getAnnouncement({
    required String accountId,
    required String conversationId,
  }) async {
    if (!_validId(accountId) || !_validId(conversationId)) return _invalid();
    final cipher = _cipher;
    if (cipher == null) {
      return err(FailureCode.internal, 'announcement storage unavailable');
    }
    return _database.transaction((tx) async {
      if (await _activeKind(tx, accountId) == null ||
          !(await _isMember(tx, conversationId, accountId))) {
        return _missing();
      }
      final rows = await tx.query(
        'SELECT sealed FROM group_announcements WHERE conversation_id = ?',
        [conversationId],
      );
      if (rows.isEmpty) return const Ok<String?>(null);
      final sealed = rows.single['sealed'] as String;
      final decoded = cipher.decrypt(
        sealed,
        aad: 'conversation:announcement:$conversationId',
      );
      if (decoded.isErr) {
        return err(FailureCode.internal, 'stored announcement cannot be decoded');
      }
      return Ok<String?>(decoded.value);
    });
  }

  /// 列出群成员（仅当前成员可列出）。返回 accountId、是否群主、加入时间。
  Future<Result<List<Map<String, Object?>>>> listMembers({
    required String accountId,
    required String conversationId,
  }) async {
    if (!_validId(accountId) || !_validId(conversationId)) return _invalid();
    return _database.transaction((tx) async {
      if (await _activeKind(tx, accountId) == null ||
          !(await _isMember(tx, conversationId, accountId))) {
        return _missing();
      }
      final conversation = await tx.query(
        'SELECT owner_account_id FROM social_conversations WHERE id = ?',
        [conversationId],
      );
      if (conversation.isEmpty) return _missing();
      final owner = conversation.single['owner_account_id'];
      final rows = await tx.query(
        'SELECT account_id, joined_at FROM social_members WHERE conversation_id = ? ORDER BY joined_at, account_id',
        [conversationId],
      );
      return Ok(<Map<String, Object?>>[
        for (final row in rows)
          {
            'accountId': row['account_id'],
            'isOwner': row['account_id'] == owner,
            'joinedAt': row['joined_at'],
          },
      ]);
    });
  }

  Future<String?> _activeKind(Tx tx, String accountId) async {
    final rows = await tx.query(
      '''
SELECT account.kind FROM account
WHERE account.id = ? AND account.disabled = 0
  AND (account.kind = 'human' OR EXISTS (
    SELECT 1 FROM ai_operator
    JOIN account operator ON operator.id = ai_operator.operator_id
    WHERE ai_operator.ai_id = account.id
      AND operator.kind = 'human' AND operator.disabled = 0
  ))
''',
      [accountId],
    );
    return rows.isEmpty ? null : rows.single['kind'] as String;
  }

  Future<bool> _isMember(
    Tx tx,
    String conversationId,
    String accountId,
  ) async => (await tx.query(
    'SELECT 1 FROM social_members WHERE conversation_id = ? AND account_id = ?',
    [conversationId, accountId],
  )).isNotEmpty;

  @override
  Future<int?> firstVisibleSeq(String accountId, String conversationId) async {
    if (!_validId(accountId) || !_validId(conversationId)) return null;
    return _database.transaction((tx) async {
      if (!await _accountExists(tx, accountId)) return null;
      final rows = await tx.query(
        'SELECT m.first_visible_seq FROM social_members m INNER JOIN social_conversations c ON c.id = m.conversation_id WHERE m.account_id = ? AND m.conversation_id = ?',
        [accountId, conversationId],
      );
      return rows.isEmpty ? null : rows.single['first_visible_seq'] as int;
    });
  }

  @override
  Future<bool> canRead(String accountId, String conversationId) async =>
      await firstVisibleSeq(accountId, conversationId) != null;
  @override
  Future<bool> canPost(String accountId, String conversationId) =>
      canRead(accountId, conversationId);
}
