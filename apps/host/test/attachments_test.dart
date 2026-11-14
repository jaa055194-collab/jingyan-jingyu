import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/messages/attachment_extraction.dart';
import 'package:jingyu_host/src/messages/attachments.dart';
import 'package:jingyu_host/src/messages/attachments_module.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/messages_module.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

Future<({int freeBytes, int totalBytes})> ampleDisk() async =>
    (freeBytes: 1 << 40, totalBytes: 1 << 40);

class _FakeMembership implements MembershipCheck {
  @override
  Future<bool> canPost(String accountId, String conversationId) async =>
      conversationId == 'conv-1';

  @override
  Future<bool> canRead(String accountId, String conversationId) async =>
      accountId == 'acct-member' && conversationId == 'conv-1';
}

class _PostMembership implements MembershipCheck {
  @override
  Future<bool> canPost(String accountId, String conversationId) async => true;

  @override
  Future<bool> canRead(String accountId, String conversationId) async => false;
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late FakeClock clock;
  late String mediaDir;
  late AttachmentService service;

  const owner = 'acct-owner';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('attachments-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...messagesMigrations],
    );
    cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
    clock = FakeClock(DateTime.utc(2026, 11, 14, 9));
    mediaDir = '${directory.path}/media';
    service = AttachmentService(
      database: db,
      cipher: cipher,
      mediaDir: mediaDir,
      clock: clock,
      diskSpace: ampleDisk,
    );
  });

  tearDown(() async {
    cipher.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<String> uploadAll(
    AttachmentService service, {
    required String mime,
    required String kind,
    required List<int> bytes,
    String? conversationId,
    int chunkSize = 5,
  }) async {
    final init = await service.initiateUpload(
      ownerAccountId: owner,
      mime: mime,
      size: bytes.length,
      kind: kind,
      conversationId: conversationId,
    );
    expect(init.isOk, isTrue, reason: 'initiate should succeed');
    final uploadId = init.value['uploadId'] as String;
    var index = 0;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = offset + chunkSize > bytes.length
          ? bytes.length
          : offset + chunkSize;
      final chunk = await service.uploadChunk(
        ownerAccountId: owner,
        uploadId: uploadId,
        index: index,
        bytes: bytes.sublist(offset, end),
      );
      expect(chunk.isOk, isTrue, reason: 'chunk $index should succeed');
      index++;
    }
    final done = await service.completeUpload(
      ownerAccountId: owner,
      uploadId: uploadId,
    );
    expect(done.isOk, isTrue, reason: 'complete should succeed');
    return done.value['id'] as String;
  }

  group('AttachmentTextExtractor', () {
    test('extracts plain text and tolerates malformed utf8', () {
      final plain = AttachmentTextExtractor.extract(
        mime: 'text/plain; charset=utf-8',
        bytes: utf8.encode('hello'),
      );
      expect(plain.status, ExtractStatus.extracted);
      expect(plain.text, 'hello');

      final malformed = AttachmentTextExtractor.extract(
        mime: 'text/plain',
        bytes: [0xff, 0x68, 0x69],
      );
      expect(malformed.status, ExtractStatus.extracted);
      expect(malformed.text, contains('hi'));
    });

    test('strips html tags and decodes entities', () {
      final result = AttachmentTextExtractor.extract(
        mime: 'text/html',
        bytes: utf8.encode(
          '<html><body><p>Hello&nbsp;<b>World</b> &amp; &#65;</p>'
          '<script>x()</script></body></html>',
        ),
      );
      expect(result.status, ExtractStatus.extracted);
      expect(result.text, contains('Hello'));
      expect(result.text, contains('World'));
      expect(result.text, contains('&'));
      expect(result.text, contains('A'));
      expect(result.text, isNot(contains('</')));
      expect(result.text, isNot(contains('x()')));
    });

    test('passes json/xml through and marks binaries unsupported', () {
      final json = AttachmentTextExtractor.extract(
        mime: 'application/json',
        bytes: utf8.encode('{"a":1}'),
      );
      expect(json.status, ExtractStatus.extracted);
      expect(json.text, '{"a":1}');

      final xml = AttachmentTextExtractor.extract(
        mime: 'text/xml',
        bytes: utf8.encode('<r>x</r>'),
      );
      expect(xml.status, ExtractStatus.extracted);
      expect(xml.text, '<r>x</r>');

      for (final mime in [
        'application/pdf',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'image/png',
        'audio/mpeg',
        'video/mp4',
        'application/octet-stream',
      ]) {
        expect(
          AttachmentTextExtractor.extract(mime: mime, bytes: [1, 2, 3]).status,
          ExtractStatus.unsupported,
          reason: mime,
        );
      }
    });

    test('reports empty for blank text', () {
      expect(
        AttachmentTextExtractor.extract(
          mime: 'text/plain',
          bytes: utf8.encode('   \n\t '),
        ).status,
        ExtractStatus.empty,
      );
      expect(
        AttachmentTextExtractor.extract(
          mime: 'text/plain',
          bytes: const <int>[],
        ).status,
        ExtractStatus.empty,
      );
    });

    test('caps extracted text at one MiB', () {
      final big = 'a' * (2 * 1024 * 1024);
      final result = AttachmentTextExtractor.extract(
        mime: 'text/plain',
        bytes: utf8.encode(big),
      );
      expect(result.status, ExtractStatus.extracted);
      expect(result.text!.length, AttachmentTextExtractor.maxTextLength);
    });
  });

  group('AttachmentService', () {
    test('initiate -> sequential chunks -> complete reconstitutes bytes and sha256',
        () async {
      final bytes = utf8.encode('hello attachment 你好 world');
      final init = await service.initiateUpload(
        ownerAccountId: owner,
        mime: 'text/plain',
        size: bytes.length,
        kind: 'text',
      );
      expect(init.isOk, isTrue);
      expect(init.value['chunkSize'], 512 * 1024);
      final uploadId = init.value['uploadId'] as String;

      final chunks = [
        bytes.sublist(0, 5),
        bytes.sublist(5, 10),
        bytes.sublist(10),
      ];
      for (var index = 0; index < chunks.length; index++) {
        final result = await service.uploadChunk(
          ownerAccountId: owner,
          uploadId: uploadId,
          index: index,
          bytes: chunks[index],
        );
        expect(result.isOk, isTrue);
        expect(result.value['nextChunk'], index + 1);
      }

      final done = await service.completeUpload(
        ownerAccountId: owner,
        uploadId: uploadId,
      );
      expect(done.isOk, isTrue);
      final attachmentId = done.value['id'] as String;
      expect(done.value['size'], bytes.length);
      expect(done.value['sha256'], sha256.convert(bytes).toString());
      expect(done.value['extractionStatus'], 'extracted');

      final file = File('$mediaDir/$owner/$attachmentId');
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), bytes);

      final row = (await db.query(
        'SELECT rel_path, extracted_text, extraction_status FROM attachments '
        'WHERE id = ?',
        [attachmentId],
      )).single;
      expect(row['rel_path'], '$owner/$attachmentId');
      expect(row['extraction_status'], 'extracted');
      expect(row['extracted_text'], isNotNull);
      expect(row['extracted_text'], isNot(utf8.decode(bytes)));

      final got = await service.getAttachment(
        accountId: owner,
        attachmentId: attachmentId,
      );
      expect(got.isOk, isTrue);
      expect(got.value['extractedText'], utf8.decode(bytes));
      expect(got.value['size'], bytes.length);
    });

    test('resume: re-sending the latest chunk is a no-op and gaps are rejected',
        () async {
      final bytes = utf8.encode('0123456789');
      final init = await service.initiateUpload(
        ownerAccountId: owner,
        mime: 'application/octet-stream',
        size: bytes.length,
        kind: 'file',
      );
      final uploadId = init.value['uploadId'] as String;

      final first = await service.uploadChunk(
        ownerAccountId: owner,
        uploadId: uploadId,
        index: 0,
        bytes: bytes.sublist(0, 4),
      );
      expect(first.value['received'], 4);
      expect(first.value['nextChunk'], 1);

      final resend = await service.uploadChunk(
        ownerAccountId: owner,
        uploadId: uploadId,
        index: 0,
        bytes: bytes.sublist(0, 4),
      );
      expect(resend.isOk, isTrue);
      expect(resend.value['received'], 4);
      expect(resend.value['nextChunk'], 1);
      final part = File('$mediaDir/$owner/$uploadId.part');
      expect(await part.length(), 4);

      final gap = await service.uploadChunk(
        ownerAccountId: owner,
        uploadId: uploadId,
        index: 2,
        bytes: bytes.sublist(4),
      );
      expect(gap.failureOrNull?.code, FailureCode.invalidArgument);

      final wrongSize = await service.uploadChunk(
        ownerAccountId: owner,
        uploadId: uploadId,
        index: 0,
        bytes: bytes.sublist(0, 3),
      );
      expect(wrongSize.failureOrNull?.code, FailureCode.invalidArgument);

      final second = await service.uploadChunk(
        ownerAccountId: owner,
        uploadId: uploadId,
        index: 1,
        bytes: bytes.sublist(4),
      );
      expect(second.value['received'], 10);
      final done = await service.completeUpload(
        ownerAccountId: owner,
        uploadId: uploadId,
      );
      expect(done.value['sha256'], sha256.convert(bytes).toString());
    });

    test('declared-size and sha256 mismatches are rejected without inserting',
        () async {
      final bytes = utf8.encode('abcdef');

      final init1 = await service.initiateUpload(
        ownerAccountId: owner,
        mime: 'text/plain',
        size: bytes.length + 3,
        kind: 'text',
      );
      final id1 = init1.value['uploadId'] as String;
      await service.uploadChunk(
        ownerAccountId: owner,
        uploadId: id1,
        index: 0,
        bytes: bytes,
      );
      final sizeMismatch = await service.completeUpload(
        ownerAccountId: owner,
        uploadId: id1,
      );
      expect(sizeMismatch.failureOrNull?.code, FailureCode.invalidArgument);
      expect(await db.query('SELECT id FROM attachments'), isEmpty);

      final init2 = await service.initiateUpload(
        ownerAccountId: owner,
        mime: 'text/plain',
        size: bytes.length,
        kind: 'text',
      );
      final id2 = init2.value['uploadId'] as String;
      await service.uploadChunk(
        ownerAccountId: owner,
        uploadId: id2,
        index: 0,
        bytes: bytes,
      );
      final shaMismatch = await service.completeUpload(
        ownerAccountId: owner,
        uploadId: id2,
        expectedSha256: 'deadbeef',
      );
      expect(shaMismatch.failureOrNull?.code, FailureCode.invalidArgument);
      expect(await db.query('SELECT id FROM attachments'), isEmpty);
    });

    test('text is readable by owner and by a conversation reader, hidden from others',
        () async {
      final bytes = utf8.encode('secret note');
      final attachmentId = await uploadAll(
        service,
        mime: 'text/plain',
        kind: 'text',
        bytes: bytes,
        conversationId: 'conv-1',
      );

      final ownerView = await service.getAttachment(
        accountId: owner,
        attachmentId: attachmentId,
      );
      expect(ownerView.value['extractedText'], 'secret note');

      final memberView = await service.getAttachment(
        accountId: 'acct-member',
        attachmentId: attachmentId,
        canReadConversation: (account, conversation) async =>
            account == 'acct-member' && conversation == 'conv-1',
      );
      expect(memberView.isOk, isTrue);
      expect(memberView.value['extractedText'], 'secret note');

      final stranger = await service.getAttachment(
        accountId: 'acct-stranger',
        attachmentId: attachmentId,
        canReadConversation: (account, conversation) async => false,
      );
      expect(stranger.failureOrNull?.code, FailureCode.notFound);

      final noCheck = await service.getAttachment(
        accountId: 'acct-stranger',
        attachmentId: attachmentId,
      );
      expect(noCheck.failureOrNull?.code, FailureCode.notFound);
    });

    test('binary attachments are unsupported and store no extracted text',
        () async {
      final attachmentId = await uploadAll(
        service,
        mime: 'image/png',
        kind: 'image',
        bytes: [0, 1, 2, 3, 255],
      );
      final row = (await db.query(
        'SELECT extracted_text, extraction_status FROM attachments WHERE id = ?',
        [attachmentId],
      )).single;
      expect(row['extraction_status'], 'unsupported');
      expect(row['extracted_text'], isNull);

      final got = await service.getAttachment(
        accountId: owner,
        attachmentId: attachmentId,
      );
      expect(got.value['extractionStatus'], 'unsupported');
      expect(got.value.containsKey('extractedText'), isFalse);
    });

    test('delete removes row and blob for owner, hides from others', () async {
      final attachmentId = await uploadAll(
        service,
        mime: 'text/plain',
        kind: 'text',
        bytes: utf8.encode('bye'),
      );
      final file = File('$mediaDir/$owner/$attachmentId');
      expect(await file.exists(), isTrue);

      final denied = await service.deleteAttachment(
        ownerAccountId: 'acct-stranger',
        attachmentId: attachmentId,
      );
      expect(denied.failureOrNull?.code, FailureCode.notFound);
      expect(await file.exists(), isTrue);

      final removed = await service.deleteAttachment(
        ownerAccountId: owner,
        attachmentId: attachmentId,
      );
      expect(removed.isOk, isTrue);
      expect(await file.exists(), isFalse);
      expect(
        await db.query('SELECT id FROM attachments WHERE id = ?', [attachmentId]),
        isEmpty,
      );

      final again = await service.deleteAttachment(
        ownerAccountId: owner,
        attachmentId: attachmentId,
      );
      expect(again.failureOrNull?.code, FailureCode.notFound);
    });

    test('quota rejection returns budgetExhausted', () async {
      final tiny = AttachmentService(
        database: db,
        cipher: cipher,
        mediaDir: mediaDir,
        clock: clock,
        diskSpace: ampleDisk,
        quotaBytes: 100,
      );
      await db.execute(
        'INSERT INTO attachments('
        'id, owner_account_id, conversation_id, kind, mime, size, sha256, '
        'rel_path, width, height, duration_ms, extracted_text, '
        'extraction_status, created_at'
        ') VALUES (?, ?, NULL, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, ?, ?)',
        [
          'existing',
          owner,
          'file',
          'application/octet-stream',
          100,
          'x',
          '$owner/existing',
          'unsupported',
          clock.now().toUtc().toIso8601String(),
        ],
      );
      final rejected = await tiny.initiateUpload(
        ownerAccountId: owner,
        mime: 'application/octet-stream',
        size: 60 * 1024 * 1024,
        kind: 'file',
      );
      expect(rejected.failureOrNull?.code, FailureCode.budgetExhausted);
      expect(await db.query('SELECT id FROM attachment_uploads'), isEmpty);
    });

    test('disk probe below ten percent stops uploads', () async {
      final lowDisk = AttachmentService(
        database: db,
        cipher: cipher,
        mediaDir: mediaDir,
        clock: clock,
        diskSpace: () async => (freeBytes: 1, totalBytes: 100),
      );
      final rejected = await lowDisk.initiateUpload(
        ownerAccountId: owner,
        mime: 'text/plain',
        size: 10,
        kind: 'text',
      );
      expect(rejected.failureOrNull?.code, FailureCode.budgetExhausted);
    });
  });

  group('AttachmentsModule HTTP', () {
    Future<Pipeline> buildPipeline({MembershipCheck? membership}) async {
      final services = HostServices();
      if (membership != null) {
        services.provide<MembershipCheck>(membership, owner: 'test');
      }
      final module = AttachmentsModule(attachments: service);
      await module.configure(services);
      final router = Router();
      module.mount(router);
      return Pipeline(
        router: router,
        authenticate: (request) async {
          final account = request.headers['test-account'];
          return account == null
              ? null
              : Principal(accountId: account, deviceId: 'test-device');
        },
      );
    }

    String chunkPath(String uploadId, int index) => Routes.attachmentUploadChunk
        .replaceFirst('{uploadId}', uploadId)
        .replaceFirst('{index}', '$index');

    String completePath(String uploadId) =>
        Routes.attachmentUploadComplete.replaceFirst('{uploadId}', uploadId);

    String attachmentPath(String attachmentId) =>
        Routes.attachment.replaceFirst('{attachmentId}', attachmentId);

    test('anonymous is 401 and malformed uploads are 400', () async {
      final pipeline = await buildPipeline();

      final anonymous = await pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.attachmentUploads,
          body: {'mime': 'text/plain', 'size': 3, 'kind': 'text'},
        ),
      );
      expect(anonymous.status, 401);

      final badSize = await pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.attachmentUploads,
          headers: {'test-account': owner},
          body: {'mime': 'text/plain', 'size': -1, 'kind': 'text'},
        ),
      );
      expect(badSize.status, 400);

      final badKind = await pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.attachmentUploads,
          headers: {'test-account': owner},
          body: {'mime': 'text/plain', 'size': 1, 'kind': 'nope'},
        ),
      );
      expect(badKind.status, 400);

      final missingBody = await pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.attachmentUploads,
          headers: {'test-account': owner},
        ),
      );
      expect(missingBody.status, 400);

      final init = await pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.attachmentUploads,
          headers: {'test-account': owner},
          body: {'mime': 'text/plain', 'size': 2, 'kind': 'text'},
        ),
      );
      expect(init.status, 200);
      final uploadId = (init.json! as Map)['uploadId'] as String;

      final badBase64 = await pipeline.handle(
        HostRequest(
          method: 'PUT',
          path: chunkPath(uploadId, 0),
          headers: {'test-account': owner},
          body: {'dataBase64': '***not-base64***'},
        ),
      );
      expect(badBase64.status, 400);
    });

    test('round trip uploads, reads with visibility, and deletes', () async {
      final pipeline = await buildPipeline(membership: _FakeMembership());
      final textBytes = utf8.encode('http text');
      final init = await pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.attachmentUploads,
          headers: {'test-account': owner},
          body: {
            'mime': 'text/plain',
            'size': textBytes.length,
            'kind': 'text',
            'conversationId': 'conv-1',
          },
        ),
      );
      expect(init.status, 200);
      final uploadId = (init.json! as Map)['uploadId'] as String;

      final chunk = await pipeline.handle(
        HostRequest(
          method: 'PUT',
          path: chunkPath(uploadId, 0),
          headers: {'test-account': owner},
          body: {'dataBase64': base64Encode(textBytes)},
        ),
      );
      expect(chunk.status, 200);
      expect((chunk.json! as Map)['nextChunk'], 1);

      final complete = await pipeline.handle(
        HostRequest(
          method: 'POST',
          path: completePath(uploadId),
          headers: {'test-account': owner},
          body: {'sha256': sha256.convert(textBytes).toString()},
        ),
      );
      expect(complete.status, 200);
      expect((complete.json! as Map)['extractionStatus'], 'extracted');
      final attachmentId = (complete.json! as Map)['id'] as String;

      final ownerGet = await pipeline.handle(
        HostRequest(
          method: 'GET',
          path: attachmentPath(attachmentId),
          headers: {'test-account': owner},
        ),
      );
      expect(ownerGet.status, 200);
      expect((ownerGet.json! as Map)['extractedText'], 'http text');

      final memberGet = await pipeline.handle(
        HostRequest(
          method: 'GET',
          path: attachmentPath(attachmentId),
          headers: {'test-account': 'acct-member'},
        ),
      );
      expect(memberGet.status, 200);
      expect((memberGet.json! as Map)['extractedText'], 'http text');

      final strangerGet = await pipeline.handle(
        HostRequest(
          method: 'GET',
          path: attachmentPath(attachmentId),
          headers: {'test-account': 'acct-stranger'},
        ),
      );
      expect(strangerGet.status, 404);

      final unknownGet = await pipeline.handle(
        HostRequest(
          method: 'GET',
          path: attachmentPath('missing-id'),
          headers: {'test-account': owner},
        ),
      );
      expect(unknownGet.status, 404);

      final deleted = await pipeline.handle(
        HostRequest(
          method: 'DELETE',
          path: attachmentPath(attachmentId),
          headers: {'test-account': owner},
        ),
      );
      expect(deleted.status, 200);
      expect((deleted.json! as Map)['removed'], isTrue);

      final gone = await pipeline.handle(
        HostRequest(
          method: 'GET',
          path: attachmentPath(attachmentId),
          headers: {'test-account': owner},
        ),
      );
      expect(gone.status, 404);
    });

    test('rejects malformed / traversal ids', () async {
      final badConversation = await service.initiateUpload(
        ownerAccountId: owner,
        mime: 'text/plain',
        size: 1,
        kind: 'text',
        conversationId: '../etc',
      );
      expect(badConversation.isOk, isFalse);

      final init = await service.initiateUpload(
        ownerAccountId: owner,
        mime: 'text/plain',
        size: 1,
        kind: 'text',
      );
      final uploadId = init.value['uploadId'] as String;
      final badChunk = await service.uploadChunk(
        ownerAccountId: owner,
        uploadId: '../$uploadId',
        index: 0,
        bytes: [65],
      );
      expect(badChunk.isOk, isFalse);
    });

    test('conversation-scoped initiate requires membership', () async {
      Future<HostResponse> initiate(
        Pipeline pipeline,
        String conversationId,
      ) => pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.attachmentUploads,
          headers: {'test-account': owner},
          body: {
            'mime': 'text/plain',
            'size': 1,
            'kind': 'text',
            'conversationId': conversationId,
          },
        ),
      );
      final denied = await initiate(
        await buildPipeline(membership: _FakeMembership()),
        'conv-other',
      );
      expect(denied.status, 404);
      final allowed = await initiate(
        await buildPipeline(membership: _PostMembership()),
        'conv-other',
      );
      expect(allowed.status, 200);
    });
  });
}
