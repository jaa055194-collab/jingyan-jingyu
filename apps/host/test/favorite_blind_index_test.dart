import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/messages/favorite_blind_index.dart';
import 'package:jingyu_host/src/messages/favorites.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _CountingCipher implements ColumnCipher {
  _CountingCipher(this.delegate);
  final ColumnCipher delegate;
  int decryptCalls = 0;
  @override
  String encrypt(String plaintext, {required String aad}) =>
      delegate.encrypt(plaintext, aad: aad);
  @override
  Result<String> decrypt(String sealed, {required String aad}) {
    decryptCalls++;
    return delegate.decrypt(sealed, aad: aad);
  }
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late FakeClock clock;
  late SqliteMessageStore messages;
  late FavoriteBlindIndexService blind;
  var idCounter = 0;

  FavoritesService newService({ColumnCipher? columnCipher, bool withBlind = true}) =>
      FavoritesService(
        database: db,
        cipher: columnCipher ?? cipher,
        clock: clock,
        newId: () => 'fav-${++idCounter}',
        blind: withBlind ? blind : null,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('favorite-blind-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...messagesMigrations],
    );
    cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
    clock = FakeClock(DateTime.utc(2026, 11, 14, 9));
    messages = SqliteMessageStore(database: db, cipher: cipher, clock: clock);
    blind = FavoriteBlindIndexService(database: db, cipher: cipher);
    idCounter = 0;
  });

  tearDown(() async {
    cipher.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  test('index stores only HMAC tokens and encrypts its key', () async {
    final service = newService();
    final added = await service.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      title: '笔记',
      content: '项目代号鲸落',
    );
    expect(added.isOk, isTrue);

    final tokens = await db.query(
      'SELECT token_hmac FROM favorite_search_tokens',
    );
    expect(tokens, isNotEmpty);
    for (final row in tokens) {
      expect((row['token_hmac'] as String).contains('鲸落'), isFalse);
      expect((row['token_hmac'] as String).contains('项目'), isFalse);
    }

    final key = await db.query(
      "SELECT sealed FROM search_index_key WHERE id = 'favorite-index'",
    );
    expect(key, hasLength(1));
    final sealed = key.single['sealed'] as String;
    expect(sealed.startsWith('v1:'), isTrue);
    expect(sealed.contains('鲸落'), isFalse);
  });

  test('authored favorite is found via blind candidate', () async {
    final service = newService();
    await service.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      title: '书摘',
      content: '项目代号鲸落',
    );
    final result = await service.search(
      ownerAccountId: 'acctA',
      query: '鲸落',
    );
    expect(result.isOk, isTrue);
    expect(result.value, hasLength(1));
    expect(result.value.single['content'], '项目代号鲸落');
    expect(result.value.single['mode'], 'blind');
  });

  test('blind search results equal scan-only results (recall preserved)', () async {
    final blindService = newService(withBlind: true);
    final scanService = newService(withBlind: false);
    await blindService.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      content: '项目代号鲸落',
    );
    await blindService.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      content: 'hello world abc',
    );
    await blindService.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      content: '鲸鱼在游泳',
    );
    for (final query in ['鲸', '鲸落', 'bc', 'hello', 'world', '游', 'xyz']) {
      final blindResult = await blindService.search(
        ownerAccountId: 'acctA',
        query: query,
      );
      final scanResult = await scanService.search(
        ownerAccountId: 'acctA',
        query: query,
      );
      expect(blindResult.isOk, isTrue, reason: 'query=$query');
      expect(scanResult.isOk, isTrue, reason: 'query=$query');
      final blindIds = blindResult.value.map((e) => e['id']).toSet();
      final scanIds = scanResult.value.map((e) => e['id']).toSet();
      expect(blindIds, scanIds, reason: 'query=$query');
    }
  });

  test('message favorite follows live source edits and hides after recall', () async {
    final conversationId = 'conv1';
    final appended = await messages.append(
      conversationId: conversationId,
      senderId: 'acctB',
      clientMsgId: 'c1',
      kind: MessageKind.text,
      body: {'text': '会消失的正文'},
    );
    final messageId = appended.value.message.messageId;
    final service = newService();
    final added = await service.add(
      ownerAccountId: 'acctA',
      kind: 'message',
      messageId: messageId,
      conversationId: conversationId,
      title: '收藏的消息',
      firstVisibleSeq: (_, _) async => 1,
    );
    expect(added.isOk, isTrue);

    var result = await service.search(
      ownerAccountId: 'acctA',
      query: '消失',
      firstVisibleSeq: (_, _) async => 1,
    );
    expect(result.value, hasLength(1));

    final edited = await messages.edit(
      conversationId: conversationId,
      messageId: messageId,
      senderId: 'acctB',
      body: {'text': '全新的内容'},
    );
    expect(edited.isOk, isTrue);
    expect(
      (await service.search(
        ownerAccountId: 'acctA',
        query: '消失',
        firstVisibleSeq: (_, _) async => 1,
      )).value,
      isEmpty,
    );
    expect(
      (await service.search(
        ownerAccountId: 'acctA',
        query: '全新的内容',
        firstVisibleSeq: (_, _) async => 1,
      )).value,
      hasLength(1),
    );

    final recalled = await messages.recall(
      conversationId: conversationId,
      messageId: messageId,
      senderId: 'acctB',
    );
    expect(recalled.isOk, isTrue);
    expect(
      (await service.search(
        ownerAccountId: 'acctA',
        query: '全新的内容',
        firstVisibleSeq: (_, _) async => 1,
      )).value,
      isEmpty,
    );
    expect(
      (await service.list(
        ownerAccountId: 'acctA',
        firstVisibleSeq: (_, _) async => 1,
      )).value,
      isEmpty,
    );
  });

  test('favorites are owner-isolated', () async {
    final service = newService();
    await service.add(ownerAccountId: 'acctA', kind: 'text', content: 'only mine');
    expect(
      (await service.search(ownerAccountId: 'acctB', query: 'mine')).value,
      isEmpty,
    );
    expect(
      (await service.list(ownerAccountId: 'acctB')).value,
      isEmpty,
    );
  });

  test('corrupt stored content fails closed with internal error', () async {
    final service = newService();
    final added = await service.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      title: 't',
      content: 'secret',
    );
    final id = added.value['id'] as String;
    await db.execute('UPDATE favorites SET content = ? WHERE id = ?', [
      'damaged',
      id,
    ]);
    final result = await service.search(
      ownerAccountId: 'acctA',
      query: 'secret',
    );
    expect(result.isErr, isTrue);
    expect(result.failureOrNull!.code, FailureCode.internal);
  });

  test('removing a favorite clears its blind tokens', () async {
    final service = newService();
    final added = await service.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      content: '待删除词',
    );
    final countBefore = await db.query(
      'SELECT COUNT(*) AS c FROM favorite_search_tokens',
    );
    expect(countBefore.single['c'] as int, greaterThan(0));
    await service.remove(
      ownerAccountId: 'acctA',
      favoriteId: added.value['id'] as String,
    );
    final countAfter = await db.query(
      'SELECT COUNT(*) AS c FROM favorite_search_tokens',
    );
    expect(countAfter.single['c'], 0);
  });

  test('blind candidates that reach the limit skip the scan fallback', () async {
    final counting = _CountingCipher(cipher);
    final service = newService(columnCipher: counting);
    await service.add(ownerAccountId: 'acctA', kind: 'text', content: 'alpha unique');
    await service.add(ownerAccountId: 'acctA', kind: 'text', content: 'beta other');
    await service.add(ownerAccountId: 'acctA', kind: 'text', content: 'gamma third');
    counting.decryptCalls = 0;
    final result = await service.search(
      ownerAccountId: 'acctA',
      query: 'alpha',
      limit: 1,
    );
    expect(result.value, hasLength(1));
    expect(result.value.single['mode'], 'blind');
    // The single candidate fills the limit, so the scan fallback never decrypts
    // the two non-matching authored favorites.
    expect(counting.decryptCalls, lessThan(3));
  });

  test('blind candidates directly reflect indexed content and owner scope', () async {
    final service = newService();
    final target = await service.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      content: '项目代号鲸落',
    );
    await service.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      content: '完全无关的文本',
    );
    final sameOwner = await blind.candidates(
      ownerAccountId: 'acctA',
      query: '鲸落',
    );
    expect(sameOwner.isOk, isTrue);
    expect(sameOwner.value, [target.value['id']]);
    final otherOwner = await blind.candidates(
      ownerAccountId: 'acctB',
      query: '鲸落',
    );
    expect(otherOwner.value, isEmpty);
  });
}
