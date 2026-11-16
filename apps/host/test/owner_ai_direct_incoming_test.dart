import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/brain/owner_ai_direct_incoming.dart';
import 'package:jingyu_host/src/brain/owner_ai_direct_source_migration.dart';
import 'package:jingyu_host/src/messages/message_store.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_consent.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_migration.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/private_conversations.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

const _migrations = [
  ...allMigrations,
  ...accountsMigrations,
  ...messagesMigrations,
  ...socialMigrations,
  friendshipMigration,
  privateConversationMigration,
  aiIdentityMigration,
  ownerAiDirectMigration,
  ownerAiProfileInvalidationMigration,
  ownerAiDirectSourceMigration,
];

void main() {
  late Directory dir;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late SqliteMessageStore messages;
  late OwnerAiDirectIncoming incoming;
  late OwnerAiDirectConsent consent;
  final clock = FakeClock(DateTime.utc(2026, 11, 17));

  Future<void> connect() async {
    db = await SqliteDatabase.open(
      '${dir.path}/host.sqlite',
      migrations: _migrations,
    );
    messages = SqliteMessageStore(database: db, cipher: cipher, clock: clock);
    incoming = OwnerAiDirectIncoming(database: db, messages: messages);
    consent = OwnerAiDirectConsent(database: db, clock: clock);
  }

  Future<void> account(String id, String kind) => db
      .execute(
        '''INSERT INTO account
(id,display_name,kind,is_admin,disabled,password_hash,failed_passwords,locked_until)
VALUES(?,?,?,0,0,?,0,0)''',
        [id, id, kind, kind == 'human' ? 'test' : null],
      )
      .then((_) {});

  Future<String> open([int revision = 0]) async =>
      (await consent.open(
            ownerId: 'owner',
            aiProfileId: 'profile',
            expectedRevision: revision,
          )).value['conversationId']
          as String;

  Future<Result<AppendResult>> append(
    String conversation,
    String clientId, {
    String sender = 'owner',
    MessageKind kind = MessageKind.text,
    Map<String, Object?> body = const {'text': 'ordinary owner message'},
  }) => incoming.append(
    conversationId: conversation,
    senderId: sender,
    clientMsgId: clientId,
    kind: kind,
    body: body,
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('owner-ai-incoming-');
    cipher = AesGcmColumnCipher(List<int>.filled(32, 33));
    await connect();
    await account('owner', 'human');
    await account('other', 'human');
    await account('ai-account', 'ai');
    await db.execute('INSERT INTO ai_operator(ai_id,operator_id) VALUES(?,?)', [
      'ai-account',
      'owner',
    ]);
    await db.execute('INSERT INTO ai_profile(id,account_id) VALUES(?,?)', [
      'profile',
      'ai-account',
    ]);
  });
  tearDown(() async {
    await db.close();
    cipher.dispose();
    await dir.delete(recursive: true);
  });

  test(
    'fresh exact owner text stamps canonical accepted source at current revision',
    () async {
      final conversation = await open();
      final result = (await append(conversation, 'source')).value;
      final stamp = (await db.query(
        'SELECT * FROM owner_ai_direct_sources',
      )).single;
      expect(stamp, {
        'source_message_id': result.message.messageId,
        'owner_account_id': 'owner',
        'ai_profile_id': 'profile',
        'ai_account_id': 'ai-account',
        'conversation_id': conversation,
        'grant_revision': 1,
      });
      expect(result.duplicate, isFalse);
      expect(await messages.headSeq(conversation), 1);
      final retry = (await append(conversation, 'source')).value;
      expect(retry.duplicate, isTrue);
      expect(
        (await db.query('SELECT * FROM owner_ai_direct_sources')).length,
        1,
      );
    },
  );

  test(
    'revoke after canPost precheck denies tagged append before any head write',
    () async {
      final conversation = await open();
      final direct = PrivateConversations(db: db, clock: clock);
      expect(await direct.canPost('owner', conversation), isTrue);
      await consent.revoke(
        ownerId: 'owner',
        aiProfileId: 'profile',
        expectedRevision: 1,
      );
      final denied = await append(conversation, 'too-late');
      expect(denied.failureOrNull?.code, FailureCode.notFound);
      expect(await messages.headSeq(conversation), 0);
      expect(await db.query('SELECT * FROM messages'), isEmpty);
      expect(await db.query('SELECT * FROM owner_ai_direct_sources'), isEmpty);
    },
  );

  test(
    'group collision after successful precheck denies valid tagged grant with zero writes',
    () async {
      final conversation = await open();
      final direct = PrivateConversations(db: db, clock: clock);
      expect(await direct.canPost('owner', conversation), isTrue);
      await db.execute(
        '''INSERT INTO social_conversations
(id,owner_account_id,name,history_visibility,created_at) VALUES(?,?,?,'all',0)''',
        [conversation, 'other', 'colliding group'],
      );
      // The grant resolver alone does not reject a group/direct ID collision.
      final grant = await db.transaction(
        (tx) => OwnerAiDirectConsent.resolveInTx(
          tx,
          ownerAccountId: 'owner',
          conversationId: conversation,
        ),
      );
      expect(grant, isNotNull);
      for (final sender in ['owner', 'ai-account']) {
        final denied = await append(
          conversation,
          'collision-$sender',
          sender: sender,
        );
        expect(denied.failureOrNull?.code, FailureCode.notFound);
      }
      expect(await db.query('SELECT * FROM message_heads'), isEmpty);
      expect(await db.query('SELECT * FROM messages'), isEmpty);
      expect(await db.query('SELECT * FROM owner_ai_direct_sources'), isEmpty);
    },
  );

  test(
    'tagged conversation rejects outsiders and disabled/reassigned identities',
    () async {
      final conversation = await open();
      expect(
        (await append(
          conversation,
          'outsider',
          sender: 'other',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      await db.execute('UPDATE ai_operator SET operator_id=? WHERE ai_id=?', [
        'other',
        'ai-account',
      ]);
      expect(
        (await append(conversation, 'old-owner')).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await append(
          conversation,
          'ai',
          sender: 'ai-account',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(await messages.headSeq(conversation), 0);
    },
  );

  test(
    'active AI and metadata text are accepted but never create source stamps',
    () async {
      final conversation = await open();
      final cases = <(String, MessageKind, Map<String, Object?>)>[
        ('ai-account', MessageKind.text, {'text': 'AI reply'}),
        (
          'owner',
          MessageKind.text,
          {
            'text': 'mention',
            'mentionAccountIds': ['ai-account'],
          },
        ),
        (
          'owner',
          MessageKind.text,
          {'text': 'attachment', 'attachmentId': 'a'},
        ),
        ('owner', MessageKind.text, {'text': 'reply', 'replyTo': 'source'}),
        (
          'owner',
          MessageKind.text,
          {'text': 'own source marker', 'source': 's1'},
        ),
        ('owner', MessageKind.text, {'text': ''}),
        ('owner', MessageKind.text, {'text': 1}),
        ('owner', MessageKind.file, {'text': 'file'}),
      ];
      for (var i = 0; i < cases.length; i++) {
        final (sender, kind, body) = cases[i];
        expect(
          (await append(
            conversation,
            'non-source-$i',
            sender: sender,
            kind: kind,
            body: body,
          )).isOk,
          isTrue,
        );
      }
      expect(await messages.headSeq(conversation), cases.length);
      expect(await db.query('SELECT * FROM owner_ai_direct_sources'), isEmpty);
    },
  );

  test(
    'stamp insertion failure rolls back message and its allocated head',
    () async {
      final conversation = await open();
      await db.execute(
        '''CREATE TRIGGER reject_source BEFORE INSERT ON owner_ai_direct_sources
BEGIN SELECT RAISE(ABORT, 'forced stamp failure'); END''',
      );
      await expectLater(
        append(conversation, 'atomic'),
        throwsA(isA<Exception>()),
      );
      expect(await db.query('SELECT * FROM messages'), isEmpty);
      expect(await db.query('SELECT * FROM message_heads'), isEmpty);
      expect(await db.query('SELECT * FROM owner_ai_direct_sources'), isEmpty);
      await db.execute('DROP TRIGGER reject_source');
      final retry = (await append(conversation, 'atomic')).value;
      expect(retry.duplicate, isFalse);
      expect(retry.message.seq, 1);
    },
  );

  test(
    'revoke/reopen duplicate never gains a retroactive source stamp',
    () async {
      final conversation = await open();
      final old = (await messages.append(
        conversationId: conversation,
        senderId: 'owner',
        clientMsgId: 'legacy',
        kind: MessageKind.text,
        body: const {'text': 'old unapproved source'},
      )).value;
      await consent.revoke(
        ownerId: 'owner',
        aiProfileId: 'profile',
        expectedRevision: 1,
      );
      expect(
        (await append(conversation, 'legacy')).failureOrNull?.code,
        FailureCode.notFound,
      );
      await db.close();
      await connect();
      expect(await open(2), conversation);
      final duplicate = (await append(conversation, 'legacy')).value;
      expect(duplicate.duplicate, isTrue);
      expect(duplicate.message.messageId, old.message.messageId);
      expect(await db.query('SELECT * FROM owner_ai_direct_sources'), isEmpty);
      await append(conversation, 'new-source');
      expect(
        (await db.query(
          'SELECT grant_revision FROM owner_ai_direct_sources',
        )).single['grant_revision'],
        3,
      );
    },
  );

  test(
    'historical source stamp survives revoke/reopen and does not change revision on duplicate',
    () async {
      final conversation = await open();
      await append(conversation, 'stamped');
      await consent.revoke(
        ownerId: 'owner',
        aiProfileId: 'profile',
        expectedRevision: 1,
      );
      await open(2);
      expect((await append(conversation, 'stamped')).value.duplicate, isTrue);
      expect(
        (await db.query(
          'SELECT grant_revision FROM owner_ai_direct_sources',
        )).single['grant_revision'],
        1,
      );
    },
  );

  test(
    'untagged human chat and group preserve normal append and idempotency with no stamp',
    () async {
      for (final conversation in ['hh', 'group']) {
        final first = (await append(conversation, 'same')).value;
        expect(first.message.seq, 1);
        expect(first.duplicate, isFalse);
        expect((await append(conversation, 'same')).value.duplicate, isTrue);
      }
      expect(await db.query('SELECT * FROM owner_ai_direct_sources'), isEmpty);
    },
  );

  test(
    'invalid input and unserializable body do not write head or stamp',
    () async {
      final conversation = await open();
      expect(
        (await append(conversation, '')).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(
        (await append(
          conversation,
          'bad',
          body: {'text': Object()},
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(await db.query('SELECT * FROM messages'), isEmpty);
      expect(await db.query('SELECT * FROM message_heads'), isEmpty);
      expect(await db.query('SELECT * FROM owner_ai_direct_sources'), isEmpty);
    },
  );
}
