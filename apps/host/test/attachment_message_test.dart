import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/messages/attachments.dart';
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
  late Pipeline pipeline;

  const owner = 'acct-owner';
  const other = 'acct-other';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('attachment-message-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...messagesMigrations],
    );
    cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
    clock = FakeClock(DateTime.utc(2026, 11, 14, 9));
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
    required String account,
    required String conversationId,
    required String mime,
    required String text,
    String kind = 'text',
  }) async {
    final bytes = utf8.encode(text);
    final init = await attachments.initiateUpload(
      ownerAccountId: account,
      mime: mime,
      size: bytes.length,
      kind: kind,
      conversationId: conversationId,
    );
    expect(init.isOk, isTrue, reason: 'initiate');
    final uploadId = init.value['uploadId'] as String;
    final chunk = await attachments.uploadChunk(
      ownerAccountId: account,
      uploadId: uploadId,
      index: 0,
      bytes: bytes,
    );
    expect(chunk.isOk, isTrue, reason: 'chunk');
    final done = await attachments.completeUpload(
      ownerAccountId: account,
      uploadId: uploadId,
    );
    expect(done.isOk, isTrue, reason: 'complete');
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

  Future<HostResponse> fileSearch(String account, String q) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: Routes.search,
      query: {'q': q, 'type': 'file'},
      headers: {'test-account': account},
    ),
  );

  test('send references own attachment in same conversation and syncs body',
      () async {
    final id = await upload(
      account: owner,
      conversationId: 'conv-1',
      mime: 'text/plain',
      text: 'hello attachment body',
    );
    final sent = await send(owner, 'conv-1', 'c1', 'file', {
      'attachmentId': id,
      'name': 'a.txt',
    });
    expect(sent.status, 200);
    final message = (sent.json! as Map)['message'] as Map;
    expect(message['kind'], 'file');
    expect((message['body'] as Map)['attachmentId'], id);
  });

  test('cannot reference another account attachment', () async {
    final id = await upload(
      account: owner,
      conversationId: 'conv-1',
      mime: 'text/plain',
      text: 'private',
    );
    final sent = await send(other, 'conv-1', 'c1', 'file', {
      'attachmentId': id,
    });
    expect(sent.status, 404);
  });

  test('attachment scoped to a different conversation is rejected', () async {
    final id = await upload(
      account: owner,
      conversationId: 'conv-1',
      mime: 'text/plain',
      text: 'scoped',
    );
    final sent = await send(owner, 'conv-2', 'c1', 'file', {
      'attachmentId': id,
    });
    expect(sent.status, 400);
  });

  test('unknown and malformed attachment references are rejected', () async {
    final unknown = await send(owner, 'conv-1', 'c1', 'file', {
      'attachmentId': 'missing-id',
    });
    expect(unknown.status, 404);
    final malformed = await send(owner, 'conv-1', 'c2', 'file', {
      'attachmentId': 42,
    });
    expect(malformed.status, 400);
  });

  test('text send without an attachment still works', () async {
    final sent = await send(owner, 'conv-1', 'c1', 'text', {'text': 'hi'});
    expect(sent.status, 200);
    expect(((sent.json! as Map)['message'] as Map)['kind'], 'text');
  });

  test('file search returns own attachments by extracted text and isolates users',
      () async {
    final id = await upload(
      account: owner,
      conversationId: 'conv-1',
      mime: 'text/plain',
      text: '项目代号鲸落 机密内容',
    );
    final mine = await fileSearch(owner, '鲸落');
    expect(mine.status, 200);
    final hits = ((mine.json! as Map)['hits'] as List).cast<Map<String, Object?>>();
    expect(hits, hasLength(1));
    expect(hits.single['id'], id);
    expect('${hits.single['snippet']}', contains('鲸落'));

    final theirs = await fileSearch(other, '鲸落');
    expect(theirs.status, 200);
    expect(((theirs.json! as Map)['hits'] as List), isEmpty);
  });
}
