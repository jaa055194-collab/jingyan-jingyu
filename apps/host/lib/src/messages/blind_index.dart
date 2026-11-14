import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../storage/cipher.dart';
import '../storage/database.dart';

/// 加密盲索引：只存 token 的 HMAC 与 message_id 映射，密钥用列加密保存。
///
/// 目的：在正文保持 AES-GCM 加密落库的前提下，为搜索提供候选集，避免全量解密。
/// 已知边界：存在 token 等值/频率泄露；不是明文 FTS，不支持任意子串与短语。
class BlindIndexService {
  BlindIndexService({required Database database, required ColumnCipher cipher})
    : _database = database,
      _cipher = cipher;

  final Database _database;
  final ColumnCipher _cipher;
  List<int>? _keyCache;

  static final RegExp _cjk = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF]+');
  static final RegExp _latin = RegExp(r'[a-z0-9]+');

  /// 规范化分词：中文 bigram；英文/数字按连续词（≥2）。
  static Set<String> tokensFor(String text) {
    final normalized = text.toLowerCase();
    final tokens = <String>{};
    for (final match in _cjk.allMatches(normalized)) {
      final run = match.group(0)!;
      if (run.length == 1) {
        tokens.add(run);
      } else {
        for (var i = 0; i + 1 < run.length; i++) {
          tokens.add(run.substring(i, i + 2));
        }
      }
    }
    for (final match in _latin.allMatches(normalized)) {
      final word = match.group(0)!;
      if (word.length >= 2) tokens.add(word);
    }
    return tokens;
  }

  Future<Result<List<int>>> _key() async {
    final cached = _keyCache;
    if (cached != null) return Ok(cached);
    final rows = await _database.query(
      'SELECT sealed FROM search_index_key WHERE id = ?',
      ['primary'],
    );
    if (rows.isEmpty) {
      final random = Random.secure();
      final key = List<int>.generate(32, (_) => random.nextInt(256));
      final sealed = _cipher.encrypt(
        base64Encode(key),
        aad: 'search:index-key',
      );
      await _database.execute(
        'INSERT INTO search_index_key(id, sealed) VALUES (?, ?)',
        ['primary', sealed],
      );
      _keyCache = key;
      return Ok(key);
    }
    final decoded = _cipher.decrypt(
      rows.single['sealed'] as String,
      aad: 'search:index-key',
    );
    if (decoded.isErr) {
      return err(FailureCode.internal, 'search index key cannot be decoded');
    }
    final key = base64Decode(decoded.value);
    if (key.length != 32) {
      return err(FailureCode.internal, 'search index key is invalid');
    }
    _keyCache = key;
    return Ok(key);
  }

  Future<Result<String>> _hmac(String token) async {
    final key = await _key();
    if (key.isErr) return Err(key.failureOrNull!);
    final digest = Hmac(sha256, key.value).convert(utf8.encode(token));
    return Ok(base64UrlEncode(digest.bytes));
  }

  Future<Result<void>> indexMessage({
    required String messageId,
    required String conversationId,
    required Map<String, Object?> body,
  }) async {
    final tokens = tokensFor(jsonEncode(body));
    final hmacs = <String>[];
    for (final token in tokens) {
      final hmac = await _hmac(token);
      if (hmac.isErr) return Err(hmac.failureOrNull!);
      hmacs.add(hmac.value);
    }
    return _database.transaction((tx) async {
      await tx.execute(
        'DELETE FROM message_search_tokens WHERE message_id = ?',
        [messageId],
      );
      for (final hmac in hmacs) {
        await tx.execute(
          'INSERT OR IGNORE INTO message_search_tokens(message_id, conversation_id, token_hmac) VALUES (?, ?, ?)',
          [messageId, conversationId, hmac],
        );
      }
      return const Ok(null);
    });
  }

  Future<void> removeMessage(String messageId) => _database.execute(
    'DELETE FROM message_search_tokens WHERE message_id = ?',
    [messageId],
  );

  /// 查询匹配全部 token 的候选 message_id。
  Future<Result<List<String>>> candidates(String query) async {
    final tokens = tokensFor(query);
    if (tokens.isEmpty) return Ok(const <String>[]);
    final hmacs = <String>[];
    for (final token in tokens) {
      final hmac = await _hmac(token);
      if (hmac.isErr) return Err(hmac.failureOrNull!);
      hmacs.add(hmac.value);
    }
    final placeholders = List.filled(hmacs.length, '?').join(',');
    final rows = await _database.query(
      '''
SELECT message_id FROM message_search_tokens
WHERE token_hmac IN ($placeholders)
GROUP BY message_id
HAVING COUNT(DISTINCT token_hmac) = ?
''',
      [...hmacs, hmacs.length],
    );
    return Ok([for (final row in rows) row['message_id'] as String]);
  }

  /// 读取候选消息并解密正文；不可解密或已不存在的行被跳过。
  Future<List<Map<String, Object?>>> resolve(List<String> messageIds) async {
    if (messageIds.isEmpty) return const [];
    final placeholders = List.filled(messageIds.length, '?').join(',');
    final rows = await _database.query(
      'SELECT * FROM messages WHERE message_id IN ($placeholders)',
      messageIds,
    );
    final resolved = <Map<String, Object?>>[];
    for (final row in rows) {
      final id = row['message_id'] as String;
      final decoded = _cipher.decrypt(
        row['body'] as String,
        aad: 'messages:body:$id',
      );
      if (decoded.isErr) continue;
      try {
        final body = jsonDecode(decoded.value);
        if (body is! Map<String, dynamic>) continue;
        resolved.add({
          'conversationId': row['conversation_id'],
          'messageId': id,
          'seq': row['seq'],
          'senderId': row['sender_id'],
          'kind': row['kind'],
          'body': Map<String, Object?>.unmodifiable(body),
          'sentAt': row['sent_at'],
        });
      } on FormatException {
        continue;
      }
    }
    return resolved;
  }
}
