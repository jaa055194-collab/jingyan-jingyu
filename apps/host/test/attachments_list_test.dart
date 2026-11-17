import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/messages/attachments.dart';
import 'package:jingyu_host/src/messages/attachments_module.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

Future<({int freeBytes, int totalBytes})> ampleDisk() async =>
    (freeBytes: 1 << 40, totalBytes: 1 << 40);

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late FakeClock clock;
  late AttachmentService service;

  const owner = 'acct-owner';
  const other = 'acct-other';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('attachments-list-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...messagesMigrations],
    );
    cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
    clock = FakeClock(DateTime.utc(2026, 11, 14, 9));
    service = AttachmentService(
      database: db,
      cipher: cipher,
      mediaDir: '${directory.path}/media',
      clock: clock,
      diskSpace: ampleDisk,
    );
  });

  tearDown(() async {
    cipher.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<String> upload(
    String accountId, {
    required String mime,
    required String kind,
    required String text,
    String? conversationId,
  }) async {
    final bytes = utf8.encode(text);
    final init = await service.initiateUpload(
      ownerAccountId: accountId,
      mime: mime,
      size: bytes.length,
      kind: kind,
      conversationId: conversationId,
    );
    expect(init.isOk, isTrue);
    final uploadId = init.value['uploadId'] as String;
    final chunk = await service.uploadChunk(
      ownerAccountId: accountId,
      uploadId: uploadId,
      index: 0,
      bytes: bytes,
    );
    expect(chunk.isOk, isTrue);
    final done = await service.completeUpload(
      ownerAccountId: accountId,
      uploadId: uploadId,
    );
    expect(done.isOk, isTrue);
    return done.value['id'] as String;
  }

  Future<void> setCreatedAt(String id, DateTime at) => db.execute(
    'UPDATE attachments SET created_at = ? WHERE id = ?',
    [at.toUtc().toIso8601String(), id],
  );

  Future<Pipeline> buildPipeline() async {
    final module = AttachmentsModule(attachments: service);
    await module.configure(HostServices());
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

  Future<HostResponse> list(
    Pipeline pipeline, {
    Map<String, String> query = const {},
    String? account = owner,
    Object? body,
  }) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: Routes.attachments,
      query: query,
      headers: account == null
          ? const <String, String>{}
          : {'test-account': account},
      body: body,
    ),
  );

  test(
    'owner isolation: only the caller own attachments are returned',
    () async {
      final pipeline = await buildPipeline();
      final aId = await upload(
        owner,
        mime: 'text/plain',
        kind: 'text',
        text: 'super-secret-a-text',
      );
      final bId = await upload(
        other,
        mime: 'text/plain',
        kind: 'text',
        text: 'secret-b-text',
      );

      final asOwner = await list(pipeline);
      expect(asOwner.status, 200);
      final ownerItems = (asOwner.json! as List).cast<Map<String, Object?>>();
      expect(ownerItems.map((i) => i['id']), [aId]);
      expect(ownerItems.map((i) => i['id']), isNot(contains(bId)));

      final asOther = await list(pipeline, account: other);
      final otherItems = (asOther.json! as List).cast<Map<String, Object?>>();
      expect(otherItems.map((i) => i['id']), [bId]);

      // Safe fields only: no extractedText / blob / sha256 / owner / rel_path.
      expect(ownerItems.single.keys.toSet(), {
        'id',
        'conversationId',
        'kind',
        'mime',
        'size',
        'extractionStatus',
        'createdAt',
      });
      final encoded = jsonEncode(asOwner.json);
      expect(encoded, isNot(contains('super-secret-a-text')));
      expect(encoded, isNot(contains('extractedText')));
      expect(encoded, isNot(contains('sha256')));
      expect(encoded, isNot(contains('rel_path')));
    },
  );

  test('orders by createdAt desc and paginates with before cursor', () async {
    final pipeline = await buildPipeline();
    final ids = <String>[];
    for (var i = 0; i < 5; i++) {
      final id = await upload(
        owner,
        mime: 'text/plain',
        kind: 'text',
        text: 'row-$i',
        conversationId: 'conv-1',
      );
      await setCreatedAt(id, DateTime.utc(2026, 11, 14, 9, 0, i));
      ids.add(id);
    }

    final page1 = await list(pipeline, query: {'limit': '2'});
    final p1 = (page1.json! as List).cast<Map<String, Object?>>();
    expect(p1.map((i) => i['id']), [ids[4], ids[3]]);

    final page2 = await list(
      pipeline,
      query: {'limit': '2', 'before': p1.last['createdAt'] as String},
    );
    final p2 = (page2.json! as List).cast<Map<String, Object?>>();
    expect(p2.map((i) => i['id']), [ids[2], ids[1]]);

    final page3 = await list(
      pipeline,
      query: {'limit': '2', 'before': p2.last['createdAt'] as String},
    );
    final p3 = (page3.json! as List).cast<Map<String, Object?>>();
    expect(p3.map((i) => i['id']), [ids[0]]);
  });

  test('filters by conversationId', () async {
    final pipeline = await buildPipeline();
    final c1a = await upload(
      owner,
      mime: 'text/plain',
      kind: 'text',
      text: 'c1a',
      conversationId: 'conv-1',
    );
    final c1b = await upload(
      owner,
      mime: 'text/plain',
      kind: 'text',
      text: 'c1b',
      conversationId: 'conv-1',
    );
    final c2 = await upload(
      owner,
      mime: 'text/plain',
      kind: 'text',
      text: 'c2',
      conversationId: 'conv-2',
    );

    final conv1 = await list(pipeline, query: {'conversationId': 'conv-1'});
    final items = (conv1.json! as List).cast<Map<String, Object?>>();
    expect(items.map((i) => i['id']).toSet(), {c1a, c1b});
    expect(items.every((i) => i['conversationId'] == 'conv-1'), isTrue);

    final all = await list(pipeline);
    expect((all.json! as List).length, 3);
    expect((all.json! as List).map((i) => (i as Map)['id']), contains(c2));
  });

  test(
    'malformed parameters and anonymous calls are rejected safely',
    () async {
      final pipeline = await buildPipeline();
      expect((await list(pipeline, account: null)).status, 401);

      for (final query in [
        {'limit': '0'},
        {'limit': '101'},
        {'limit': 'abc'},
        {'before': 'not-a-date'},
        {'conversationId': 'bad id!'},
        {'unknown': '1'},
      ]) {
        final resp = await list(pipeline, query: query);
        expect(resp.status, 400, reason: '$query');
      }

      final withBody = await list(pipeline, body: const {'x': 1});
      expect(withBody.status, 400);
    },
  );
}
