/// 客户端输入框草稿存储（纯 Dart、UI 无关）。
///
/// 按账号与会话隔离保存输入草稿；空/纯空白文本视为清除。持久化由外壳用平台
/// 密钥加密落盘；本包仅提供内存模型与版本化 JSON 快照。
library;

import 'package:jingyu_core/jingyu_core.dart';

/// 一条不可变的会话草稿。
class ConversationDraft {
  const ConversationDraft({
    required this.conversationId,
    required this.text,
    required this.updatedAt,
  });

  final String conversationId;
  final String text;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'conversationId': conversationId,
    'text': text,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  /// 返回 null 表示快照条目损坏；非字符串 key 不会被强转。
  static ConversationDraft? fromJson(Map<Object?, Object?> raw) {
    final conversationId = raw['conversationId'];
    final text = raw['text'];
    final updatedAt = raw['updatedAt'];
    if (conversationId is! String || text is! String || updatedAt is! String) {
      return null;
    }
    if (text.trim().isEmpty) return null;
    final parsedAt = DateTime.tryParse(updatedAt);
    if (parsedAt == null) return null;
    try {
      validateId(conversationId, kind: 'conversation');
    } on ArgumentError {
      return null;
    }
    return ConversationDraft(
      conversationId: conversationId,
      text: text,
      updatedAt: parsedAt.toUtc(),
    );
  }
}

/// 账号隔离的会话草稿存储。
class DraftStore {
  final Map<String, Map<String, ConversationDraft>> _data =
      <String, Map<String, ConversationDraft>>{};

  /// 保存草稿；空/纯空白文本等价于 [clear]。
  void save(
    String accountId,
    String conversationId,
    String text, {
    required DateTime updatedAt,
  }) {
    validateId(accountId, kind: 'account');
    validateId(conversationId, kind: 'conversation');
    if (text.trim().isEmpty) {
      clear(accountId, conversationId);
      return;
    }
    _data.putIfAbsent(
      accountId,
      () => <String, ConversationDraft>{},
    )[conversationId] = ConversationDraft(
      conversationId: conversationId,
      text: text,
      updatedAt: updatedAt.toUtc(),
    );
  }

  ConversationDraft? draft(String accountId, String conversationId) =>
      _data[accountId]?[conversationId];

  String? draftText(String accountId, String conversationId) =>
      _data[accountId]?[conversationId]?.text;

  bool hasDraft(String accountId, String conversationId) =>
      _data[accountId]?.containsKey(conversationId) ?? false;

  /// 该账号的草稿，按 updatedAt 降序、再按会话 id 升序，稳定可预期。
  List<ConversationDraft> drafts(String accountId) {
    final Map<String, ConversationDraft>? conversations = _data[accountId];
    if (conversations == null) return const <ConversationDraft>[];
    final List<ConversationDraft> list = conversations.values.toList();
    list.sort((ConversationDraft a, ConversationDraft b) {
      final int byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime != 0
          ? byTime
          : a.conversationId.compareTo(b.conversationId);
    });
    return List<ConversationDraft>.unmodifiable(list);
  }

  void clear(String accountId, String conversationId) {
    final Map<String, ConversationDraft>? conversations = _data[accountId];
    if (conversations == null) return;
    conversations.remove(conversationId);
    if (conversations.isEmpty) _data.remove(accountId);
  }

  void clearAccount(String accountId) => _data.remove(accountId);

  Map<String, Object?> exportAccount(String accountId) => <String, Object?>{
    'version': 1,
    'drafts': <Map<String, Object?>>[
      for (final ConversationDraft draft
          in _data[accountId]?.values ?? <ConversationDraft>[])
        draft.toJson(),
    ],
  };

  /// 验证整份快照后原子替换该账号草稿。损坏/未知版本抛 [FormatException]，原数据不动。
  void importAccount(String accountId, Map<String, Object?> snapshot) {
    validateId(accountId, kind: 'account');
    final Object? version = snapshot['version'];
    final Object? rawDrafts = snapshot['drafts'];
    if (version != 1 || rawDrafts is! List) {
      throw const FormatException('Unsupported or invalid draft snapshot');
    }
    final Map<String, ConversationDraft> staged = <String, ConversationDraft>{};
    for (final Object? raw in rawDrafts) {
      if (raw is! Map<Object?, Object?>) {
        throw const FormatException('Invalid draft entry');
      }
      final ConversationDraft? draft = ConversationDraft.fromJson(raw);
      if (draft == null || staged.containsKey(draft.conversationId)) {
        throw const FormatException('Invalid or duplicate draft');
      }
      staged[draft.conversationId] = draft;
    }
    if (staged.isEmpty) {
      _data.remove(accountId);
    } else {
      _data[accountId] = staged;
    }
  }
}
