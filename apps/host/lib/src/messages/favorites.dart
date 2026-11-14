import 'dart:convert';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/cipher.dart';
import '../storage/database.dart';

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
  }) : _database = database,
       _cipher = cipher,
       _newId = newId ?? _randomId;

  final Database _database;
  final ColumnCipher _cipher;
  final Clock clock;
  final String Function() _newId;
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
    FavoriteVisibility? firstVisibleSeq,
  }) async {
    if (!_validId(ownerAccountId) ||
        !_kinds.contains(kind) ||
        (title != null && title.length > 500) ||
        (content != null && content.length > 65536)) {
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
    return _database.transaction((tx) async {
      if (kind == 'message') {
        final source = await tx.query(
          'SELECT seq, recalled_at FROM messages WHERE conversation_id = ? AND message_id = ?',
          [conversationId, messageId],
        );
        if (source.isEmpty ||
            source.single['recalled_at'] != null ||
            (source.single['seq'] as int) < first!) {
          return err(FailureCode.notFound, 'Not visible');
        }
      }
      await tx.execute(
        '''
INSERT INTO favorites(id, owner_account_id, kind, message_id, conversation_id, title, content, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
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
          clock.now().toUtc().toIso8601String(),
        ],
      );
      return Ok({'id': id, 'kind': kind, 'title': title});
    });
  }

  Future<Result<List<Map<String, Object?>>>> list({
    required String ownerAccountId,
    FavoriteVisibility? firstVisibleSeq,
  }) => _read(ownerAccountId, firstVisibleSeq: firstVisibleSeq);

  Future<Result<void>> remove({
    required String ownerAccountId,
    required String favoriteId,
  }) => _database.transaction((tx) async {
    final rows = await tx.query(
      'SELECT id FROM favorites WHERE id = ? AND owner_account_id = ?',
      [favoriteId, ownerAccountId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'Not found');
    await tx.execute(
      'DELETE FROM favorites WHERE id = ? AND owner_account_id = ?',
      [favoriteId, ownerAccountId],
    );
    return const Ok(null);
  });

  Future<Result<List<Map<String, Object?>>>> search({
    required String ownerAccountId,
    required String query,
    int limit = 50,
    FavoriteVisibility? firstVisibleSeq,
  }) {
    if (query.trim().isEmpty ||
        query.length > 200 ||
        limit < 1 ||
        limit > 100) {
      return Future.value(err(FailureCode.invalidArgument, 'Invalid query'));
    }
    return _read(
      ownerAccountId,
      query: query.toLowerCase(),
      limit: limit,
      firstVisibleSeq: firstVisibleSeq,
    );
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
      final id = row['id'] as String;
      String? content;
      if (row['kind'] == 'message') {
        final conv = row['conversation_id'] as String;
        final first = await firstVisibleSeq?.call(ownerAccountId, conv);
        if (first == null) continue;
        final source = await _database.query(
          'SELECT body, seq, recalled_at FROM messages WHERE conversation_id = ? AND message_id = ?',
          [conv, row['message_id']],
        );
        if (source.isEmpty ||
            source.single['recalled_at'] != null ||
            (source.single['seq'] as int) < first) {
          continue;
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
          aad: 'favorites:content:$ownerAccountId:$id',
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
          aad: 'favorites:title:$ownerAccountId:$id',
        );
        if (decoded.isErr) {
          return err(FailureCode.internal, 'Stored favorite cannot be decoded');
        }
        title = decoded.value;
      }
      if (query != null &&
          !'${title ?? ''} $content'.toLowerCase().contains(query)) {
        continue;
      }
      items.add({
        'id': id,
        'kind': row['kind'],
        'messageId': row['message_id'],
        'conversationId': row['conversation_id'],
        'title': title,
        'content': content,
        'createdAt': row['created_at'],
      });
    }
    return Ok(items);
  }
}
