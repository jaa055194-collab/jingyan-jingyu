import 'dart:convert';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';

/// A topic describes a root message; it is not a message conversation.
class GroupTopic {
  const GroupTopic({
    required this.id,
    required this.conversationId,
    required this.rootMessageId,
    required this.createdBy,
    required this.createdAt,
  });

  final String id;
  final String conversationId;
  final String rootMessageId;
  final String createdBy;
  final DateTime createdAt;

  factory GroupTopic._row(Map<String, Object?> row) => GroupTopic(
    id: row['id'] as String,
    conversationId: row['conversation_id'] as String,
    rootMessageId: row['root_message_id'] as String,
    createdBy: row['created_by'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      row['created_at'] as int,
      isUtc: true,
    ),
  );
}

/// A pointer to a currently visible source. Contains no copied message body.
class TopicMessageReference {
  const TopicMessageReference({
    required this.messageId,
    required this.seq,
    required this.senderId,
  });

  final String messageId;
  final int seq;
  final String senderId;

  factory TopicMessageReference._row(Map<String, Object?> row) =>
      TopicMessageReference(
        messageId: row['message_id'] as String,
        seq: row['seq'] as int,
        senderId: row['sender_id'] as String,
      );
}

/// Explicit opt-in FR-25 metadata subset; does not send replies, read/decrypt
/// message bodies, invoke AI, or authorize memory collection/context injection.
/// The host must supply authenticated principal IDs, never request JSON actors.
/// Requires accounts, messages, group, direct, and topic migrations.
///
/// All membership, account/operator, history boundary, root/source checks and
/// metadata operations share one Tx, with no cached authorization. A collision
/// between group and direct conversation IDs is denied. Linking an existing
/// message is allowed only to its sender or the current parent-group owner;
/// linking is aggregation and does not declare the source a new topic reply.
class TopicService {
  TopicService({
    required Database database,
    required this.clock,
    String Function()? newId,
  }) : _database = database,
       _newId = newId ?? _randomId;

  final Database _database;
  final Clock clock;
  final String Function() _newId;

  static String _randomId() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
  }

  bool _validIds(List<String> ids) {
    try {
      for (final id in ids) {
        validateId(id);
      }
      return true;
    } on FormatException {
      return false;
    }
  }

  Result<T> _invalid<T>() => err(FailureCode.invalidArgument, 'Invalid input');
  Result<T> _missing<T>() => err(FailureCode.notFound, 'Not found');

  Future<Result<GroupTopic>> create({
    required String actorAccountId,
    required String conversationId,
    required String rootMessageId,
  }) async {
    if (!_validIds([actorAccountId, conversationId, rootMessageId])) {
      return _invalid();
    }
    return _database.transaction((tx) async {
      final access = await _access(tx, actorAccountId, conversationId);
      if (access == null ||
          await _source(tx, conversationId, rootMessageId, access.firstSeq) ==
              null) {
        return _missing();
      }
      final topic = GroupTopic(
        id: validateId(_newId(), kind: 'topic'),
        conversationId: conversationId,
        rootMessageId: rootMessageId,
        createdBy: actorAccountId,
        createdAt: clock.now().toUtc(),
      );
      await tx.execute(
        '''INSERT INTO social_topics
        (id, conversation_id, root_message_id, created_by, created_at)
        VALUES (?, ?, ?, ?, ?)''',
        [
          topic.id,
          topic.conversationId,
          topic.rootMessageId,
          topic.createdBy,
          topic.createdAt.millisecondsSinceEpoch,
        ],
      );
      return Ok(topic);
    });
  }

  Future<Result<GroupTopic>> get({
    required String actorAccountId,
    required String topicId,
  }) async {
    if (!_validIds([actorAccountId, topicId])) return _invalid();
    return _database.transaction((tx) async {
      final visible = await _visibleTopic(tx, actorAccountId, topicId);
      return visible == null ? _missing() : Ok(visible.topic);
    });
  }

  Future<Result<List<GroupTopic>>> list({
    required String actorAccountId,
    required String conversationId,
  }) async {
    if (!_validIds([actorAccountId, conversationId])) return _invalid();
    return _database.transaction((tx) async {
      final access = await _access(tx, actorAccountId, conversationId);
      if (access == null) return _missing();
      final rows = await tx.query(
        '''SELECT t.* FROM social_topics t
        JOIN messages root ON root.message_id = t.root_message_id
          AND root.conversation_id = t.conversation_id
        WHERE t.conversation_id = ? AND root.seq >= ?
        ORDER BY t.created_at, t.id''',
        [conversationId, access.firstSeq],
      );
      return Ok(List<GroupTopic>.unmodifiable(rows.map(GroupTopic._row)));
    });
  }

  Future<Result<void>> associate({
    required String actorAccountId,
    required String topicId,
    required String messageId,
  }) async {
    if (!_validIds([actorAccountId, topicId, messageId])) return _invalid();
    return _database.transaction((tx) async {
      final visible = await _visibleTopic(tx, actorAccountId, topicId);
      if (visible == null) return _missing();
      final source = await _source(
        tx,
        visible.topic.conversationId,
        messageId,
        visible.access.firstSeq,
      );
      if (source == null ||
          (source.senderId != actorAccountId &&
              visible.access.ownerId != actorAccountId)) {
        return _missing();
      }
      // The root is already included implicitly; never create duplicate pointers.
      if (messageId == visible.topic.rootMessageId) return const Ok(null);
      await tx.execute(
        '''INSERT INTO social_topic_references
        (topic_id, message_id, associated_by, associated_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(topic_id, message_id) DO NOTHING''',
        [
          topicId,
          messageId,
          actorAccountId,
          clock.now().toUtc().millisecondsSinceEpoch,
        ],
      );
      return const Ok(null);
    });
  }

  /// Includes the root and currently visible references, ordered by source seq.
  /// Each source is checked again; a missing/foreign/hidden reference is omitted.
  /// A missing/foreign/hidden root instead hides the entire topic (404).
  Future<Result<List<TopicMessageReference>>> references({
    required String actorAccountId,
    required String topicId,
  }) async {
    if (!_validIds([actorAccountId, topicId])) return _invalid();
    return _database.transaction((tx) async {
      final visible = await _visibleTopic(tx, actorAccountId, topicId);
      if (visible == null) return _missing();
      final rows = await tx.query(
        '''SELECT m.message_id, m.seq, m.sender_id FROM messages m
        WHERE m.conversation_id = ? AND m.seq >= ?
          AND (m.message_id = ? OR EXISTS (
            SELECT 1 FROM social_topic_references r
            WHERE r.topic_id = ? AND r.message_id = m.message_id
          ))
        ORDER BY m.seq, m.message_id''',
        [
          visible.topic.conversationId,
          visible.access.firstSeq,
          visible.topic.rootMessageId,
          topicId,
        ],
      );
      return Ok(
        List<TopicMessageReference>.unmodifiable(
          rows.map(TopicMessageReference._row),
        ),
      );
    });
  }

  /// Derives a namespace for the active AI principal's registered profile,
  /// after topic access checks. Requires AI identity migration 501; missing or
  /// ambiguous profiles are denied. This grants no permission to collect, inject or send content;
  /// memory/model callers still need their own source and target authorization.
  Future<Result<TopicScope>> scope({
    required String actorAccountId,
    required String topicId,
  }) async {
    if (!_validIds([actorAccountId, topicId])) return _invalid();
    return _database.transaction((tx) async {
      final visible = await _visibleTopic(tx, actorAccountId, topicId);
      if (visible == null || visible.access.kind != 'ai') return _missing();
      final profiles = await tx.query(
        'SELECT id FROM ai_profile WHERE account_id = ?',
        [actorAccountId],
      );
      if (profiles.length != 1) return _missing();
      final profileId = profiles.single['id'] as String;
      if (!_validIds([profileId])) return _missing();
      return Ok(
        TopicScope(
          aiId: profileId,
          conversationId: visible.topic.conversationId,
          topicId: topicId,
        ),
      );
    });
  }

  Future<_GroupAccess?> _access(
    Tx tx,
    String actorId,
    String conversationId,
  ) async {
    final rows = await tx.query(
      '''SELECT m.first_visible_seq, c.owner_account_id, a.kind
      FROM social_conversations c
      JOIN social_members m ON m.conversation_id = c.id
      JOIN account a ON a.id = m.account_id
      WHERE c.id = ? AND a.id = ? AND a.disabled = 0
        AND NOT EXISTS (SELECT 1 FROM direct_conversations d WHERE d.id = c.id)
        AND (a.kind = 'human' OR (a.kind = 'ai' AND EXISTS (
          SELECT 1 FROM ai_operator mapping
          JOIN account operator ON operator.id = mapping.operator_id
          WHERE mapping.ai_id = a.id
            AND operator.kind = 'human' AND operator.disabled = 0
        )))''',
      [conversationId, actorId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return _GroupAccess(
      firstSeq: row['first_visible_seq'] as int,
      ownerId: row['owner_account_id'] as String,
      kind: row['kind'] as String,
    );
  }

  Future<TopicMessageReference?> _source(
    Tx tx,
    String conversationId,
    String messageId,
    int firstSeq,
  ) async {
    final rows = await tx.query(
      '''SELECT message_id, seq, sender_id FROM messages
      WHERE message_id = ? AND conversation_id = ? AND seq >= ?''',
      [messageId, conversationId, firstSeq],
    );
    return rows.isEmpty ? null : TopicMessageReference._row(rows.single);
  }

  Future<_VisibleTopic?> _visibleTopic(
    Tx tx,
    String actorId,
    String topicId,
  ) async {
    final rows = await tx.query('SELECT * FROM social_topics WHERE id = ?', [
      topicId,
    ]);
    if (rows.isEmpty) return null;
    final topic = GroupTopic._row(rows.single);
    final access = await _access(tx, actorId, topic.conversationId);
    if (access == null ||
        await _source(
              tx,
              topic.conversationId,
              topic.rootMessageId,
              access.firstSeq,
            ) ==
            null) {
      return null;
    }
    return _VisibleTopic(topic, access);
  }
}

class _GroupAccess {
  const _GroupAccess({
    required this.firstSeq,
    required this.ownerId,
    required this.kind,
  });
  final int firstSeq;
  final String ownerId;
  final String kind;
}

class _VisibleTopic {
  const _VisibleTopic(this.topic, this.access);
  final GroupTopic topic;
  final _GroupAccess access;
}
