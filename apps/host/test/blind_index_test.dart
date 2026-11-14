import 'dart:io';

import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/messages/blind_index.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late BlindIndexService blind;
  late SqliteMessageStore messages;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('blind-index-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...messagesMigrations,
        ...socialMigrations,
        privateConversationMigration,
      ],
    );
    cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
    blind = BlindIndexService(database: db, cipher: cipher);
    messages = SqliteMessageStore(database: db, cipher: cipher);
  });

  tearDown(() async {
    cipher.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  test('tokenizer splits CJK bigrams and latin words', () {
    expect(BlindIndexService.tokensFor('项目代号鲸落'), contains('项目'));
    expect(BlindIndexService.tokensFor('项目代号鲸落'), contains('鲸落'));
    expect(
      BlindIndexService.tokensFor('Hello, WORLD!'),
      containsAll(['hello', 'world']),
    );
    expect(BlindIndexService.tokensFor('a b'), isEmpty);
    expect(BlindIndexService.tokensFor('   '), isEmpty);
  });

  test('key is stored encrypted and tokens hold no plaintext', () async {
    final appended = (await messages.append(
      conversationId: 'c1',
      senderId: 'u1',
      clientMsgId: 'm1',
      kind: MessageKind.text,
      body: {'text': '项目代号鲸落'},
    )).value;
    expect(
      (await blind.indexMessage(
        messageId: appended.message.messageId,
        conversationId: 'c1',
        body: appended.message.body,
      )).isOk,
      isTrue,
    );
    final keyRow = (await db.query(
      'SELECT sealed FROM search_index_key',
    )).single;
    expect(keyRow['sealed'] as String, isNot(contains('项目代号')));
    final rows = await db.query(
      'SELECT token_hmac FROM message_search_tokens WHERE message_id = ?',
      [appended.message.messageId],
    );
    expect(rows, isNotEmpty);
    for (final row in rows) {
      expect(row['token_hmac'] as String, isNot(contains('项目')));
    }

    final candidates = await blind.candidates('鲸落');
    expect(candidates.isOk, isTrue);
    expect(candidates.value, contains(appended.message.messageId));
    final resolved = await blind.resolve(candidates.value);
    expect((resolved.single['body'] as Map)['text'], '项目代号鲸落');
  });

  test('reindex replaces tokens and remove clears them', () async {
    final appended = (await messages.append(
      conversationId: 'c1',
      senderId: 'u1',
      clientMsgId: 'm2',
      kind: MessageKind.text,
      body: {'text': '旧词甲'},
    )).value;
    final id = appended.message.messageId;
    await blind.indexMessage(
      messageId: id,
      conversationId: 'c1',
      body: {'text': '旧词甲'},
    );
    await blind.indexMessage(
      messageId: id,
      conversationId: 'c1',
      body: {'text': '新词乙'},
    );
    expect((await blind.candidates('旧词甲')).value, isEmpty);
    expect((await blind.candidates('新词乙')).value, contains(id));
    await blind.removeMessage(id);
    expect((await blind.candidates('新词乙')).value, isEmpty);
  });
}
