import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/messages/attachments.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/messages_module.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

// Original 64 ms synthetic silence. No recording or third-party media.
// ffmpeg -f lavfi -i anullsrc=r=48000:cl=mono -t 0.064 -c:a aac
//   -profile:a aac_low -b:a 48k -map_metadata -1 -fflags +bitexact
//   -flags:a +bitexact -movflags +faststart -f ipod voice-silence-aac-lc.m4a
final _m4a = File('test/fixtures/voice-silence-aac-lc.m4a').readAsBytesSync();

// Offsets in this fixed fixture: ftyp (0), moov (28), audio hdlr (320),
// free (746), and mdat (754). The handler type is 16 bytes into hdlr.
Uint8List _replaceType(int offset, String type) =>
    Uint8List.fromList(_m4a)..setAll(offset + 4, type.codeUnits);

Uint8List _withFreeSpace(int size) {
  final bytes = Uint8List(size)..setAll(0, _m4a);
  ByteData.sublistView(bytes).setUint32(_m4a.length, size - _m4a.length);
  return bytes..setAll(_m4a.length + 4, 'free'.codeUnits);
}

// Credential derivation is not under test; credentials and their revocation
// still flow through the real accounts store and authenticator.
class _FastHasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String value) async => 'test:$value';

  @override
  Future<bool> verifyAsync(String value, String encodedHash) async =>
      encodedHash == 'test:$value';
}

void main() {
  late SqliteDatabase db;
  late String mediaDir;
  late FakeClock clock;
  late AccountsDomain accounts;
  late SqliteMessageStore store;
  late ConversationService membership;
  late AttachmentService attachments;
  late Pipeline pipeline;
  late AccountId sender, member;
  late String senderToken, memberToken, conversationId;
  var serial = 0;

  Future<Pipeline> buildPipeline({bool includeHistory = true}) async {
    final authenticate = DbAuthenticator(accounts).call;
    final services = HostServices()
      ..provide<MembershipCheck>(membership, owner: 'test');
    if (includeHistory) {
      services.provide<HistoryMembershipCheck>(membership, owner: 'test');
    }
    final module = MessagesModule(
      store: store,
      authenticate: authenticate,
      attachments: attachments,
      clock: clock,
    );
    await module.configure(services);
    final router = Router();
    module.mount(router);
    return Pipeline(
      router: router,
      authenticate: authenticate,
      onError: (error, stack, _) => Error.throwWithStackTrace(error, stack),
    );
  }

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp('voice-route-');
    addTearDown(() => directory.delete(recursive: true));
    mediaDir = '${directory.path}/media';
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...messagesMigrations,
        ...socialMigrations,
      ],
    );
    addTearDown(db.close);
    final cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
    addTearDown(cipher.dispose);
    clock = FakeClock(DateTime.utc(2026, 11, 20));
    store = SqliteMessageStore(database: db, cipher: cipher, clock: clock);
    attachments = AttachmentService(
      database: db,
      cipher: cipher,
      mediaDir: mediaDir,
      clock: clock,
    );
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    const password = 'voice-route-test-password';
    sender = (await accounts.bootstrapAdmin(
      displayName: 'Sender',
      password: password,
    )).unwrap();
    senderToken = (await accounts.login(
      sender,
      password,
      deviceName: 'Sender device',
    )).unwrap().accessToken;
    final admin = (await accounts.scope(senderToken)).unwrap();
    member = (await admin.accounts.createHuman(
      displayName: 'Member',
      password: password,
    )).unwrap();
    memberToken = (await accounts.login(
      member,
      password,
      deviceName: 'Member device',
    )).unwrap().accessToken;

    membership = ConversationService(
      database: db,
      clock: clock,
      accountExists: (tx, id) async => (await tx.query(
        'SELECT id FROM account WHERE id = ? AND disabled = 0',
        [id],
      )).isNotEmpty,
      headSeq: (tx, id) async {
        final rows = await tx.query(
          'SELECT seq FROM message_heads WHERE conversation_id = ?',
          [id],
        );
        return rows.isEmpty ? 0 : rows.single['seq'] as int;
      },
    );
    conversationId = (await membership.createGroup(
      ownerAccountId: sender.value,
      name: 'M4A route',
      historyVisibility: HistoryVisibility.joined,
    )).unwrap().id;
    pipeline = await buildPipeline();
  });

  Future<void> join() async => (await membership.addMember(
    actorAccountId: sender.value,
    conversationId: conversationId,
    memberAccountId: member.value,
  )).unwrap();

  Future<String> upload({
    Uint8List? bytes,
    String mime = 'audio/mp4',
    String kind = 'voice',
    AccountId? owner,
    String? conversation,
  }) async {
    final payload = bytes ?? _m4a;
    final account = (owner ?? sender).value;
    final start = (await attachments.initiateUpload(
      ownerAccountId: account,
      mime: mime,
      size: payload.length,
      kind: kind,
      conversationId: conversation ?? conversationId,
    )).unwrap();
    final uploadId = start['uploadId'] as String;
    final chunkSize = start['chunkSize'] as int;
    for (var offset = 0; offset < payload.length; offset += chunkSize) {
      final end = offset + chunkSize;
      (await attachments.uploadChunk(
        ownerAccountId: account,
        uploadId: uploadId,
        index: offset ~/ chunkSize,
        bytes: Uint8List.sublistView(
          payload,
          offset,
          end < payload.length ? end : payload.length,
        ),
      )).unwrap();
    }
    return (await attachments.completeUpload(
          ownerAccountId: account,
          uploadId: uploadId,
        )).unwrap()['id']
        as String;
  }

  Future<String> send(String attachmentId, {String kind = 'audio'}) async {
    final response = await pipeline.handle(
      HostRequest(
        method: 'POST',
        path: Routes.messages.replaceFirst('{conversationId}', conversationId),
        headers: {'authorization': 'Bearer $senderToken'},
        body: {
          'clientMsgId': 'voice-${++serial}',
          'kind': kind,
          'body': {'attachmentId': attachmentId},
        },
      ),
    );
    expect(response.status, 200, reason: '${response.json}');
    return ((response.json as Map)['message'] as Map)['messageId'] as String;
  }

  Future<HostResponse> readVoice(
    String messageId,
    String? token, {
    String? conversation,
    Pipeline? through,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: 'GET',
      path:
          '/api/v1/conversations/${conversation ?? conversationId}'
          '/messages/$messageId/voice-attachment',
      headers: {if (token != null) 'authorization': 'Bearer $token'},
    ),
  );

  Future<String> storedAudio(Map<String, Object?> body) async =>
      (await store.append(
        conversationId: conversationId,
        senderId: sender.value,
        clientMsgId: 'stored-${++serial}',
        kind: MessageKind.audio,
        body: body,
      )).unwrap().message.messageId;

  void expectHidden(HostResponse response, {String? reason}) {
    expect(response.status, 404, reason: reason ?? '${response.json}');
    expect(response.json, {'error': 'not_found'}, reason: reason);
  }

  test(
    'a visible audio message returns only its completed M4A bytes',
    () async {
      await join();
      final id = await send(await upload());

      final response = await readVoice(id, memberToken);
      expect(response.status, 200, reason: '${response.json}');
      expect(response.json, {
        'mime': 'audio/mp4',
        'size': _m4a.length,
        'sha256': sha256.convert(_m4a).toString(),
        'dataBase64': base64Encode(_m4a),
      });
      expect(response.headers['Cache-Control'], 'no-store');
      expect(response.headers['X-Content-Type-Options'], 'nosniff');

      final imageResponse = await pipeline.handle(
        HostRequest(
          method: 'GET',
          path: Routes.messageAttachment
              .replaceFirst('{conversationId}', conversationId)
              .replaceFirst('{messageId}', id),
          headers: {'authorization': 'Bearer $memberToken'},
        ),
      );
      expectHidden(imageResponse);
    },
  );

  test('anonymous and revoked bearers cannot read voice content', () async {
    await join();
    final id = await send(await upload());
    expect((await readVoice(id, null)).status, 401);
    expect((await readVoice(id, memberToken)).status, 200);
    final current = (await accounts.authenticate(memberToken))!;
    final scope = (await accounts.scope(memberToken)).unwrap();
    (await scope.devices.revoke(
      member,
      DeviceId.parse(current.deviceId),
    )).unwrap();

    final denied = await readVoice(id, memberToken);
    expect(denied.status, 401);
    expect(denied.json, {'error': 'unauthenticated'});
  });

  test('voice reads respect the current membership and join floor', () async {
    final attachment = await upload();
    final beforeJoin = await send(attachment);
    expectHidden(await readVoice(beforeJoin, memberToken));
    await join();
    expectHidden(await readVoice(beforeJoin, memberToken));
    final afterJoin = await send(attachment);
    expect((await readVoice(afterJoin, memberToken)).status, 200);
    (await membership.removeMember(
      actorId: sender.value,
      conversationId: conversationId,
      targetId: member.value,
    )).unwrap();
    expectHidden(await readVoice(afterJoin, memberToken));
  });

  test(
    'membership alone cannot open voice bytes without a history policy',
    () async {
      final id = await send(await upload());
      expect((await readVoice(id, senderToken)).status, 200);
      final withoutHistory = await buildPipeline(includeHistory: false);
      expectHidden(await readVoice(id, senderToken, through: withoutHistory));
    },
  );

  test('recall and non-audio kinds cannot expose M4A bytes', () async {
    final attachment = await upload();
    final id = await send(attachment);
    expect((await readVoice(id, senderToken)).status, 200);
    final recall = await pipeline.handle(
      HostRequest(
        method: 'POST',
        path: Routes.messageRecall
            .replaceFirst('{conversationId}', conversationId)
            .replaceFirst('{messageId}', id),
        headers: {'authorization': 'Bearer $senderToken'},
      ),
    );
    expect(recall.status, 200);
    expectHidden(await readVoice(id, senderToken));

    // A legacy tombstone may still carry a reference. Recalled takes priority.
    final tombstone = await storedAudio({
      'recalled': true,
      'attachmentId': attachment,
    });
    expectHidden(await readVoice(tombstone, senderToken));
    final wrongKind = await send(attachment, kind: 'file');
    expectHidden(await readVoice(wrongKind, senderToken));
  });

  test(
    'the route is scoped to an exact message, not an attachment ID',
    () async {
      final attachment = await upload();
      final id = await send(attachment);
      final elsewhere = (await membership.createGroup(
        ownerAccountId: sender.value,
        name: 'Another group',
      )).unwrap().id;
      expectHidden(await readVoice(id, senderToken, conversation: elsewhere));
      expectHidden(await readVoice(attachment, senderToken));
      expect((await readVoice('x' * 65, senderToken)).status, 400);
    },
  );

  test(
    'stored references must belong to the actual sender and conversation',
    () async {
      await join();
      // Append directly to simulate stored data that did not go through _send.
      // The viewer owns the first attachment, but the message sender does not.
      final wrongOwner = await upload(owner: member);
      final wrongConversation = await upload(conversation: 'elsewhere');
      final pending = (await attachments.initiateUpload(
        ownerAccountId: sender.value,
        mime: 'audio/mp4',
        size: _m4a.length,
        kind: 'voice',
        conversationId: conversationId,
      )).unwrap()['uploadId'];
      for (final attachment in [
        wrongOwner,
        wrongConversation,
        pending,
        42,
        '..',
        null,
      ]) {
        final id = await storedAudio({'attachmentId': attachment});
        expectHidden(await readVoice(id, memberToken));
      }
    },
  );

  test(
    'M4A needs both the allowed MIME and the voice attachment kind',
    () async {
      for (final (mime, kind) in [
        ('audio/wav', 'voice'),
        ('video/mp4', 'voice'),
        ('application/octet-stream', 'voice'),
        ('audio/mp4', 'file'),
      ]) {
        final id = await send(await upload(mime: mime, kind: kind));
        expectHidden(await readVoice(id, senderToken), reason: '$mime / $kind');
      }
    },
  );

  test(
    'a claimed M4A needs finite boxes, movie metadata, and a sound track',
    () async {
      final nestedOverrun = Uint8List.fromList(_m4a);
      ByteData.sublistView(nestedOverrun).setUint32(320, _m4a.length);
      for (final (label, bytes) in [
        ('truncated header', Uint8List.sublistView(_m4a, 0, 7)),
        ('wrong format box', _replaceType(0, 'JUNK')),
        ('missing movie', _replaceType(28, 'free')),
        ('missing media data', _replaceType(754, 'free')),
        ('missing track handler', _replaceType(320, 'free')),
        (
          'video track',
          Uint8List.fromList(_m4a)..setAll(336, 'vide'.codeUnits),
        ),
        ('box past end', Uint8List.sublistView(_m4a, 0, _m4a.length - 1)),
        ('box past parent', nestedOverrun),
        ('fragmented container', _replaceType(746, 'moof')),
      ]) {
        final id = await send(await upload(bytes: bytes));
        expectHidden(await readVoice(id, senderToken), reason: label);
      }
    },
  );

  test('valid M4A can include additional free space', () async {
    final bytes = _withFreeSpace(_m4a.length + 17);
    final id = await send(await upload(bytes: bytes));
    final response = await readVoice(id, senderToken);
    expect(response.status, 200);
    expect((response.json as Map)['dataBase64'], base64Encode(bytes));
  });

  test(
    'voice content accepts the exact 8 MiB bound and rejects larger M4A',
    () async {
      const cap = 8 * 1024 * 1024;
      for (final size in [cap, cap + 1]) {
        final id = await send(await upload(bytes: _withFreeSpace(size)));
        final response = await readVoice(id, senderToken);
        if (size == cap) {
          expect(response.status, 200);
          expect((response.json as Map)['size'], cap);
        } else {
          expectHidden(response);
        }
      }
    },
  );

  test(
    'missing, truncated or changed completed voice blobs stay hidden',
    () async {
      final attachment = await upload();
      final id = await send(attachment);
      final blob = File('$mediaDir/${sender.value}/$attachment');
      expect((await readVoice(id, senderToken)).status, 200);
      final changed = Uint8List.fromList(_m4a);
      changed[changed.length - 1] ^= 1;
      await blob.writeAsBytes(changed);
      expectHidden(await readVoice(id, senderToken), reason: 'changed payload');
      await blob.writeAsBytes(_m4a.take(_m4a.length - 1).toList());
      expectHidden(await readVoice(id, senderToken), reason: 'truncated');
      // Only delete the verified, service-generated blob within the test dir.
      await blob.delete();
      expectHidden(await readVoice(id, senderToken), reason: 'missing');

      final other = await upload();
      await db.execute('UPDATE attachments SET rel_path = ? WHERE id = ?', [
        '${sender.value}/$other',
        attachment,
      ]);
      expectHidden(
        await readVoice(id, senderToken),
        reason: 'noncanonical blob',
      );
    },
  );
}
