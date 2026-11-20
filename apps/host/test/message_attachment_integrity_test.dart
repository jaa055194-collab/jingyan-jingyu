import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/messages/attachments.dart';
import 'package:jingyu_host/src/messages/attachments_module.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/messages_module.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

Future<({int freeBytes, int totalBytes})> _ampleDisk() async =>
    (freeBytes: 1 << 40, totalBytes: 1 << 40);

class _AllowMembership implements MembershipCheck {
  @override
  Future<bool> canPost(String accountId, String conversationId) async => true;

  @override
  Future<bool> canRead(String accountId, String conversationId) async => true;
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late FakeClock clock;
  late SqliteMessageStore store;
  late AttachmentService attachments;
  late Pipeline messages;
  late Pipeline attachmentsHttp;

  const owner = 'acct-owner';
  const other = 'acct-other';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('edit-integrity-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...messagesMigrations],
    );
    cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
    clock = FakeClock(DateTime.utc(2026, 11, 20, 12));
    store = SqliteMessageStore(database: db, cipher: cipher, clock: clock);
    attachments = AttachmentService(
      database: db,
      cipher: cipher,
      mediaDir: '${directory.path}/media',
      clock: clock,
      diskSpace: _ampleDisk,
    );
    final services = HostServices()
      ..provide<MembershipCheck>(_AllowMembership(), owner: 'test');
    final messagesModule = MessagesModule(
      store: store,
      attachments: attachments,
      clock: clock,
    );
    await messagesModule.configure(services);
    final messagesRouter = Router();
    messagesModule.mount(messagesRouter);
    messages = Pipeline(
      router: messagesRouter,
      authenticate: (request) async {
        final account = request.headers['test-account'];
        return account == null
            ? null
            : Principal(accountId: account, deviceId: 'test-device');
      },
    );

    final attachmentsModule = AttachmentsModule(attachments: attachments);
    await attachmentsModule.configure(services);
    final attachmentsRouter = Router();
    attachmentsModule.mount(attachmentsRouter);
    attachmentsHttp = Pipeline(
      router: attachmentsRouter,
      authenticate: (request) async {
        final account = request.headers['test-account'];
        return account == null
            ? null
            : Principal(accountId: account, deviceId: 'test-device');
      },
    );
  });

  tearDown(() async {
    cipher.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<String> upload({
    String account = owner,
    String conversationId = 'conv-1',
    String mime = 'text/plain',
    String text = 'secret extracted body',
  }) async {
    final bytes = utf8.encode(text);
    final init = await attachments.initiateUpload(
      ownerAccountId: account,
      mime: mime,
      size: bytes.length,
      kind: 'text',
      conversationId: conversationId,
    );
    expect(init.isOk, isTrue, reason: '${init.failureOrNull}');
    final uploadId = init.value['uploadId'] as String;
    expect(
      (await attachments.uploadChunk(
        ownerAccountId: account,
        uploadId: uploadId,
        index: 0,
        bytes: bytes,
      )).isOk,
      isTrue,
    );
    final done = await attachments.completeUpload(
      ownerAccountId: account,
      uploadId: uploadId,
    );
    expect(done.isOk, isTrue, reason: '${done.failureOrNull}');
    return done.value['id'] as String;
  }

  Future<HostResponse> send(
    String account,
    String conversationId,
    String clientMsgId,
    Map<String, Object?> body,
  ) => messages.handle(
    HostRequest(
      method: 'POST',
      path: Routes.messages.replaceFirst('{conversationId}', conversationId),
      headers: {'test-account': account},
      body: {'clientMsgId': clientMsgId, 'kind': 'text', 'body': body},
    ),
  );

  Future<HostResponse> edit(
    String account,
    String conversationId,
    String messageId,
    Object? newBody,
  ) => messages.handle(
    HostRequest(
      method: 'POST',
      path: Routes.messageEdit
          .replaceFirst('{conversationId}', conversationId)
          .replaceFirst('{messageId}', messageId),
      headers: {'test-account': account},
      body: {'body': newBody},
    ),
  );

  Future<String> textMessage(
    String account,
    String conversationId,
    String clientMsgId,
    String text,
  ) async {
    final sent = await send(account, conversationId, clientMsgId, {
      'text': text,
    });
    expect(sent.status, 200, reason: '${sent.json}');
    return ((sent.json! as Map)['message'] as Map)['messageId'] as String;
  }

  Future<Map<String, Object?>> storedBody(
    String conversationId,
    String messageId,
  ) async {
    // This branch predates MessageStore.read; decode the stored column directly
    // with the same AAD the store uses.
    final rows = await db.query(
      'SELECT body FROM messages WHERE conversation_id = ? AND message_id = ?',
      [conversationId, messageId],
    );
    expect(rows, hasLength(1), reason: 'stored message row');
    final decoded = cipher.decrypt(
      rows.single['body'] as String,
      aad: 'messages:body:$messageId',
    );
    expect(decoded.isOk, isTrue, reason: '${decoded.failureOrNull}');
    return (jsonDecode(decoded.value) as Map).cast<String, Object?>();
  }

  Future<int> editRows(String conversationId, String messageId) async =>
      (await db.query(
        'SELECT edit_id FROM message_edits '
        'WHERE conversation_id = ? AND message_id = ?',
        [conversationId, messageId],
      )).length;

  group('edit-time attachment integrity', () {
    test(
      'editing into a foreign attachment is 404 and changes nothing',
      () async {
        final foreignAttachment = await upload(account: owner);
        final messageId = await textMessage(other, 'conv-1', 'c1', 'original');

        final response = await edit(other, 'conv-1', messageId, {
          'text': 'forged',
          'attachmentId': foreignAttachment,
        });

        expect(response.status, 404, reason: '${response.json}');
        expect(await storedBody('conv-1', messageId), {'text': 'original'});
        expect(await editRows('conv-1', messageId), 0);
      },
    );

    test(
      'editing into an attachment from another conversation is 404',
      () async {
        final elsewhere = await upload(conversationId: 'conv-2');
        final messageId = await textMessage(owner, 'conv-1', 'c1', 'original');

        final response = await edit(owner, 'conv-1', messageId, {
          'attachmentId': elsewhere,
        });

        expect(response.status, 404, reason: '${response.json}');
        expect(await storedBody('conv-1', messageId), {'text': 'original'});
        expect(await editRows('conv-1', messageId), 0);
      },
    );

    test('a non-String attachmentId is 400 and changes nothing', () async {
      final messageId = await textMessage(owner, 'conv-1', 'c1', 'original');

      final response = await edit(owner, 'conv-1', messageId, {
        'attachmentId': 42,
      });

      expect(response.status, 400, reason: '${response.json}');
      expect(await storedBody('conv-1', messageId), {'text': 'original'});
      expect(await editRows('conv-1', messageId), 0);
    });

    test(
      'editing into the editor own same-conversation attachment succeeds',
      () async {
        final mine = await upload();
        final messageId = await textMessage(owner, 'conv-1', 'c1', 'original');

        final response = await edit(owner, 'conv-1', messageId, {
          'attachmentId': mine,
        });

        expect(response.status, 200, reason: '${response.json}');
        expect((response.json! as Map)['body'], {'attachmentId': mine});
        expect(await storedBody('conv-1', messageId), {'attachmentId': mine});
        expect(await editRows('conv-1', messageId), 1);
      },
    );

    test(
      'an edit that removes the attachment reference still succeeds',
      () async {
        final mine = await upload();
        final messageId = await textMessage(owner, 'conv-1', 'c1', 'original');
        final withAttachment = await edit(owner, 'conv-1', messageId, {
          'attachmentId': mine,
        });
        expect(withAttachment.status, 200, reason: '${withAttachment.json}');

        final removed = await edit(owner, 'conv-1', messageId, {
          'text': 'plain',
        });

        expect(removed.status, 200, reason: '${removed.json}');
        expect(await storedBody('conv-1', messageId), {'text': 'plain'});
        expect(await editRows('conv-1', messageId), 2);
      },
    );
  });

  group('extracted text is owner-only', () {
    Future<HostResponse> get(String account, String attachmentId) =>
        attachmentsHttp.handle(
          HostRequest(
            method: 'GET',
            path: Routes.attachment.replaceFirst(
              '{attachmentId}',
              attachmentId,
            ),
            headers: {'test-account': account},
          ),
        );

    test(
      'owner gets text while a conversation member gets metadata only',
      () async {
        final id = await upload(text: 'private extracted note');

        final ownerView = await get(owner, id);
        expect(ownerView.status, 200, reason: '${ownerView.json}');
        expect(
          (ownerView.json! as Map)['extractedText'],
          'private extracted note',
        );

        final memberView = await get(other, id);
        expect(memberView.status, 200, reason: '${memberView.json}');
        final member = memberView.json! as Map;
        expect(member.containsKey('extractedText'), isFalse);
        expect(member['id'], id);
        expect(member['mime'], 'text/plain');
        expect(member['size'], utf8.encode('private extracted note').length);
        expect(member['extractionStatus'], 'extracted');
        expect(
          memberView.encodeBody(),
          isNot(contains('private extracted note')),
        );
      },
    );

    test('member metadata survives a corrupt stored text column', () async {
      final id = await upload(text: 'body that will be corrupted');
      await db.execute(
        'UPDATE attachments SET extracted_text = ? WHERE id = ?',
        ['not-a-valid-cipher-column', id],
      );

      final memberView = await get(other, id);
      expect(memberView.status, 200, reason: '${memberView.json}');
      expect((memberView.json! as Map).containsKey('extractedText'), isFalse);

      // The owner path still decrypts, so a corrupt column remains an error
      // rather than silently returning wrong content.
      final ownerView = await get(owner, id);
      expect(ownerView.status, 500, reason: '${ownerView.json}');
    });
  });
}
