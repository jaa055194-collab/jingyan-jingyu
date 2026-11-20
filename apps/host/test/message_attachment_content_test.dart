import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/messages/attachments.dart';
import 'package:jingyu_host/src/messages/message_store.dart';
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

/// Mutable policy so one pipeline can model member, late-join and stranger.
class _PolicyMembership implements HistoryMembershipCheck {
  bool readable = true;
  int? floor = 1;

  @override
  Future<bool> canPost(String accountId, String conversationId) async =>
      readable;

  @override
  Future<bool> canRead(String accountId, String conversationId) async =>
      readable;

  @override
  Future<int?> firstVisibleSeq(String accountId, String conversationId) async =>
      readable ? floor : null;
}

const _pngBytes = <int>[137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4];

void main() {
  group('MessageStore.read contract', () {
    test(
      'memory store returns an existing message and notFound otherwise',
      () async {
        final store = InMemoryMessageStore();
        final appended = await store.append(
          conversationId: 'c1',
          senderId: 'u1',
          clientMsgId: 'm1',
          kind: MessageKind.image,
          body: {'attachmentId': 'a1'},
        );
        final id = appended.value.message.messageId;

        final found = await store.read(conversationId: 'c1', messageId: id);
        expect(found.isOk, isTrue, reason: '${found.failureOrNull}');
        expect(found.value.messageId, id);
        expect(found.value.body['attachmentId'], 'a1');

        final missing = await store.read(
          conversationId: 'c1',
          messageId: 'nope',
        );
        expect(missing.failureOrNull?.code, FailureCode.notFound);
        final otherConversation = await store.read(
          conversationId: 'c2',
          messageId: id,
        );
        expect(otherConversation.failureOrNull?.code, FailureCode.notFound);
      },
    );

    test(
      'SQLite store returns an existing message and notFound otherwise',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'message-read-',
        );
        final db = await SqliteDatabase.open(
          '${directory.path}/host.sqlite',
          migrations: [...allMigrations, ...messagesMigrations],
        );
        final cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
        addTearDown(() async {
          cipher.dispose();
          await db.close();
          await directory.delete(recursive: true);
        });
        final store = SqliteMessageStore(database: db, cipher: cipher);
        final appended = await store.append(
          conversationId: 'c1',
          senderId: 'u1',
          clientMsgId: 'm1',
          kind: MessageKind.image,
          body: {'attachmentId': 'a1'},
        );
        final id = appended.value.message.messageId;

        final found = await store.read(conversationId: 'c1', messageId: id);
        expect(found.isOk, isTrue, reason: '${found.failureOrNull}');
        expect(found.value.messageId, id);
        expect(found.value.body['attachmentId'], 'a1');

        final missing = await store.read(
          conversationId: 'c1',
          messageId: 'nope',
        );
        expect(missing.failureOrNull?.code, FailureCode.notFound);
        final otherConversation = await store.read(
          conversationId: 'c2',
          messageId: id,
        );
        expect(otherConversation.failureOrNull?.code, FailureCode.notFound);
      },
    );
  });

  group('AttachmentService.readImageContent', () {
    late Directory directory;
    late SqliteDatabase db;
    late AesGcmColumnCipher cipher;
    late AttachmentService attachments;
    late String mediaDir;
    const owner = 'acct-owner';

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('image-content-');
      db = await SqliteDatabase.open(
        '${directory.path}/host.sqlite',
        migrations: [...allMigrations, ...messagesMigrations],
      );
      cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
      mediaDir = '${directory.path}/media';
      attachments = AttachmentService(
        database: db,
        cipher: cipher,
        mediaDir: mediaDir,
        clock: FakeClock(DateTime.utc(2026, 11, 20)),
        diskSpace: _ampleDisk,
      );
    });

    tearDown(() async {
      cipher.dispose();
      await db.close();
      await directory.delete(recursive: true);
    });

    Future<String> upload({
      String mime = 'image/png',
      String kind = 'image',
      String conversationId = 'conv-1',
      String account = owner,
      List<int> bytes = _pngBytes,
    }) async {
      final init = await attachments.initiateUpload(
        ownerAccountId: account,
        mime: mime,
        size: bytes.length,
        kind: kind,
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

    test(
      'returns exact bytes for a matching conversation and sender',
      () async {
        final id = await upload();
        final result = await attachments.readImageContent(
          attachmentId: id,
          conversationId: 'conv-1',
          senderId: owner,
        );
        expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
        expect(result.value.mime, 'image/png');
        expect(result.value.size, _pngBytes.length);
        expect(result.value.sha256, sha256.convert(_pngBytes).toString());
        expect(result.value.bytes, _pngBytes);
      },
    );

    test(
      'rejects unknown, foreign-conversation and foreign-owner references',
      () async {
        final id = await upload();
        final unknown = await attachments.readImageContent(
          attachmentId: 'missing',
          conversationId: 'conv-1',
          senderId: owner,
        );
        expect(unknown.failureOrNull?.code, FailureCode.notFound);
        final wrongConversation = await attachments.readImageContent(
          attachmentId: id,
          conversationId: 'conv-2',
          senderId: owner,
        );
        expect(wrongConversation.failureOrNull?.code, FailureCode.notFound);
        final wrongSender = await attachments.readImageContent(
          attachmentId: id,
          conversationId: 'conv-1',
          senderId: 'acct-other',
        );
        expect(wrongSender.failureOrNull?.code, FailureCode.notFound);
      },
    );

    test('rejects non-raster MIME types', () async {
      for (final mime in ['image/svg+xml', 'text/plain', 'application/pdf']) {
        final id = await upload(mime: mime, kind: 'file');
        final result = await attachments.readImageContent(
          attachmentId: id,
          conversationId: 'conv-1',
          senderId: owner,
        );
        expect(result.failureOrNull?.code, FailureCode.notFound, reason: mime);
      }
    });

    test('enforces the byte cap before reading the blob', () async {
      final id = await upload();
      final tooSmall = await attachments.readImageContent(
        attachmentId: id,
        conversationId: 'conv-1',
        senderId: owner,
        maxBytes: _pngBytes.length - 1,
      );
      expect(tooSmall.failureOrNull?.code, FailureCode.notFound);
      final exact = await attachments.readImageContent(
        attachmentId: id,
        conversationId: 'conv-1',
        senderId: owner,
        maxBytes: _pngBytes.length,
      );
      expect(exact.isOk, isTrue);
    });

    test(
      'rejects a missing blob and a length mismatch without throwing',
      () async {
        final missingId = await upload();
        await File('$mediaDir/$owner/$missingId').delete();
        final missing = await attachments.readImageContent(
          attachmentId: missingId,
          conversationId: 'conv-1',
          senderId: owner,
        );
        expect(missing.failureOrNull?.code, FailureCode.notFound);

        final shortId = await upload();
        final file = File('$mediaDir/$owner/$shortId');
        final original = await file.readAsBytes();
        await file.writeAsBytes(original.sublist(0, 3), flush: true);
        final mismatch = await attachments.readImageContent(
          attachmentId: shortId,
          conversationId: 'conv-1',
          senderId: owner,
        );
        expect(mismatch.failureOrNull?.code, FailureCode.notFound);
      },
    );
  });

  group('GET message image content route', () {
    late Directory directory;
    late SqliteDatabase db;
    late AesGcmColumnCipher cipher;
    late FakeClock clock;
    late SqliteMessageStore store;
    late AttachmentService attachments;
    late _PolicyMembership membership;
    late Pipeline pipeline;
    late String mediaDir;

    const owner = 'acct-owner';
    const other = 'acct-other';

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('image-route-');
      db = await SqliteDatabase.open(
        '${directory.path}/host.sqlite',
        migrations: [...allMigrations, ...messagesMigrations],
      );
      cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
      clock = FakeClock(DateTime.utc(2026, 11, 20, 10));
      mediaDir = '${directory.path}/media';
      store = SqliteMessageStore(database: db, cipher: cipher, clock: clock);
      attachments = AttachmentService(
        database: db,
        cipher: cipher,
        mediaDir: mediaDir,
        clock: clock,
        diskSpace: _ampleDisk,
      );
      membership = _PolicyMembership();
      final services = HostServices()
        ..provide<MembershipCheck>(membership, owner: 'test')
        ..provide<HistoryMembershipCheck>(membership, owner: 'test');
      final module = MessagesModule(
        store: store,
        attachments: attachments,
        clock: clock,
      );
      await module.configure(services);
      final router = Router();
      module.mount(router);
      pipeline = Pipeline(
        router: router,
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
      String mime = 'image/png',
      String kind = 'image',
      List<int> bytes = _pngBytes,
    }) async {
      final init = await attachments.initiateUpload(
        ownerAccountId: account,
        mime: mime,
        size: bytes.length,
        kind: kind,
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
      String kind,
      Map<String, Object?> body,
    ) => pipeline.handle(
      HostRequest(
        method: 'POST',
        path: Routes.messages.replaceFirst('{conversationId}', conversationId),
        headers: {'test-account': account},
        body: {'clientMsgId': clientMsgId, 'kind': kind, 'body': body},
      ),
    );

    Future<HostResponse> read(
      String? account,
      String conversationId,
      String messageId,
    ) => pipeline.handle(
      HostRequest(
        method: 'GET',
        path: Routes.messageAttachment
            .replaceFirst('{conversationId}', conversationId)
            .replaceFirst('{messageId}', messageId),
        headers: {'test-account': ?account},
      ),
    );

    Future<String> sendImage(
      String account,
      String conversationId,
      String clientMsgId, {
      String? attachmentId,
    }) async {
      final id =
          attachmentId ??
          await upload(account: account, conversationId: conversationId);
      final sent = await send(account, conversationId, clientMsgId, 'image', {
        'attachmentId': id,
        'name': 'pic.png',
      });
      expect(sent.status, 200, reason: '${sent.json}');
      return ((sent.json! as Map)['message'] as Map)['messageId'] as String;
    }

    test('member gets bounded base64 JSON with hardened headers', () async {
      final messageId = await sendImage(owner, 'conv-1', 'c1');

      final response = await read(other, 'conv-1', messageId);
      expect(response.status, 200, reason: '${response.json}');
      final json = response.json! as Map;
      expect(json.keys.toSet(), {'mime', 'size', 'sha256', 'dataBase64'});
      expect(json['mime'], 'image/png');
      expect(json['size'], _pngBytes.length);
      expect(json['sha256'], sha256.convert(_pngBytes).toString());
      expect(base64Decode(json['dataBase64'] as String), _pngBytes);
      expect(response.headers['Cache-Control'], 'no-store');
      expect(response.headers['X-Content-Type-Options'], 'nosniff');
      final encoded = response.encodeBody();
      expect(encoded, isNot(contains('ownerAccountId')));
      expect(encoded, isNot(contains(owner)));
      expect(encoded, isNot(contains('extractedText')));
      expect(encoded, isNot(contains(mediaDir)));
    });

    test('anonymous and non-members get uniform 404/401', () async {
      final messageId = await sendImage(owner, 'conv-1', 'c1');
      final anonymous = await read(null, 'conv-1', messageId);
      expect(anonymous.status, 401);

      membership.readable = false;
      final stranger = await read(other, 'conv-1', messageId);
      expect(stranger.status, 404);
      expect(stranger.json, {'error': 'not_found'});
    });

    test('joined-late member cannot read a pre-join message', () async {
      final messageId = await sendImage(owner, 'conv-1', 'c1');
      membership.floor = 2;
      final lateJoin = await read(other, 'conv-1', messageId);
      expect(lateJoin.status, 404);
    });

    test(
      'recalled, text, unknown and cross-conversation messages are 404',
      () async {
        final recalledId = await sendImage(owner, 'conv-1', 'c1');
        final recalled = await pipeline.handle(
          HostRequest(
            method: 'POST',
            path: Routes.messageRecall
                .replaceFirst('{conversationId}', 'conv-1')
                .replaceFirst('{messageId}', recalledId),
            headers: {'test-account': owner},
          ),
        );
        expect(recalled.status, 200, reason: '${recalled.json}');
        expect((await read(other, 'conv-1', recalledId)).status, 404);

        final text = await send(owner, 'conv-1', 'c2', 'text', {'text': 'hi'});
        final textId =
            ((text.json! as Map)['message'] as Map)['messageId'] as String;
        expect((await read(other, 'conv-1', textId)).status, 404);

        expect((await read(other, 'conv-1', 'missing')).status, 404);
        expect((await read(other, 'conv-2', recalledId)).status, 404);
      },
    );

    test('forged edit referencing another owner attachment is 404', () async {
      final ownerAttachment = await upload(account: owner);
      final sent = await send(other, 'conv-1', 'c1', 'text', {'text': 'hi'});
      final messageId =
          ((sent.json! as Map)['message'] as Map)['messageId'] as String;
      final edited = await pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.messageEdit
              .replaceFirst('{conversationId}', 'conv-1')
              .replaceFirst('{messageId}', messageId),
          headers: {'test-account': other},
          body: {
            'body': {'attachmentId': ownerAttachment},
          },
        ),
      );
      // The edit itself is now refused: an editor may not introduce a reference
      // to an attachment it could not have sent, so the forged reference never
      // reaches storage. This assertion predates that rule and used to expect
      // 200 here; the content read below is 404 either way.
      expect(edited.status, 404, reason: '${edited.json}');
      expect(edited.json, {'error': 'not_found'});
      expect((await read(other, 'conv-1', messageId)).status, 404);
    });

    test('attachment from another conversation is 404', () async {
      final foreign = await upload(conversationId: 'conv-2');
      final sent = await send(owner, 'conv-1', 'c1', 'text', {'text': 'hi'});
      final messageId =
          ((sent.json! as Map)['message'] as Map)['messageId'] as String;
      await pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.messageEdit
              .replaceFirst('{conversationId}', 'conv-1')
              .replaceFirst('{messageId}', messageId),
          headers: {'test-account': owner},
          body: {
            'body': {'attachmentId': foreign},
          },
        ),
      );
      expect((await read(owner, 'conv-1', messageId)).status, 404);
    });

    test('non-image MIME, deleted blob and oversize rows are 404', () async {
      final nonImage = await upload(mime: 'text/plain', kind: 'file');
      final nonImageMessage = await sendImage(
        owner,
        'conv-1',
        'c1',
        attachmentId: nonImage,
      );
      expect((await read(other, 'conv-1', nonImageMessage)).status, 404);

      final deletedMessage = await sendImage(owner, 'conv-1', 'c2');
      final row = (await db.query(
        'SELECT rel_path FROM attachments ORDER BY rowid DESC LIMIT 1',
      )).single;
      await File('$mediaDir/${row['rel_path']}').delete();
      expect((await read(other, 'conv-1', deletedMessage)).status, 404);

      // Declared size above the 8 MiB transport bound: no blob read required.
      final oversize = await upload(bytes: [1, 2, 3, 4]);
      await db.execute('UPDATE attachments SET size = ? WHERE id = ?', [
        8 * 1024 * 1024 + 1,
        oversize,
      ]);
      final oversizeMessage = await sendImage(
        owner,
        'conv-1',
        'c3',
        attachmentId: oversize,
      );
      expect((await read(other, 'conv-1', oversizeMessage)).status, 404);
    });

    test('malformed ids are 400 and a missing attachmentId is 404', () async {
      // Single-segment invalid ids reach the handler; multi-segment traversal
      // never matches the route, so it is already a uniform 404.
      expect((await read(other, '..', 'x')).status, 400);
      expect((await read(other, 'conv-1', 'x' * 65)).status, 400);
      final sent = await send(owner, 'conv-1', 'c1', 'image', {'name': 'x'});
      final messageId =
          ((sent.json! as Map)['message'] as Map)['messageId'] as String;
      expect((await read(other, 'conv-1', messageId)).status, 404);
    });
  });
}
