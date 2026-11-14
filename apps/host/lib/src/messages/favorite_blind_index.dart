import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../storage/cipher.dart';
import '../storage/database.dart';
import 'blind_index.dart';

/// 收藏专用加密盲索引。
///
/// 与消息盲索引同构（只存 token 的 HMAC 和收藏 id 的映射，密钥用列加密保存），
/// 但使用独立密钥行 `favorite-index`，不与消息 `primary` 密钥混用。目的：收藏
/// 搜索在保留标题/自填内容 AES-GCM 加密落库的前提下，先取候选收藏，避免逐条
/// 解密全部收藏。消息引用类收藏的正文是实时来源，不复制进索引（见 FavoritesService）。
///
/// 已知边界：存在 token 等值/频率泄露；不是明文 FTS，不支持任意子串。
class FavoriteBlindIndexService {
  FavoriteBlindIndexService({
    required Database database,
    required ColumnCipher cipher,
  }) : _database = database,
       _cipher = cipher;

  final Database _database;
  final ColumnCipher _cipher;
  List<int>? _keyCache;

  static const String _keyId = 'favorite-index';
  static const String _keyAad = 'favorite:index-key';

  /// 与服务端消息盲索引共用同一套规范化分词：中文 bigram，英文/数字按词（≥2）。
  static Set<String> tokensFor(String text) => BlindIndexService.tokensFor(text);

  Future<Result<List<int>>> _key() async {
    final cached = _keyCache;
    if (cached != null) return Ok(cached);
    final rows = await _database.query(
      'SELECT sealed FROM search_index_key WHERE id = ?',
      [_keyId],
    );
    if (rows.isEmpty) {
      final random = Random.secure();
      final key = List<int>.generate(32, (_) => random.nextInt(256));
      final sealed = _cipher.encrypt(base64Encode(key), aad: _keyAad);
      await _database.execute(
        'INSERT INTO search_index_key(id, sealed) VALUES (?, ?)',
        [_keyId, sealed],
      );
      _keyCache = key;
      return Ok(key);
    }
    final decoded = _cipher.decrypt(rows.single['sealed'] as String, aad: _keyAad);
    if (decoded.isErr) {
      return err(FailureCode.internal, 'favorite index key cannot be decoded');
    }
    final key = base64Decode(decoded.value);
    if (key.length != 32) {
      return err(FailureCode.internal, 'favorite index key is invalid');
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

  /// 以给定文本重建一条收藏的 token（先删后插，天然幂等）。
  Future<Result<void>> indexFavorite({
    required String favoriteId,
    required String ownerAccountId,
    required String text,
  }) async {
    final tokens = tokensFor(text);
    final hmacs = <String>[];
    for (final token in tokens) {
      final hmac = await _hmac(token);
      if (hmac.isErr) return Err(hmac.failureOrNull!);
      hmacs.add(hmac.value);
    }
    return _database.transaction((tx) async {
      await tx.execute(
        'DELETE FROM favorite_search_tokens WHERE favorite_id = ?',
        [favoriteId],
      );
      for (final hmac in hmacs) {
        await tx.execute(
          'INSERT OR IGNORE INTO favorite_search_tokens(favorite_id, owner_account_id, token_hmac) VALUES (?, ?, ?)',
          [favoriteId, ownerAccountId, hmac],
        );
      }
      return const Ok(null);
    });
  }

  Future<void> removeFavorite(String favoriteId) => _database.execute(
    'DELETE FROM favorite_search_tokens WHERE favorite_id = ?',
    [favoriteId],
  );

  /// 返回匹配查询全部 token 的候选收藏 id（同一 owner 范围内）。
  Future<Result<List<String>>> candidates({
    required String ownerAccountId,
    required String query,
  }) async {
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
SELECT favorite_id FROM favorite_search_tokens
WHERE owner_account_id = ? AND token_hmac IN ($placeholders)
GROUP BY favorite_id
HAVING COUNT(DISTINCT token_hmac) = ?
''',
      [ownerAccountId, ...hmacs, hmacs.length],
    );
    return Ok([for (final row in rows) row['favorite_id'] as String]);
  }
}
