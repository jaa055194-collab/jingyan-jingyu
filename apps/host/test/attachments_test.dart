import 'dart:async';
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
        includeExtractedText: true,
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

    group('chunk recovery', () {
      Future<String> startUpload(int size) async {
        final init = await service.initiateUpload(
          ownerAccountId: owner,
          mime: 'application/octet-stream',
          size: size,
          kind: 'file',
        );
        return init.value['uploadId'] as String;
      }

      Future<Result<Map<String, Object?>>> sendChunk(
        String uploadId,
        int index,
        String text,
      ) => service.uploadChunk(
        ownerAccountId: owner,
        uploadId: uploadId,
        index: index,
        bytes: utf8.encode(text),
      );

      File partFor(String uploadId) => File('$mediaDir/$owner/$uploadId.part');

      test(
        'reopens a committed prefix and replaces only the stray suffix',
        () async {
          final uploadId = await startUpload(6);
          expect((await sendChunk(uploadId, 0, 'abc')).isOk, isTrue);
          final part = partFor(uploadId);
          await part.writeAsString('X', mode: FileMode.append, flush: true);
          await db.close();
          db = await SqliteDatabase.open(
            '${directory.path}/host.sqlite',
            migrations: [...allMigrations, ...messagesMigrations],
          );
          service = AttachmentService(
            database: db,
            cipher: cipher,
            mediaDir: mediaDir,
            clock: clock,
            diskSpace: ampleDisk,
          );

          final duplicate = await sendChunk(uploadId, 0, 'ABC');
          expect(duplicate.value, {'received': 3, 'nextChunk': 1});
          expect(
            await part.readAsString(),
            'abcX',
          ); // A duplicate does not write.
          final next = await sendChunk(uploadId, 1, 'def');
          expect(next.value, {'received': 6, 'nextChunk': 2});
          expect(await part.readAsString(), 'abcdef');

          final digest = sha256.convert(utf8.encode('abcdef')).toString();
          final done = await service.completeUpload(
            ownerAccountId: owner,
            uploadId: uploadId,
            expectedSha256: digest,
          );
          expect(done.value['sha256'], digest);
          final attachmentId = done.value['id'];
          expect(
            await File('$mediaDir/$owner/$attachmentId').readAsString(),
            'abcdef',
          );
        },
      );

      test(
        'completion hashes a fully committed prefix without a stray suffix',
        () async {
          final uploadId = await startUpload(3);
          expect((await sendChunk(uploadId, 0, 'abc')).isOk, isTrue);
          final part = partFor(uploadId);
          await part.writeAsString('X', mode: FileMode.append, flush: true);

          final digest = sha256.convert(utf8.encode('abc')).toString();
          final done = await service.completeUpload(
            ownerAccountId: owner,
            uploadId: uploadId,
            expectedSha256: digest,
          );
          expect(done.isOk, isTrue, reason: '${done.failureOrNull}');
          expect(done.value['sha256'], digest);
          final attachmentId = done.value['id'];
          expect(
            await File('$mediaDir/$owner/$attachmentId').readAsString(),
            'abc',
          );
        },
      );

      test('completion can publish an empty file without a part', () async {
        final uploadId = await startUpload(0);
        final done = await service.completeUpload(
          ownerAccountId: owner,
          uploadId: uploadId,
        );
        expect(done.value['size'], 0);
        final attachmentId = done.value['id'];
        expect(await File('$mediaDir/$owner/$attachmentId').length(), 0);
      });

      for (final missing in [false, true]) {
        test(
          'refuses retries with a ${missing ? 'missing' : 'short'} committed prefix',
          () async {
            final uploadId = await startUpload(3);
            expect((await sendChunk(uploadId, 0, 'abc')).isOk, isTrue);
            final part = partFor(uploadId);
            if (missing) {
              await part.delete();
            } else {
              await part.writeAsString('ab', flush: true);
            }

            final duplicate = await sendChunk(uploadId, 0, 'abc');
            final next = await sendChunk(uploadId, 1, '');
            final done = await service.completeUpload(
              ownerAccountId: owner,
              uploadId: uploadId,
            );
            expect(
              duplicate.isErr,
              isTrue,
              reason: 'duplicate must not acknowledge lost bytes',
            );
            expect(
              next.isErr,
              isTrue,
              reason: 'new chunk must not advance the ledger',
            );
            expect(done.isErr, isTrue);
            expect(await part.exists(), !missing);
            if (!missing) expect(await part.readAsString(), 'ab');
            final ledger = await db.query(
              'SELECT received_bytes, next_chunk, status FROM attachment_uploads WHERE id = ?',
              [uploadId],
            );
            expect(ledger.single, {
              'received_bytes': 3,
              'next_chunk': 1,
              'status': 'pending',
            });
            expect(await db.query('SELECT id FROM attachments'), isEmpty);
          },
        );
      }

      test('foreign owner cannot mutate or complete a pending part', () async {
        final uploadId = await startUpload(3);
        expect((await sendChunk(uploadId, 0, 'abc')).isOk, isTrue);
        final part = partFor(uploadId);
        await part.writeAsString('X', mode: FileMode.append, flush: true);

        final chunk = await service.uploadChunk(
          ownerAccountId: 'acct-other',
          uploadId: uploadId,
          index: 1,
          bytes: [],
        );
        final done = await service.completeUpload(
          ownerAccountId: 'acct-other',
          uploadId: uploadId,
        );
        expect(chunk.failureOrNull?.code, FailureCode.notFound);
        expect(done.failureOrNull?.code, FailureCode.notFound);
        expect(await part.readAsString(), 'abcX');
        expect(await db.query('SELECT id FROM attachments'), isEmpty);
      });

      test('overlapping retries check the committed chunk size', () async {
        final uploadId = await startUpload(3);
        final results = await Future.wait([
          sendChunk(uploadId, 0, 'abc'),
          sendChunk(uploadId, 0, 'a'),
        ]);
        expect(results[0].value, {'received': 3, 'nextChunk': 1});
        expect(results[1].failureOrNull?.code, FailureCode.invalidArgument);
        expect(await partFor(uploadId).readAsString(), 'abc');
      });

      test('overlapping retries and completion publish one copy', () async {
        final uploadId = await startUpload(3);
        // Start all operations before yielding: without a per-upload guard
        // each SQLite SELECT is queued before the first write can commit.
        final results = await Future.wait([
          sendChunk(uploadId, 0, 'abc'),
          sendChunk(uploadId, 0, 'ABC'),
          service.completeUpload(ownerAccountId: owner, uploadId: uploadId),
          service.completeUpload(ownerAccountId: owner, uploadId: uploadId),
        ]);
        expect(results[0].value, {'received': 3, 'nextChunk': 1});
        expect(results[1].value, {'received': 3, 'nextChunk': 1});
        expect(results[2].isOk, isTrue, reason: '${results[2].failureOrNull}');
        final attachmentId = results[2].value['id'];
        expect(results[3].failureOrNull?.code, FailureCode.conflict);
        expect(
          await File('$mediaDir/$owner/$attachmentId').readAsString(),
          'abc',
        );
        expect(await db.query('SELECT id FROM attachments'), [
          {'id': attachmentId},
        ]);
        expect(await partFor(uploadId).exists(), isFalse);
      });
    });

    group('abort upload', () {
      Future<String> startUpload({int size = 6}) async {
        final init = await service.initiateUpload(
          ownerAccountId: owner,
          mime: 'application/octet-stream',
          size: size,
          kind: 'file',
        );
        expect(init.isOk, isTrue, reason: '${init.failureOrNull}');
        return init.value['uploadId'] as String;
      }

      File partFor(String uploadId) => File('$mediaDir/$owner/$uploadId.part');

      Future<Result<Map<String, Object?>>> sendChunk(
        String uploadId,
        int index,
        String text,
      ) => service.uploadChunk(
        ownerAccountId: owner,
        uploadId: uploadId,
        index: index,
        bytes: utf8.encode(text),
      );

      test(
        'owner abort after partial chunks frees the slot and blocks the upload',
        () async {
          final uploadIds = <String>[];
          for (var i = 0; i < 3; i++) {
            uploadIds.add(await startUpload());
          }
          final uploadId = uploadIds.first;
          expect((await sendChunk(uploadId, 0, 'abc')).isOk, isTrue);
          expect(await partFor(uploadId).exists(), isTrue);

          final aborted = await service.abortUpload(
            ownerAccountId: owner,
            uploadId: uploadId,
          );
          expect(aborted.isOk, isTrue, reason: '${aborted.failureOrNull}');

          final row = (await db.query(
            'SELECT status FROM attachment_uploads WHERE id = ?',
            [uploadId],
          )).single;
          expect(row['status'], 'aborted');
          expect(
            await db.query(
              'SELECT chunk_index FROM attachment_upload_chunks '
              'WHERE upload_id = ?',
              [uploadId],
            ),
            isEmpty,
          );
          expect(await partFor(uploadId).exists(), isFalse);

          final chunkAfter = await sendChunk(uploadId, 1, 'def');
          final completeAfter = await service.completeUpload(
            ownerAccountId: owner,
            uploadId: uploadId,
          );
          expect(chunkAfter.failureOrNull?.code, FailureCode.conflict);
          expect(completeAfter.failureOrNull?.code, FailureCode.conflict);
          expect(await db.query('SELECT id FROM attachments'), isEmpty);

          final replacement = await service.initiateUpload(
            ownerAccountId: owner,
            mime: 'application/octet-stream',
            size: 6,
            kind: 'file',
          );
          expect(
            replacement.isOk,
            isTrue,
            reason: '${replacement.failureOrNull}',
          );
          final fullAgain = await service.initiateUpload(
            ownerAccountId: owner,
            mime: 'application/octet-stream',
            size: 6,
            kind: 'file',
          );
          expect(fullAgain.failureOrNull?.code, FailureCode.rateLimited);
        },
      );

      test(
        'foreign abort is not found and leaves the pending upload intact',
        () async {
          final uploadId = await startUpload();
          expect((await sendChunk(uploadId, 0, 'abc')).isOk, isTrue);
          final part = partFor(uploadId);

          final foreign = await service.abortUpload(
            ownerAccountId: 'acct-other',
            uploadId: uploadId,
          );
          expect(foreign.failureOrNull?.code, FailureCode.notFound);
          final row = (await db.query(
            'SELECT status FROM attachment_uploads WHERE id = ?',
            [uploadId],
          )).single;
          expect(row['status'], 'pending');
          expect(
            await db.query(
              'SELECT chunk_index FROM attachment_upload_chunks '
              'WHERE upload_id = ?',
              [uploadId],
            ),
            hasLength(1),
          );
          expect(await part.readAsString(), 'abc');

          final next = await sendChunk(uploadId, 1, 'def');
          expect(next.isOk, isTrue, reason: '${next.failureOrNull}');
          final done = await service.completeUpload(
            ownerAccountId: owner,
            uploadId: uploadId,
          );
          expect(done.isOk, isTrue, reason: '${done.failureOrNull}');
        },
      );

      test(
        'missing abort is not found and an aborted abort is idempotent',
        () async {
          final missing = await service.abortUpload(
            ownerAccountId: owner,
            uploadId: 'missing-upload',
          );
          expect(missing.failureOrNull?.code, FailureCode.notFound);

          final uploadId = await startUpload();
          final first = await service.abortUpload(
            ownerAccountId: owner,
            uploadId: uploadId,
          );
          final second = await service.abortUpload(
            ownerAccountId: owner,
            uploadId: uploadId,
          );
          expect(first.isOk, isTrue);
          expect(second.isOk, isTrue);
          final row = (await db.query(
            'SELECT status FROM attachment_uploads WHERE id = ?',
            [uploadId],
          )).single;
          expect(row['status'], 'aborted');
        },
      );

      test(
        'aborting a completed upload conflicts and keeps the attachment',
        () async {
          final uploadId = await startUpload(size: 3);
          expect((await sendChunk(uploadId, 0, 'abc')).isOk, isTrue);
          final done = await service.completeUpload(
            ownerAccountId: owner,
            uploadId: uploadId,
          );
          expect(done.isOk, isTrue, reason: '${done.failureOrNull}');
          final attachmentId = done.value['id'] as String;

          final aborted = await service.abortUpload(
            ownerAccountId: owner,
            uploadId: uploadId,
          );
          expect(aborted.failureOrNull?.code, FailureCode.conflict);
          expect(
            await db.query(
              'SELECT status FROM attachment_uploads WHERE id = ?',
              [uploadId],
            ),
            [
              {'status': 'completed'},
            ],
          );
          expect(await File('$mediaDir/$owner/$attachmentId').exists(), isTrue);
        },
      );

      test('abort and chunk are serialized through the per-upload queue',
          () async {
        final uploadId = await startUpload();
        final chunkFuture = sendChunk(uploadId, 0, 'abc');
        final abortFuture = service.abortUpload(
          ownerAccountId: owner,
          uploadId: uploadId,
        );
        final chunkResult = await chunkFuture;
        final abortResult = await abortFuture;
        expect(chunkResult.isOk, isTrue, reason: '${chunkResult.failureOrNull}');
        expect(abortResult.isOk, isTrue, reason: '${abortResult.failureOrNull}');
        expect(await partFor(uploadId).exists(), isFalse);
        final row = (await db.query(
          'SELECT status FROM attachment_uploads WHERE id = ?',
          [uploadId],
        )).single;
        expect(row['status'], 'aborted');

        final abortFirstId = await startUpload();
        final abortFirst = service.abortUpload(
          ownerAccountId: owner,
          uploadId: abortFirstId,
        );
        final chunkAfter = sendChunk(abortFirstId, 0, 'abc');
        final abortFirstResult = await abortFirst;
        final chunkAfterResult = await chunkAfter;
        expect(abortFirstResult.isOk, isTrue);
        expect(chunkAfterResult.failureOrNull?.code, FailureCode.conflict);
        expect(await partFor(abortFirstId).exists(), isFalse);
      });

      test('abort wins over a concurrent complete without publishing', () async {
        final uploadId = await startUpload(size: 3);
        expect((await sendChunk(uploadId, 0, 'abc')).isOk, isTrue);
        final abortFuture = service.abortUpload(
          ownerAccountId: owner,
          uploadId: uploadId,
        );
        final completeFuture = service.completeUpload(
          ownerAccountId: owner,
          uploadId: uploadId,
        );
        final abortResult = await abortFuture;
        final completeResult = await completeFuture;
        expect(abortResult.isOk, isTrue);
        expect(completeResult.failureOrNull?.code, FailureCode.conflict);
        expect(await db.query('SELECT id FROM attachments'), isEmpty);
        expect(await partFor(uploadId).exists(), isFalse);
      });
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
        includeExtractedText: true,
      );
      expect(ownerView.value['extractedText'], 'secret note');

      final memberView = await service.getAttachment(
        accountId: 'acct-member',
        attachmentId: attachmentId,
        canReadConversation: (account, conversation) async =>
            account == 'acct-member' && conversation == 'conv-1',
        includeExtractedText: true,
      );
      expect(memberView.isOk, isTrue);
      expect(memberView.value.containsKey('extractedText'), isFalse);
      expect(memberView.value['mime'], 'text/plain');

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

    Future<List<Result<Map<String, Object?>>>> raceInitiations(
      String account,
    ) async {
      const attempts = 8;
      var probes = 0;
      final ready = Completer<void>();
      Future<({int freeBytes, int totalBytes})> synchronizedDisk() async {
        if (++probes == attempts) ready.complete();
        // Align requests before admission without replacing the real database.
        await ready.future;
        return ampleDisk();
      }

      final services = List.generate(
        2,
        (_) => AttachmentService(
          database: db,
          cipher: cipher,
          mediaDir: mediaDir,
          clock: clock,
          diskSpace: synchronizedDisk,
        ),
      );
      return Future.wait([
        for (var i = 0; i < attempts; i++)
          services[i % services.length].initiateUpload(
            ownerAccountId: account,
            mime: 'text/plain',
            size: 1,
            kind: 'text',
          ),
      ]);
    }

    test('B-6 concurrent service instances admit only three pending uploads',
        () async {
      final results = await raceInitiations(owner);
      expect(results.where((result) => result.isOk), hasLength(3));
      expect(
        results.where(
          (result) => result.failureOrNull?.code == FailureCode.rateLimited,
        ),
        hasLength(5),
      );
      final pending = await db.query(
        "SELECT id FROM attachment_uploads "
        "WHERE owner_account_id = ? AND status = 'pending'",
        [owner],
      );
      expect(pending, hasLength(3));
      expect(
        results
            .where((result) => result.isOk)
            .map((result) => result.value['uploadId'])
            .toSet(),
        hasLength(3),
      );
    });

    test('B-6 a full owner does not consume another accounts upload slots',
        () async {
      for (var i = 0; i < 3; i++) {
        final result = await service.initiateUpload(
          ownerAccountId: owner,
          mime: 'text/plain',
          size: 1,
          kind: 'text',
        );
        expect(result.isOk, isTrue);
      }
      final results = await raceInitiations('acct-other');
      expect(results.where((result) => result.isOk), hasLength(3));
      expect(
        results.where(
          (result) => result.failureOrNull?.code == FailureCode.rateLimited,
        ),
        hasLength(5),
      );
      for (final account in [owner, 'acct-other']) {
        expect(
          await db.query(
            "SELECT id FROM attachment_uploads "
            "WHERE owner_account_id = ? AND status = 'pending'",
            [account],
          ),
          hasLength(3),
        );
      }
    });

    test('B-6 completing an upload makes exactly one slot reusable', () async {
      final uploadIds = <String>[];
      for (var i = 0; i < 3; i++) {
        final result = await service.initiateUpload(
          ownerAccountId: owner,
          mime: 'text/plain',
          size: 1,
          kind: 'text',
        );
        expect(result.isOk, isTrue);
        uploadIds.add(result.value['uploadId'] as String);
      }
      final chunk = await service.uploadChunk(
        ownerAccountId: owner,
        uploadId: uploadIds.first,
        index: 0,
        bytes: [120],
      );
      expect(chunk.isOk, isTrue);
      final completed = await service.completeUpload(
        ownerAccountId: owner,
        uploadId: uploadIds.first,
      );
      expect(completed.isOk, isTrue);
      final results = await raceInitiations(owner);
      expect(results.where((result) => result.isOk), hasLength(1));
      expect(
        results.where(
          (result) => result.failureOrNull?.code == FailureCode.rateLimited,
        ),
        hasLength(7),
      );
      expect(
        await db.query(
          "SELECT id FROM attachment_uploads "
          "WHERE owner_account_id = ? AND status = 'pending'",
          [owner],
        ),
        hasLength(3),
      );
      final status = await db.query(
        'SELECT status FROM attachment_uploads WHERE id = ?',
        [uploadIds.first],
      );
      expect(status.single['status'], 'completed');
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
      final memberJson = memberGet.json! as Map;
      expect(memberJson.containsKey('extractedText'), isFalse);
      expect(memberJson['mime'], 'text/plain');
      expect(memberGet.encodeBody(), isNot(contains('http text')));

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

    String uploadPath(String uploadId) =>
        Routes.attachmentUpload.replaceFirst('{uploadId}', uploadId);

    test('DELETE abort is owner-scoped and idempotent', () async {
      final pipeline = await buildPipeline();

      final anonymous = await pipeline.handle(
        HostRequest(method: 'DELETE', path: uploadPath('missing-upload')),
      );
      expect(anonymous.status, 401);

      final init = await pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.attachmentUploads,
          headers: {'test-account': owner},
          body: {
            'mime': 'application/octet-stream',
            'size': 6,
            'kind': 'file',
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
          body: {'dataBase64': base64Encode(utf8.encode('abc'))},
        ),
      );
      expect(chunk.status, 200);

      final foreign = await pipeline.handle(
        HostRequest(
          method: 'DELETE',
          path: uploadPath(uploadId),
          headers: {'test-account': 'acct-other'},
        ),
      );
      expect(foreign.status, 404);
      expect(
        (await db.query(
          'SELECT status FROM attachment_uploads WHERE id = ?',
          [uploadId],
        )).single['status'],
        'pending',
      );

      final ownerAbort = await pipeline.handle(
        HostRequest(
          method: 'DELETE',
          path: uploadPath(uploadId),
          headers: {'test-account': owner},
        ),
      );
      expect(ownerAbort.status, 200);
      expect(ownerAbort.json, {'aborted': true});

      final again = await pipeline.handle(
        HostRequest(
          method: 'DELETE',
          path: uploadPath(uploadId),
          headers: {'test-account': owner},
        ),
      );
      expect(again.status, 200);
      expect(again.json, {'aborted': true});

      final chunkAfter = await pipeline.handle(
        HostRequest(
          method: 'PUT',
          path: chunkPath(uploadId, 1),
          headers: {'test-account': owner},
          body: {'dataBase64': base64Encode(utf8.encode('def'))},
        ),
      );
      expect(chunkAfter.status, 409);

      final completeAfter = await pipeline.handle(
        HostRequest(
          method: 'POST',
          path: completePath(uploadId),
          headers: {'test-account': owner},
          body: {},
        ),
      );
      expect(completeAfter.status, 409);
    });

    test('DELETE abort distinguishes missing from completed uploads', () async {
      final pipeline = await buildPipeline();
      final missing = await pipeline.handle(
        HostRequest(
          method: 'DELETE',
          path: uploadPath('missing-upload'),
          headers: {'test-account': owner},
        ),
      );
      expect(missing.status, 404);

      final init = await service.initiateUpload(
        ownerAccountId: owner,
        mime: 'application/octet-stream',
        size: 3,
        kind: 'file',
      );
      final uploadId = init.value['uploadId'] as String;
      await service.uploadChunk(
        ownerAccountId: owner,
        uploadId: uploadId,
        index: 0,
        bytes: utf8.encode('abc'),
      );
      final done = await service.completeUpload(
        ownerAccountId: owner,
        uploadId: uploadId,
      );
      expect(done.isOk, isTrue);
      final attachmentId = done.value['id'] as String;

      final conflict = await pipeline.handle(
        HostRequest(
          method: 'DELETE',
          path: uploadPath(uploadId),
          headers: {'test-account': owner},
        ),
      );
      expect(conflict.status, 409);
      expect(
        await db.query('SELECT id FROM attachments WHERE id = ?', [
          attachmentId,
        ]),
        hasLength(1),
      );
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
