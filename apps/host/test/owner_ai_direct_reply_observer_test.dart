import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_service.dart';
import 'package:jingyu_host/src/brain/owner_ai_direct_reply_observer.dart';
import 'package:jingyu_host/src/brain/owner_reply_attempts.dart';
import 'package:jingyu_host/src/brain/owner_reply_attempts_migration.dart';
import 'package:jingyu_host/src/brain/owner_ai_direct_source_migration.dart';
import 'package:jingyu_host/src/messages/message_store.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/binding_matrix.dart';
import 'package:jingyu_host/src/models/binding_migrations.dart';
import 'package:jingyu_host/src/models/models_migrations.dart';
import 'package:jingyu_host/src/models/openai_chat_adapter.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/models/stateless_owner_chat.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_consent.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_migration.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  late SqliteDatabase db;
  late Directory temp;
  late AesGcmColumnCipher cipher;
  late SqliteMessageStore messages;
  late OwnerAiDirectConsent consent;
  late StatelessOwnerChat chat;
  late String direct;
  final clock = FakeClock(DateTime.utc(2026, 11, 17));
  var calls = 0, admissions = 0;
  var allowS1 = true;
  Failure? failure;
  Completer<void>? entered, release;
  List<ChatTurn> receivedTurns = [];
  final pinned = ResolvedBinding(
    ownerId: 'owner',
    aiProfileId: AiId.parse('profile'),
    aiAccountId: AccountId.parse('ai'),
    capability: ProviderCapability.chat,
    providerId: 'provider',
    model: 'model',
  );

  OwnerAiDirectReplyObserver compose({
    OwnerReplyAttempts? attempts,
    bool runtime = true,
    Future<bool> Function(OwnerAiDirectGrant)? admit,
    Future<Result<ResolvedBinding>> Function(OwnerAiDirectGrant)? binding,
    SqliteMessageStore? store,
  }) => OwnerAiDirectReplyObserver(
    database: db,
    cipher: cipher,
    messages: store ?? messages,
    system: 'Trusted system.',
    maxTokens: 32,
    admitS1:
        admit ??
        (_) async {
          admissions++;
          return allowS1;
        },
    resolveBinding: binding ?? (_) async => Ok(pinned),
    chat: runtime ? chat : null,
    attempts: attempts ?? const OwnerReplyAttempts(),
  );
  Future<StoredMessage> send({
    String text = '为什么这样？',
    String sender = 'owner',
    String? conversation,
    Map<String, Object?>? body,
    MessageKind kind = MessageKind.text,
    bool stamp = true,
  }) async {
    final scope = conversation ?? direct;
    final id = 'human_${await messages.headSeq(scope)}';
    return db.transaction((tx) async {
      final source = (await messages.appendInTransaction(
        tx,
        conversationId: scope,
        senderId: sender,
        clientMsgId: id,
        kind: kind,
        body: body ?? {'text': text},
      )).value.message;
      final grant = await OwnerAiDirectConsent.resolveInTx(
        tx,
        ownerAccountId: sender,
        conversationId: scope,
      );
      if (stamp && grant != null) {
        await tx.execute(
          'INSERT INTO owner_ai_direct_sources VALUES(?,?,?,?,?,?)',
          [
            source.messageId,
            grant.ownerAccountId,
            grant.aiProfileId,
            grant.aiAccountId,
            grant.conversationId,
            grant.revision,
          ],
        );
      }
      return source;
    });
  }

  Future<List<StoredMessage>> rows() async => (await messages.since(
    conversationId: direct,
    afterSeq: 0,
  )).value.messages;
  Future<OwnerReplyAttempt?> attempt(StoredMessage source) => db.transaction(
    (tx) => const OwnerReplyAttempts().getForOwnerInTx(
      tx,
      ownerAccountId: 'owner',
      sourceMessageId: source.messageId,
      aiProfileId: 'profile',
    ),
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('owner-observer-');
    db = await SqliteDatabase.open(
      '${temp.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...messagesMigrations,
        ownerReplyAttemptsMigration,
        ownerAiDirectSourceMigration,
        ...socialMigrations,
        friendshipMigration,
        privateConversationMigration,
        ownerAiDirectMigration,
        ...modelsMigrations,
        aiIdentityMigration,
        bindingMigration,
        ownerAiProfileInvalidationMigration,
        ...personaMigrations,
      ],
    );
    cipher = AesGcmColumnCipher(List.generate(32, (i) => i));
    messages = SqliteMessageStore(database: db, cipher: cipher, clock: clock);
    for (final owner in ['owner', 'other']) {
      await db.execute(
        "INSERT INTO account VALUES(?,?,'human',0,0,'fixture',0,0)",
        [owner, owner],
      );
    }
    await db.execute("INSERT INTO account VALUES('ai','AI','ai',0,0,NULL,0,0)");
    await db.execute("INSERT INTO ai_operator VALUES('ai','owner')");
    await db.execute("INSERT INTO ai_profile VALUES('profile','ai')");
    consent = OwnerAiDirectConsent(database: db, clock: clock);
    direct =
        (await consent.open(
              ownerId: 'owner',
              aiProfileId: 'profile',
              expectedRevision: 0,
            )).value['conversationId']
            as String;
    await db.execute(
      "INSERT INTO providers VALUES('owner','provider','P','https://example.invalid','opaque','masked',1,'[\"chat\"]')",
    );
    await db.execute(
      "INSERT INTO model_bindings VALUES('owner','profile','chat','provider','model')",
    );
    final persona = SqlitePersonaService.forOwner(
      ownerId: 'owner',
      actorAccountId: 'owner',
      database: db,
      cipher: cipher,
      clock: clock,
    );
    expect(
      (await persona.initialize(
        AiId.parse('profile'),
        initial: PersonaLayers(
          p0: {'name': 'Nora'},
          p1: {'style': 'warm'},
          p2: {'mood': 'calm'},
        ),
      )).isOk,
      isTrue,
    );
    calls = 0;
    admissions = 0;
    allowS1 = true;
    failure = null;
    entered = null;
    release = null;
    receivedTurns = [];
    chat = StatelessOwnerChat(
      db: db,
      cipher: cipher,
      clock: clock,
      chat:
          ({
            required ownerId,
            required ai,
            required turns,
            required requestId,
            required layer,
            required context,
            maxTokens,
            expectedProviderId,
            expectedModel,
          }) async {
            calls++;
            receivedTurns = turns;
            expect(layer, BudgetLayer.b2DeepChat);
            expect(expectedProviderId, 'provider');
            expect(expectedModel, 'model');
            entered?.complete();
            await release?.future;
            if (failure != null) return Err<ChatCompletion>(failure!);
            return const Ok(
              ChatCompletion(
                text: 'Synthetic answer',
                inputTokens: 2,
                outputTokens: 3,
                totalTokens: 5,
              ),
            );
          },
    );
  });
  tearDown(() async {
    await db.close();
    cipher.dispose();
    // Exact directory created by this test fixture, never a production path.
    await temp.delete(recursive: true);
  });

  test(
    'unstamped source and revoke/reopen before observer never dispatch',
    () async {
      final unstamped = await send(stamp: false);
      await compose().onAccepted(unstamped);
      final old = await send();
      await consent.revoke(
        ownerId: 'owner',
        aiProfileId: 'profile',
        expectedRevision: 1,
      );
      await consent.open(
        ownerId: 'owner',
        aiProfileId: 'profile',
        expectedRevision: 2,
      );
      await compose().onAccepted(old);
      expect(calls, 0);
      expect(await attempt(old), isNull);
      expect(await attempt(unstamped), isNull);
    },
  );

  test(
    'S1 curated first, unsupported simple silent and hardstop prevents reply',
    () async {
      final observer = compose();
      final hello = await send(text: '你好');
      await observer.onAccepted(hello);
      expect((await rows()).last.body, {
        'text': '你好呀',
        'source': 's1',
        'activityRefs': <String>[],
      });
      expect((await attempt(hello))!.status, OwnerReplyAttemptStatus.completed);
      final unsupported = await send(text: '短句');
      await observer.onAccepted(unsupported);
      expect(await attempt(unsupported), isNull);
      allowS1 = false;
      final stopped = await send(text: '谢谢');
      await observer.onAccepted(stopped);
      expect(
        (await attempt(stopped))!.failureCode,
        FailureCode.budgetExhausted,
      );
      expect(calls, 0);
      expect(admissions, 2);
      expect((await rows()).length, 4);
    },
  );
  test(
    'complex and unsure use only canonical source and pinned B2 facade',
    () async {
      for (final text in ['为什么这样？', '这是一段未匹配长句']) {
        final source = await send(text: text);
        final spoof = StoredMessage(
          conversationId: source.conversationId,
          seq: source.seq,
          messageId: source.messageId,
          senderId: source.senderId,
          clientMsgId: source.clientMsgId,
          kind: source.kind,
          body: const {'text': 'injected body'},
          sentAt: source.sentAt,
        );
        await compose().onAccepted(spoof);
        expect(receivedTurns.last.content, text);
        expect((await rows()).last.body['source'], 's2');
      }
      expect(calls, 2);
    },
  );
  for (final body in <Map<String, Object?>>[
    {'text': '为什么？', 'attachmentId': 'private'},
    {'text': '为什么？', 'quotedSource': 'thirdparty'},
    {
      'text': '为什么？',
      'mentionAccountIds': ['ai'],
    },
  ]) {
    test('extra body fields never reach model: ${body.keys}', () async {
      final source = await send(body: body);
      await compose().onAccepted(source);
      expect(calls, 0);
      expect(await attempt(source), isNull);
    });
  }
  test(
    'group, other owner, AI-origin, recalled and edited are rejected',
    () async {
      final observer = compose();
      await observer.onAccepted(await send(conversation: 'group'));
      await observer.onAccepted(await send(sender: 'other'));
      await observer.onAccepted(await send(sender: 'ai'));
      final recalled = await send();
      await messages.recall(
        conversationId: direct,
        messageId: recalled.messageId,
        senderId: 'owner',
      );
      await observer.onAccepted(recalled);
      final edited = await send();
      await messages.edit(
        conversationId: direct,
        messageId: edited.messageId,
        senderId: 'owner',
        body: {'text': 'different'},
      );
      await observer.onAccepted(edited);
      expect(calls, 0);
      expect(await db.query('SELECT * FROM owner_reply_attempts'), isEmpty);
    },
  );
  test('same direct ID also tagged group fails closed', () async {
    final source = await send();
    await db.execute(
      "INSERT INTO social_conversations VALUES(?,'owner','Ambiguous','all',0)",
      [direct],
    );
    await compose().onAccepted(source);
    expect(calls, 0);
    expect(await attempt(source), isNull);
  });
  test(
    'duplicate/concurrent observer instances and consent reopen never replay',
    () async {
      final source = await send();
      await Future.wait([
        compose().onAccepted(source),
        compose().onAccepted(source),
      ]);
      await consent.revoke(
        ownerId: 'owner',
        aiProfileId: 'profile',
        expectedRevision: 1,
      );
      await consent.open(
        ownerId: 'owner',
        aiProfileId: 'profile',
        expectedRevision: 2,
      );
      await compose().onAccepted(source);
      expect(calls, 1);
      expect((await rows()).length, 2);
      expect(
        (await attempt(source))!.claim.requestId.length,
        lessThanOrEqualTo(64),
      );
    },
  );
  test('failed provider retains inbound, safe status and no retry', () async {
    failure = const Failure(
      FailureCode.modelUnavailable,
      'private provider prose',
    );
    final source = await send();
    await compose().onAccepted(source);
    await compose().onAccepted(source);
    expect(calls, 1);
    expect((await rows()).length, 1);
    final status = await attempt(source);
    expect(status!.status, OwnerReplyAttemptStatus.failed);
    expect(status.failureCode, FailureCode.modelUnavailable);
    expect(
      (await db.query(
        'SELECT * FROM owner_reply_attempts',
      )).single.values.join(),
      isNot(contains('private provider prose')),
    );
  });
  test(
    'missing runtime and resolver failure fail safely without outbound',
    () async {
      final a = await send();
      await compose(runtime: false).onAccepted(a);
      final b = await send();
      await compose(
        binding: (_) async => err(FailureCode.notFound, 'binding absent'),
      ).onAccepted(b);
      expect(calls, 0);
      expect((await attempt(a))!.status, OwnerReplyAttemptStatus.failed);
      expect((await attempt(b))!.status, OwnerReplyAttemptStatus.failed);
    },
  );
  test(
    'S1 uses no main binding or runtime, but requires real admission',
    () async {
      await db.execute('DELETE FROM model_bindings');
      final source = await send(text: '你好');
      await compose(
        runtime: false,
        binding: (_) async => throw StateError('S1 must not resolve chat'),
      ).onAccepted(source);
      expect((await rows()).last.body['source'], 's1');
      expect(admissions, 1);
      expect(calls, 0);
    },
  );
  for (final config in [
    'disabled-provider',
    'wrong-capability',
    'changed-model',
  ]) {
    test('preflight configuration $config prevents outbound', () async {
      switch (config) {
        case 'disabled-provider':
          await db.execute('UPDATE providers SET enabled=0');
        case 'wrong-capability':
          await db.execute(
            "UPDATE providers SET capabilities='[\"chatFast\"]'",
          );
        case 'changed-model':
          await db.execute("UPDATE model_bindings SET model='other'");
      }
      final source = await send();
      await compose().onAccepted(source);
      expect(calls, 0);
      expect((await rows()).length, 1);
      expect(
        (await attempt(source))!.status,
        OwnerReplyAttemptStatus.discarded,
      );
    });
  }
  test('revoked consent and nontext do not claim', () async {
    final source = await send();
    await consent.revoke(
      ownerId: 'owner',
      aiProfileId: 'profile',
      expectedRevision: 1,
    );
    await compose().onAccepted(source);
    expect(await attempt(source), isNull);
    await consent.open(
      ownerId: 'owner',
      aiProfileId: 'profile',
      expectedRevision: 2,
    );
    final nontext = await send(kind: MessageKind.image, body: {'text': 'why?'});
    await compose().onAccepted(nontext);
    expect(await attempt(nontext), isNull);
    expect(calls, 0);
  });
  test(
    'existing pending claim is stranded, never automatically retried',
    () async {
      final source = await send();
      await db.transaction(
        (tx) => const OwnerReplyAttempts().claimInTx(
          tx,
          claim: OwnerReplyAttemptClaim(
            sourceMessageId: source.messageId,
            aiProfileId: 'profile',
            ownerAccountId: 'owner',
            aiAccountId: 'ai',
            conversationId: direct,
            grantRevision: 1,
            requestId: 'prior_unknown',
          ),
        ),
      );
      await compose().onAccepted(source);
      expect(calls, 0);
      expect((await attempt(source))!.status, OwnerReplyAttemptStatus.pending);
    },
  );
  test(
    'completed reply and permanent dedupe survive SQLite close/reopen',
    () async {
      final source = await send(text: '你好');
      await compose(runtime: false).onAccepted(source);
      final before = await rows();
      expect(before.length, 2);
      await db.close();
      db = await SqliteDatabase.open(
        '${temp.path}/host.sqlite',
        migrations: [],
      );
      messages = SqliteMessageStore(database: db, cipher: cipher, clock: clock);
      await compose(runtime: false).onAccepted(source);
      final after = await rows();
      expect(after.map((m) => m.messageId), before.map((m) => m.messageId));
      expect(
        (await attempt(source))!.status,
        OwnerReplyAttemptStatus.completed,
      );
      expect(admissions, 1);
    },
  );
  test('missing persona fails before runtime port', () async {
    // Use a new owned profile without persona rather than deleting immutable history.
    await db.execute(
      "INSERT INTO account VALUES('ai2','AI2','ai',0,0,NULL,0,0)",
    );
    await db.execute("INSERT INTO ai_operator VALUES('ai2','owner')");
    await db.execute("INSERT INTO ai_profile VALUES('profile2','ai2')");
    direct =
        (await consent.open(
              ownerId: 'owner',
              aiProfileId: 'profile2',
              expectedRevision: 0,
            )).value['conversationId']
            as String;
    await db.execute(
      "INSERT INTO model_bindings VALUES('owner','profile2','chat','provider','model')",
    );
    final source = await send();
    await compose(
      binding: (_) async => Ok(
        ResolvedBinding(
          ownerId: 'owner',
          aiProfileId: AiId.parse('profile2'),
          aiAccountId: AccountId.parse('ai2'),
          capability: ProviderCapability.chat,
          providerId: 'provider',
          model: 'model',
        ),
      ),
    ).onAccepted(source);
    expect(calls, 0);
    final status = await db.transaction(
      (tx) => const OwnerReplyAttempts().getForOwnerInTx(
        tx,
        ownerAccountId: 'owner',
        sourceMessageId: source.messageId,
        aiProfileId: 'profile2',
      ),
    );
    expect(status!.status, OwnerReplyAttemptStatus.failed);
  });
  test(
    'preflight revoke after binding resolver prevents transmission',
    () async {
      final source = await send();
      await compose(
        binding: (_) async {
          await consent.revoke(
            ownerId: 'owner',
            aiProfileId: 'profile',
            expectedRevision: 1,
          );
          return Ok(pinned);
        },
      ).onAccepted(source);
      expect(calls, 0);
      expect(
        (await attempt(source))!.status,
        OwnerReplyAttemptStatus.discarded,
      );
    },
  );
  test(
    'S1 admission can await outside Tx, revoke before final blocks append',
    () async {
      final source = await send(text: '你好');
      await compose(
        admit: (_) async {
          await consent.revoke(
            ownerId: 'owner',
            aiProfileId: 'profile',
            expectedRevision: 1,
          );
          return true;
        },
      ).onAccepted(source);
      expect(calls, 0);
      expect((await rows()).length, 1);
      expect(
        (await attempt(source))!.status,
        OwnerReplyAttemptStatus.discarded,
      );
    },
  );
  for (final change in [
    'revoke',
    'transfer',
    'edit',
    'recall',
    'binding',
    'disable',
  ]) {
    test(
      'provider barrier $change discards settled completion without reply',
      () async {
        entered = Completer<void>();
        release = Completer<void>();
        final source = await send();
        final pending = compose().onAccepted(source);
        await entered!.future;
        switch (change) {
          case 'revoke':
            await consent.revoke(
              ownerId: 'owner',
              aiProfileId: 'profile',
              expectedRevision: 1,
            );
          case 'transfer':
            await db.execute(
              "UPDATE ai_operator SET operator_id='other' WHERE ai_id='ai'",
            );
          case 'edit':
            await messages.edit(
              conversationId: direct,
              messageId: source.messageId,
              senderId: 'owner',
              body: {'text': 'changed'},
            );
          case 'recall':
            await messages.recall(
              conversationId: direct,
              messageId: source.messageId,
              senderId: 'owner',
            );
          case 'binding':
            await db.execute("UPDATE model_bindings SET model='changed'");
          case 'disable':
            await db.execute("UPDATE account SET disabled=1 WHERE id='ai'");
        }
        release!.complete();
        await pending;
        expect(calls, 1);
        expect((await rows()).length, 1);
        expect(
          (await attempt(source))!.status,
          OwnerReplyAttemptStatus.discarded,
        );
        await compose().onAccepted(source);
        expect(calls, 1);
      },
    );
  }
  test(
    'finish exception rolls back reply and seq but retains nonreplayable claim',
    () async {
      final source = await send();
      await compose(attempts: _FailCompleted()).onAccepted(source);
      expect((await rows()).length, 1);
      expect(await messages.headSeq(direct), 1);
      expect((await attempt(source))!.status, OwnerReplyAttemptStatus.failed);
      await compose().onAccepted(source);
      expect(calls, 1);
    },
  );
  test('append Err throws rollback and rolls back writes before Err', () async {
    final source = await send();
    await compose(store: _ErrAppend(db, cipher)).onAccepted(source);
    expect(await messages.headSeq(direct), 1);
    expect((await rows()).length, 1);
    expect((await attempt(source))!.status, OwnerReplyAttemptStatus.failed);
  });
}

class _FailCompleted extends OwnerReplyAttempts {
  @override
  Future<bool> finishInTx(
    tx, {
    required ownerAccountId,
    required sourceMessageId,
    required aiProfileId,
    required requestId,
    required status,
    String? replyId,
    FailureCode? failureCode,
  }) {
    if (status == OwnerReplyAttemptStatus.completed) {
      throw StateError('forced finish failure');
    }
    return super.finishInTx(
      tx,
      ownerAccountId: ownerAccountId,
      sourceMessageId: sourceMessageId,
      aiProfileId: aiProfileId,
      requestId: requestId,
      status: status,
      replyId: replyId,
      failureCode: failureCode,
    );
  }
}

class _ErrAppend extends SqliteMessageStore {
  _ErrAppend(this.db, ColumnCipher cipher)
    : super(database: db, cipher: cipher);
  final SqliteDatabase db;
  @override
  Future<Result<AppendResult>> appendInTransaction(
    tx, {
    required conversationId,
    required senderId,
    required clientMsgId,
    required kind,
    required body,
  }) async {
    await tx.execute(
      'UPDATE message_heads SET seq=999 WHERE conversation_id=?',
      [conversationId],
    );
    return err(FailureCode.internal, 'forced append Err');
  }
}
