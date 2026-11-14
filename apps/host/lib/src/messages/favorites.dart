import 'dart:convert';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/cipher.dart';
import '../storage/database.dart';
import 'favorite_blind_index.dart';

/// Live server-side history boundary. Null denies access before any source decrypt.
typedef FavoriteVisibility =
    Future<int?> Function(String ownerAccountId, String conversationId);

/// Owner-private favorites. User-authored text/link/file metadata is encrypted.
/// Message favorites store references only, and require current source visibility
/// on creation, listing and search; edits/recalls cannot leave readable snapshots.
class FavoritesService {
  FavoritesService({
    required Database database,
    required ColumnCipher cipher,
    this.clock = const SystemClock(),
    String Function()? newId,
    FavoriteBlindIndexService? blind,
  }) : _database = database,
       _cipher = cipher,
       _newId = newId ?? _randomId,
       _blind = blind;

  final Database _database;
  final ColumnCipher _cipher;
  final Clock clock;
  final String Function() _newId;

  /// Optional favorite-specific blind index. When present, search takes token
  /// candidates first, then falls back to a bounded scan to preserve exact
  /// substring recall (the same blind-then-scan semantics as message search).
  final FavoriteBlindIndexService? _blind;
  static const _kinds = {'text', 'message', 'link', 'file'};

  static String _randomId() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
  }

  bool _validId(String id) {
    try {
      validateId(id);
      return true;
    } on FormatException {
      return false;
    }
  }

  Future<Result<Map<String, Object?>>> add({
    required String ownerAccountId,
    required String kind,
    String? messageId,
    String? conversationId,
    String? title,
    String? content,
    List<String>? tags,
    String? note,
    FavoriteVisibility? firstVisibleSeq,
  }) async {
    if (!_validId(ownerAccountId) ||
        !_kinds.contains(kind) ||
        (title != null && title.length > 500) ||
        (content != null && content.length > 65536) ||
        (note != null && note.length > 2000) ||
        (tags != null && tags.length > 20) ||
        (tags != null &&
            tags.any((t) => t.trim().isEmpty || t.length > 50))) {
      return err(FailureCode.invalidArgument, 'Invalid favorite');
    }
    int? first;
    if (kind == 'message') {
      if (messageId == null ||
          conversationId == null ||
          !_validId(messageId) ||
          !_validId(conversationId) ||
          content != null) {
        return err(FailureCode.invalidArgument, 'Message reference required');
      }
      first = await firstVisibleSeq?.call(ownerAccountId, conversationId);
      if (first == null) return err(FailureCode.notFound, 'Not visible');
    } else if (messageId != null ||
        conversationId != null ||
        content == null ||
        content.trim().isEmpty) {
      return err(FailureCode.invalidArgument, 'Content required');
    }
    final id = validateId(_newId(), kind: 'favorite');
    final result = await _database.transaction((tx) async {
      if (kind == 'message') {
        final source = await tx.query(
          'SELECT seq, recalled_at FROM messages WHERE conversation_id = ? AND message_id = ?',
          [conversationId, messageId],
        );
        if (source.isEmpty ||
            source.single['recalled_at'] != null ||
            (source.single['seq'] as int) < first!) {
          return err<Map<String, Object?>>(FailureCode.notFound, 'Not visible');
        }
      }
      await tx.execute(
        '''
INSERT INTO favorites(id, owner_account_id, kind, message_id, conversation_id, title, content, tags, note, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
        [
          id,
          ownerAccountId,
          kind,
          messageId,
          conversationId,
          title == null
              ? null
              : _cipher.encrypt(
                  title,
                  aad: 'favorites:title:$ownerAccountId:$id',
                ),
          kind == 'message'
              ? null
              : _cipher.encrypt(
                  content!,
                  aad: 'favorites:content:$ownerAccountId:$id',
                ),
          tags == null
              ? null
              : _cipher.encrypt(
                  jsonEncode([for (final t in tags) t.trim()]),
                  aad: 'favorites:tags:$ownerAccountId:$id',
                ),
          note == null
              ? null
              : _cipher.encrypt(
                  note,
                  aad: 'favorites:note:$ownerAccountId:$id',
                ),
          clock.now().toUtc().toIso8601String(),
        ],
      );
      return Ok<Map<String, Object?>>({
        'id': id,
        'kind': kind,
        'title': title,
      });
    });
    // Index after the row commits: a message favorite indexes its title only,
    // because its body is the live source and must not be copied into the index.
    final blind = _blind;
    if (blind != null && result.isOk) {
      final tagText = tags == null ? '' : tags.join(' ');
      final searchable = kind == 'message'
          ? '${title ?? ''} $tagText ${note ?? ''}'
          : '${title ?? ''} ${content!} $tagText ${note ?? ''}';
      try {
        await blind.indexFavorite(
          favoriteId: id,
          ownerAccountId: ownerAccountId,
          text: searchable,
        );
      } catch (_) {
        // Indexing must not fail an accepted favorite; search can still scan.
      }
    }
    return result;
  }

  Future<Result<List<Map<String, Object?>>>> list({
    required String ownerAccountId,
    FavoriteVisibility? firstVisibleSeq,
  }) => _read(ownerAccountId, firstVisibleSeq: firstVisibleSeq);

  Future<Result<void>> remove({
    required String ownerAccountId,
    required String favoriteId,
  }) async {
    final Result<void> result = await _database.transaction((tx) async {
      final rows = await tx.query(
        'SELECT id FROM favorites WHERE id = ? AND owner_account_id = ?',
        [favoriteId, ownerAccountId],
      );
      if (rows.isEmpty) return err(FailureCode.notFound, 'Not found');
      await tx.execute(
        'DELETE FROM favorites WHERE id = ? AND owner_account_id = ?',
        [favoriteId, ownerAccountId],
      );
      return const Ok<void>(null);
    });
    if (result.isOk) {
      final blind = _blind;
      if (blind != null) {
        try {
          await blind.removeFavorite(favoriteId);
        } catch (_) {}
      }
    }
    return result;
  }

  /// 更新收藏的标签与备注（整体替换；null 表示清空）。仅本人可改。
  Future<Result<Map<String, Object?>>> updateMeta({
    required String ownerAccountId,
    required String favoriteId,
    required List<String>? tags,
    required String? note,
  }) async {
    if (!_validId(ownerAccountId) ||
        !_validId(favoriteId) ||
        (note != null && note.length > 2000) ||
        (tags != null && tags.length > 20) ||
        (tags != null && tags.any((t) => t.trim().isEmpty || t.length > 50))) {
      return err(FailureCode.invalidArgument, 'Invalid favorite metadata');
    }
    final updated = await _database.transaction((tx) async {
      final rows = await tx.query(
        'SELECT id FROM favorites WHERE id = ? AND owner_account_id = ?',
        [favoriteId, ownerAccountId],
      );
      if (rows.isEmpty) return err(FailureCode.notFound, 'Not found');
      await tx.execute(
        'UPDATE favorites SET tags = ?, note = ? WHERE id = ? AND owner_account_id = ?',
        [
          tags == null
              ? null
              : _cipher.encrypt(
                  jsonEncode([for (final t in tags) t.trim()]),
                  aad: 'favorites:tags:$ownerAccountId:$favoriteId',
                ),
          note == null
              ? null
              : _cipher.encrypt(
                  note,
                  aad: 'favorites:note:$ownerAccountId:$favoriteId',
                ),
          favoriteId,
          ownerAccountId,
        ],
      );
      return const Ok<void>(null);
    });
    if (updated.isErr) return Err(updated.failureOrNull!);
    final blind = _blind;
    if (blind != null) {
      try {
        await _reindex(ownerAccountId, favoriteId, tags, note);
      } catch (_) {
        // Reindex is best-effort; scan fallback keeps search correct.
      }
    }
    return Ok({
      'id': favoriteId,
      'tags': tags == null ? null : [for (final t in tags) t.trim()],
      'note': note,
    });
  }

  Future<void> _reindex(
    String ownerAccountId,
    String favoriteId,
    List<String>? tags,
    String? note,
  ) async {
    final blind = _blind;
    if (blind == null) return;
    final rows = await _database.query(
      'SELECT * FROM favorites WHERE id = ? AND owner_account_id = ?',
      [favoriteId, ownerAccountId],
    );
    if (rows.isEmpty) return;
    final row = rows.single;
    var text = '';
    if (row['title'] != null) {
      final decoded = _cipher.decrypt(
        row['title'] as String,
        aad: 'favorites:title:$ownerAccountId:$favoriteId',
      );
      if (decoded.isOk) text += decoded.value;
    }
    if (row['kind'] != 'message' && row['content'] != null) {
      final decoded = _cipher.decrypt(
        row['content'] as String,
        aad: 'favorites:content:$ownerAccountId:$favoriteId',
      );
      if (decoded.isOk) text += ' ${decoded.value}';
    }
    final tagText = tags == null ? '' : tags.join(' ');
    text += ' $tagText ${note ?? ''}';
    await blind.indexFavorite(
      favoriteId: favoriteId,
      ownerAccountId: ownerAccountId,
      text: text,
    );
  }

  Future<Result<List<Map<String, Object?>>>> search({
    required String ownerAccountId,
    required String query,
    int limit = 50,
    FavoriteVisibility? firstVisibleSeq,
  }) async {
    if (query.trim().isEmpty ||
        query.length > 200 ||
        limit < 1 ||
        limit > 100) {
      return err(FailureCode.invalidArgument, 'Invalid query');
    }
    final needle = query.toLowerCase();
    final hits = <Map<String, Object?>>[];
    final seen = <String>{};

    // Blind-index candidates first (each is still decrypted and re-verified).
    final blind = _blind;
    if (blind != null && FavoriteBlindIndexService.tokensFor(query).isNotEmpty) {
      final candidates = await blind.candidates(
        ownerAccountId: ownerAccountId,
        query: query,
      );
      if (candidates.isErr) return Err(candidates.failureOrNull!);
      for (final favoriteId in candidates.value) {
        if (hits.length >= limit) break;
        if (!seen.add(favoriteId)) continue;
        final rendered = await _renderById(
          ownerAccountId,
          favoriteId,
          firstVisibleSeq,
        );
        if (rendered.isErr) return Err(rendered.failureOrNull!);
        final item = rendered.value;
        if (item == null) continue;
        if (!_matches(item, needle)) continue;
        item['mode'] = 'blind';
        hits.add(item);
      }
    }

    // Scan fallback preserves exact substring recall (token indexes cannot match
    // arbitrary substrings such as part of a Latin word or single characters).
    final rows = await _database.query(
      'SELECT * FROM favorites WHERE owner_account_id = ? ORDER BY rowid',
      [ownerAccountId],
    );
    for (final row in rows) {
      if (hits.length >= limit) break;
      final id = row['id'] as String;
      if (!seen.add(id)) continue;
      final rendered = await _render(row, ownerAccountId, firstVisibleSeq);
      if (rendered.isErr) return Err(rendered.failureOrNull!);
      final item = rendered.value;
      if (item == null) continue;
      if (!_matches(item, needle)) continue;
      item['mode'] = 'scan';
      hits.add(item);
    }
    return Ok(hits);
  }

  bool _matches(Map<String, Object?> item, String needle) {
    final tags = item['tags'];
    final tagText = tags is List ? tags.join(' ') : '';
    return '${item['title'] ?? ''} ${item['content']} $tagText ${item['note'] ?? ''}'
        .toLowerCase()
        .contains(needle);
  }

  Future<Result<List<Map<String, Object?>>>> _read(
    String ownerAccountId, {
    String? query,
    int? limit,
    FavoriteVisibility? firstVisibleSeq,
  }) async {
    final rows = await _database.query(
      'SELECT * FROM favorites WHERE owner_account_id = ? ORDER BY rowid',
      [ownerAccountId],
    );
    final items = <Map<String, Object?>>[];
    for (final row in rows) {
      if (limit != null && items.length >= limit) break;
      final rendered = await _render(row, ownerAccountId, firstVisibleSeq);
      if (rendered.isErr) return Err(rendered.failureOrNull!);
      final item = rendered.value;
      if (item == null) continue;
      if (query != null && !_matches(item, query)) continue;
      items.add(item);
    }
    return Ok(items);
  }

  /// 按 id 读一行再渲染（用于盲索引候选，数量少）。
  Future<Result<Map<String, Object?>?>> _renderById(
    String ownerAccountId,
    String favoriteId,
    FavoriteVisibility? firstVisibleSeq,
  ) async {
    final rows = await _database.query(
      'SELECT * FROM favorites WHERE id = ? AND owner_account_id = ?',
      [favoriteId, ownerAccountId],
    );
    if (rows.isEmpty) return const Ok(null);
    return _render(rows.single, ownerAccountId, firstVisibleSeq);
  }

  /// 渲染一条收藏为对外结构；返回 Ok(null) 表示当前不可见（应跳过），
  /// 返回 Err 表示存储密文损坏（失败关闭，不返回部分数据）。
  Future<Result<Map<String, Object?>?>> _render(
    Map<String, Object?> row,
    String ownerAccountId,
    FavoriteVisibility? firstVisibleSeq,
  ) async {
    final favoriteId = row['id'] as String;
    String? content;
    if (row['kind'] == 'message') {
      final conv = row['conversation_id'] as String;
      final first = await firstVisibleSeq?.call(ownerAccountId, conv);
      if (first == null) return const Ok(null);
      final source = await _database.query(
        'SELECT body, seq, recalled_at FROM messages WHERE conversation_id = ? AND message_id = ?',
        [conv, row['message_id']],
      );
      if (source.isEmpty ||
          source.single['recalled_at'] != null ||
          (source.single['seq'] as int) < first) {
        return const Ok(null);
      }
      final decoded = _cipher.decrypt(
        source.single['body'] as String,
        aad: 'messages:body:${row['message_id']}',
      );
      if (decoded.isErr) {
        return err(FailureCode.internal, 'Stored favorite cannot be decoded');
      }
      try {
        final body = jsonDecode(decoded.value);
        if (body is! Map<String, dynamic>) {
          return err(FailureCode.internal, 'Invalid source body');
        }
        content = jsonEncode(body);
      } on FormatException {
        return err(FailureCode.internal, 'Invalid source body');
      }
    } else {
      final decoded = _cipher.decrypt(
        row['content'] as String,
        aad: 'favorites:content:$ownerAccountId:$favoriteId',
      );
      if (decoded.isErr) {
        return err(FailureCode.internal, 'Stored favorite cannot be decoded');
      }
      content = decoded.value;
    }
    String? title;
    if (row['title'] != null) {
      final decoded = _cipher.decrypt(
        row['title'] as String,
        aad: 'favorites:title:$ownerAccountId:$favoriteId',
      );
      if (decoded.isErr) {
        return err(FailureCode.internal, 'Stored favorite cannot be decoded');
      }
      title = decoded.value;
    }
    List<String>? tags;
    if (row['tags'] != null) {
      final decoded = _cipher.decrypt(
        row['tags'] as String,
        aad: 'favorites:tags:$ownerAccountId:$favoriteId',
      );
      if (decoded.isErr) {
        return err(FailureCode.internal, 'Stored favorite cannot be decoded');
      }
      try {
        final parsed = jsonDecode(decoded.value);
        if (parsed is List) {
          tags = [
            for (final tag in parsed)
              if (tag is String) tag,
          ];
        }
      } on FormatException {
        return err(FailureCode.internal, 'Invalid favorite tags');
      }
    }
    String? note;
    if (row['note'] != null) {
      final decoded = _cipher.decrypt(
        row['note'] as String,
        aad: 'favorites:note:$ownerAccountId:$favoriteId',
      );
      if (decoded.isErr) {
        return err(FailureCode.internal, 'Stored favorite cannot be decoded');
      }
      note = decoded.value;
    }
    return Ok({
      'id': favoriteId,
      'kind': row['kind'],
      'messageId': row['message_id'],
      'conversationId': row['conversation_id'],
      'title': title,
      'content': content,
      'tags': tags,
      'note': note,
      'createdAt': row['created_at'],
    });
  }
}
