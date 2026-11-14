import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/group_management_routes.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_audit_log.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _FastHasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String value) async => 'test:$value';

  @override
  Future<bool> verifyAsync(String value, String encodedHash) async =>
      encodedHash == 'test:$value';
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late AccountsDomain accounts;
  late ConversationService conversations;
  late Pipeline pipeline;
  late Map<String, String> tokens;
  late String groupId;
  const password = 'Test-Password-9';

  Future<HostResponse> getAnnouncement(String? token) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: Routes.groupAnnouncement.replaceFirst('{conversationId}', groupId),
      headers: {if (token != null) 'authorization': 'Bearer $token'},
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('group-announcement-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...messagesMigrations,
        ...socialMigrations,
      ],
    );
    cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
    final clock = FakeClock(DateTime.utc(2026, 11, 14, 9));
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    final adminId = (await accounts.bootstrapAdmin(
      displayName: 'Admin',
      password: password,
    )).value;
    final admin = (await accounts.scope(
      (await accounts.login(adminId, password, deviceName: 'admin')).value
          .accessToken,
    )).value;
    final ownerId = (await admin.accounts.createHuman(
      displayName: 'Owner',
      password: password,
    )).value;
    final memberId = (await admin.accounts.createHuman(
      displayName: 'Member',
      password: password,
    )).value;
    final outsiderId = (await admin.accounts.createHuman(
      displayName: 'Outsider',
      password: password,
    )).value;
    tokens = {
      'owner': (await accounts.login(ownerId, password, deviceName: 'o')).value
          .accessToken,
      'member': (await accounts.login(memberId, password, deviceName: 'm')).value
          .accessToken,
      'outsider':
          (await accounts.login(outsiderId, password, deviceName: 'x')).value
              .accessToken,
    };
    conversations = ConversationService(
      database: db,
      clock: clock,
      cipher: cipher,
      headSeq: (tx, id) async => 0,
      accountExists: (tx, id) async => (await tx.query(
        'SELECT id FROM account WHERE id = ? AND disabled = 0',
        [id],
      )).isNotEmpty,
    );
    final group = (await conversations.createGroup(
      ownerAccountId: ownerId.value,
      name: 'Announcement group',
    )).value;
    groupId = group.id;
    await conversations.addMember(
      actorAccountId: ownerId.value,
      conversationId: groupId,
      memberAccountId: memberId.value,
    );
    final router = Router();
    mountGroupManagementRoutes(
      router,
      conversations: conversations,
      accounts: accounts,
      clock: clock,
      audit: SqliteAuditLog(db),
    );
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(accounts).call,
    );
  });

  tearDown(() async {
    cipher.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  test('owner sets announcement, members read, others denied, encrypted at rest',
      () async {
    final set = await pipeline.handle(
      HostRequest(
        method: 'PUT',
        path: Routes.groupAnnouncement.replaceFirst('{conversationId}', groupId),
        headers: {'authorization': 'Bearer ${tokens['owner']}'},
        body: {'text': '周五团建 机密公告'},
      ),
    );
    expect(set.status, 200);

    expect(
      ((await getAnnouncement(tokens['owner']!)).json! as Map)['announcement'],
      '周五团建 机密公告',
    );
    expect(
      ((await getAnnouncement(tokens['member']!)).json! as Map)['announcement'],
      '周五团建 机密公告',
    );
    expect((await getAnnouncement(tokens['outsider']!)).status, 404);
    expect((await getAnnouncement(null)).status, 401);

    // Not the owner cannot set.
    final denied = await pipeline.handle(
      HostRequest(
        method: 'PUT',
        path: Routes.groupAnnouncement.replaceFirst('{conversationId}', groupId),
        headers: {'authorization': 'Bearer ${tokens['member']}'},
        body: {'text': 'hijack'},
      ),
    );
    expect(denied.status, 404);

    final row = (await db.query(
      'SELECT sealed FROM group_announcements WHERE conversation_id = ?',
      [groupId],
    )).single;
    expect(row['sealed'], isNot(contains('机密公告')));
    expect((row['sealed'] as String).startsWith('v1:'), isTrue);
  });

  test('owner can clear and invalid input is rejected', () async {
    await pipeline.handle(
      HostRequest(
        method: 'PUT',
        path: Routes.groupAnnouncement.replaceFirst('{conversationId}', groupId),
        headers: {'authorization': 'Bearer ${tokens['owner']}'},
        body: {'text': 'hello'},
      ),
    );
    final cleared = await pipeline.handle(
      HostRequest(
        method: 'PUT',
        path: Routes.groupAnnouncement.replaceFirst('{conversationId}', groupId),
        headers: {'authorization': 'Bearer ${tokens['owner']}'},
        body: {'text': ''},
      ),
    );
    expect(cleared.status, 200);
    expect(
      ((await getAnnouncement(tokens['member']!)).json! as Map)['announcement'],
      isNull,
    );

    final tooLong = await pipeline.handle(
      HostRequest(
        method: 'PUT',
        path: Routes.groupAnnouncement.replaceFirst('{conversationId}', groupId),
        headers: {'authorization': 'Bearer ${tokens['owner']}'},
        body: {'text': 'x'.padRight(2001, 'x')},
      ),
    );
    expect(tooLong.status, 400);

    final badKey = await pipeline.handle(
      HostRequest(
        method: 'PUT',
        path: Routes.groupAnnouncement.replaceFirst('{conversationId}', groupId),
        headers: {'authorization': 'Bearer ${tokens['owner']}'},
        body: {'body': 'x'},
      ),
    );
    expect(badKey.status, 400);
  });
}
