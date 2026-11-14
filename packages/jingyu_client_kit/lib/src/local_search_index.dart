/// 客户端本地搜索索引（纯 Dart、UI 无关）。
///
/// 为离线/弱网场景提供按账号隔离的内存倒排索引：外壳把已同步到本地的消息
/// 灌进来，就能在不联网的情况下做全文检索。
///
/// 设计边界（见 DESIGN.md「3. 客户端本地索引」）：
/// * 本包只维护内存结构 + 可序列化快照，**不**直接读写磁盘；
///   持久化由外壳用平台密钥加密落盘（避免明文落盘）。
/// * token 规则与服务端盲索引一致：CJK 相邻二元组 + 单字（unigrams+bigrams，
///   保证单字查询可用），Latin/数字连续串长度≥2 作为整词，全部小写。
/// * 由于是本地索引，允许 token 是检索结果的超集：真正的命中由 `search`
///   末尾的 `contains` 复核保证（因此部分子串/单字查询也能正确命中）。
library;

/// 一条检索命中（轻量值对象，不含内部索引结构）。
class LocalSearchHit {
  const LocalSearchHit({
    required this.messageId,
    required this.conversationId,
    required this.seq,
    required this.senderId,
    required this.kind,
    required this.sentAt,
    required this.text,
  });

  /// 消息 id。
  final String messageId;

  /// 所属会话 id。
  final String conversationId;

  /// 会话内单调序号（用于排序）。
  final int seq;

  /// 发送者 id。
  final String senderId;

  /// 消息类型（线协议字符串，如 `text`）。
  final String kind;

  /// 发送时刻。
  final DateTime sentAt;

  /// 命中消息的正文。
  final String text;
}

/// 内部：单条索引条目。
class _Entry {
  _Entry({
    required this.messageId,
    required this.conversationId,
    required this.seq,
    required this.senderId,
    required this.kind,
    required this.text,
    required this.sentAt,
  });

  final String messageId;
  final String conversationId;
  final int seq;
  final String senderId;
  final String kind;
  final String text;
  final DateTime sentAt;
}

/// 内部：单个账号的索引（正向表 + 倒排表）。
class _AccountIndex {
  final Map<String, _Entry> entries = <String, _Entry>{};
  final Map<String, Set<String>> inverted = <String, Set<String>>{};
}

/// 按账号隔离的客户端本地搜索索引。
///
/// 生命周期与账号绑定：登出/换账号用 [clearAccount]，持久化用
/// [exportAccount] / [importAccount]（快照可 JSON 序列化，外壳负责加密落盘）。
class LocalSearchIndex {
  /// 每个账号一份索引。
  final Map<String, _AccountIndex> _accounts = <String, _AccountIndex>{};

  /// 分词。lowercase；CJK 连续串：长度 1 加单字，长度≥2 加所有相邻二元组
  /// **和**所有单字；Latin/数字连续串长度≥2 作为整词。其它字符作分隔符。
  static Set<String> tokenize(String text) {
    final tokens = <String>{};
    final runes = text.toLowerCase().runes.toList();
    var i = 0;
    while (i < runes.length) {
      final rune = runes[i];
      if (_isCjkRune(rune)) {
        var j = i;
        while (j < runes.length && _isCjkRune(runes[j])) {
          j++;
        }
        final run = runes.sublist(i, j);
        if (run.length == 1) {
          tokens.add(String.fromCharCode(run.first));
        } else {
          for (var k = 0; k < run.length; k++) {
            tokens.add(String.fromCharCode(run[k]));
          }
          for (var k = 0; k + 1 < run.length; k++) {
            tokens.add(String.fromCharCodes(run.sublist(k, k + 2)));
          }
        }
        i = j;
      } else if (_isWordRune(rune)) {
        var j = i;
        while (j < runes.length && _isWordRune(runes[j])) {
          j++;
        }
        if (j - i >= 2) {
          tokens.add(String.fromCharCodes(runes.sublist(i, j)));
        }
        i = j;
      } else {
        i++;
      }
    }
    return tokens;
  }

  /// 新增或替换（编辑）一条消息，幂等地维护倒排索引。
  void applyMessage(
    String accountId, {
    required String conversationId,
    required String messageId,
    required int seq,
    required String senderId,
    required String kind,
    required String text,
    required DateTime sentAt,
  }) {
    final account = _accounts.putIfAbsent(accountId, () => _AccountIndex());
    final old = account.entries[messageId];
    if (old != null) {
      _dropFromInverted(account, old);
    }
    final entry = _Entry(
      messageId: messageId,
      conversationId: conversationId,
      seq: seq,
      senderId: senderId,
      kind: kind,
      text: text,
      sentAt: sentAt,
    );
    account.entries[messageId] = entry;
    _addToInverted(account, entry);
  }

  /// 删除一条消息（撤回/删除），同时清理其 token。
  void removeMessage(String accountId, String messageId) {
    final account = _accounts[accountId];
    if (account == null) return;
    final old = account.entries.remove(messageId);
    if (old != null) {
      _dropFromInverted(account, old);
    }
  }

  /// 检索。空/空白 query 返回 `const []`。
  ///
  /// 先用可靠的 token 缩小候选（AND），再用 `contains` 复核精确子串，
  /// 最后按 seq 升序、按 [limit] 截断；可按 [conversationId] 限定会话。
  List<LocalSearchHit> search(
    String accountId,
    String query, {
    String? conversationId,
    int limit = 50,
  }) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <LocalSearchHit>[];
    if (limit <= 0) return const <LocalSearchHit>[];

    final account = _accounts[accountId];
    if (account == null) return const <LocalSearchHit>[];

    final tokens = tokenize(trimmed);
    if (tokens.isEmpty) return const <LocalSearchHit>[];

    // 只有 CJK token（单字/二元组）能作为"安全"的 AND 过滤：任何包含完整
    // query 子串的正文必然也包含这些 token。Latin 整词 token 可能只是别的
    // 单词的子串（如 query `bc` 之于正文 `abc`），用它做交会会漏结果，
    // 因此只用它之外的 CJK token 缩小范围，正确性交给 contains 复核。
    Set<String>? candidates;
    for (final token in tokens) {
      if (!_isCjkToken(token)) continue;
      final posting = account.inverted[token];
      if (posting == null) continue; // 该 token 未出现在任何正文里：不额外限制
      candidates = candidates == null
          ? posting.toSet()
          : candidates.intersection(posting);
      if (candidates.isEmpty) break;
    }

    final needle = trimmed.toLowerCase();
    final pool = candidates ?? account.entries.keys.toSet();
    final hits = <LocalSearchHit>[];
    for (final messageId in pool) {
      final entry = account.entries[messageId];
      if (entry == null) continue;
      if (conversationId != null && entry.conversationId != conversationId) {
        continue;
      }
      if (!entry.text.toLowerCase().contains(needle)) continue;
      hits.add(LocalSearchHit(
        messageId: entry.messageId,
        conversationId: entry.conversationId,
        seq: entry.seq,
        senderId: entry.senderId,
        kind: entry.kind,
        sentAt: entry.sentAt,
        text: entry.text,
      ));
    }

    hits.sort((a, b) => a.seq.compareTo(b.seq));
    if (hits.length > limit) {
      return hits.sublist(0, limit);
    }
    return hits;
  }

  /// 清空某个账号的全部索引（登出/换账号）。
  void clearAccount(String accountId) {
    _accounts.remove(accountId);
  }

  /// 导出某账号的 JSON 可序列化快照（外壳负责加密落盘）。
  Map<String, Object?> exportAccount(String accountId) {
    final messages = <Object?>[];
    final account = _accounts[accountId];
    if (account != null) {
      for (final entry in account.entries.values) {
        messages.add(<String, Object?>{
          'messageId': entry.messageId,
          'conversationId': entry.conversationId,
          'seq': entry.seq,
          'senderId': entry.senderId,
          'kind': entry.kind,
          'text': entry.text,
          'sentAt': entry.sentAt.toIso8601String(),
        });
      }
    }
    return <String, Object?>{'version': 1, 'messages': messages};
  }

  /// 从快照恢复某账号索引（先清空该账号已有数据，再整体重建倒排）。
  void importAccount(String accountId, Map<String, Object?> snapshot) {
    clearAccount(accountId);
    final rawMessages = snapshot['messages'];
    if (rawMessages is! Iterable<Object?>) return;
    for (final raw in rawMessages) {
      if (raw is! Map<Object?, Object?>) continue;
      final messageId = raw['messageId'];
      final conversationId = raw['conversationId'];
      final senderId = raw['senderId'];
      final kind = raw['kind'];
      final text = raw['text'];
      if (messageId is! String ||
          conversationId is! String ||
          senderId is! String ||
          kind is! String ||
          text is! String) {
        continue;
      }
      final seqValue = raw['seq'];
      final seq = seqValue is int ? seqValue : int.tryParse('$seqValue') ?? 0;
      final sentAtValue = raw['sentAt'];
      final sentAt = sentAtValue is String
          ? (DateTime.tryParse(sentAtValue) ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      applyMessage(
        accountId,
        conversationId: conversationId,
        messageId: messageId,
        seq: seq,
        senderId: senderId,
        kind: kind,
        text: text,
        sentAt: sentAt,
      );
    }
  }

  void _addToInverted(_AccountIndex account, _Entry entry) {
    for (final token in tokenize(entry.text)) {
      account.inverted.putIfAbsent(token, () => <String>{}).add(entry.messageId);
    }
  }

  void _dropFromInverted(_AccountIndex account, _Entry entry) {
    for (final token in tokenize(entry.text)) {
      final posting = account.inverted[token];
      if (posting == null) continue;
      posting.remove(entry.messageId);
      if (posting.isEmpty) {
        account.inverted.remove(token);
      }
    }
  }

  static bool _isCjkToken(String token) =>
      token.runes.any(_isCjkRune);

  /// CJK 判定：主区、扩展 A/B、兼容区、假名。
  static bool _isCjkRune(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0x3400 && rune <= 0x4DBF) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0x20000 && rune <= 0x2A6DF) ||
      (rune >= 0x3040 && rune <= 0x30FF);

  /// Latin 小写字母或数字（用于整词 run；单字符 run 不建 token）。
  static bool _isWordRune(int rune) =>
      (rune >= 0x30 && rune <= 0x39) || (rune >= 0x61 && rune <= 0x7A);
}
